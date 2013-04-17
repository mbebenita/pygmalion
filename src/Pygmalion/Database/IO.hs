{-# LANGUAGE OverloadedStrings #-}

module Pygmalion.Database.IO
( ensureDB
, withDB
, withTransaction
, updateSourceFile
, getAllSourceFiles
, getCommandInfo
, getSimilarCommandInfo
, updateDef
, getDef
, enableTracing
, DBHandle
) where

import Control.Applicative
import Control.Exception(bracket)
import Control.Monad
import Data.Hashable
import Data.Int
import Data.String
import qualified Data.Text as T
import Database.SQLite.Simple
import System.FilePath.Posix

import Control.Exception.Labeled
import Pygmalion.Core

-- General database manipulation functions. These are thin wrappers around the
-- underlying database implementation that also verify that the database is
-- configured according to the correct schema and enable foreign keys.
data DBHandle = DBHandle {
                  conn :: Connection,
                  beginTransactionStmt :: Statement,
                  endTransactionStmt :: Statement,
                  updateSourceFileStmt :: Statement,
                  updateDefStmt :: Statement,
                  insertFileStmt :: Statement,
                  insertPathStmt :: Statement,
                  insertCommandStmt :: Statement,
                  insertArgsStmt :: Statement,
                  insertKindStmt :: Statement
                }

ensureDB :: IO ()
ensureDB = withDB (const . return $ ())

withDB :: (DBHandle -> IO a) -> IO a
withDB f = bracket (openDB dbFile) closeDB f

withTransaction :: DBHandle -> IO a -> IO a
withTransaction h f = bracket (execStatement h beginTransactionStmt ())
                              (const $ execStatement h endTransactionStmt ())
                              (const f)

openDB :: FilePath -> IO DBHandle
openDB db = labeledCatch "openDB" $ do
  c <- open db
  tuneDB c
  ensureSchema c
  h <- DBHandle c <$> openStatement c (mkQueryT beginTransactionSQL)
                  <*> openStatement c (mkQueryT endTransactionSQL)
                  <*> openStatement c (mkQueryT updateSourceFileSQL)
                  <*> openStatement c (mkQueryT updateDefSQL)
                  <*> openStatement c (mkQueryT insertFileSQL)
                  <*> openStatement c (mkQueryT insertPathSQL)
                  <*> openStatement c (mkQueryT insertCommandSQL)
                  <*> openStatement c (mkQueryT insertArgsSQL)
                  <*> openStatement c (mkQueryT insertKindSQL)
  return h

closeDB :: DBHandle -> IO ()
closeDB h = do
  closeStatement (beginTransactionStmt h)
  closeStatement (endTransactionStmt h)
  closeStatement (updateSourceFileStmt h)
  closeStatement (updateDefStmt h)
  closeStatement (insertFileStmt h)
  closeStatement (insertPathStmt h)
  closeStatement (insertCommandStmt h)
  closeStatement (insertArgsStmt h)
  closeStatement (insertKindStmt h)
  close (conn h)

enableTracing :: Connection -> IO ()
enableTracing c = setTrace c (Just $ putStrLn . T.unpack)

tuneDB :: Connection -> IO ()
tuneDB c = do
  -- Tradeoffs: We don't care if the database is corrupted on power loss, as
  -- this data can always be rebuilt from the original source files. However,
  -- especially given libclang's instability, we do want to avoid corruption
  -- because of crashes. We try to optimize as much as possible within those
  -- constraints.
  execute_ c "pragma synchronous = normal"
  execute_ c "pragma journal_mode = wal"
  execute_ c "pragma locking_mode = exclusive"
  execute_ c "pragma page_size = 4096"
  execute_ c "pragma cache_size = 10000"

beginTransactionSQL :: T.Text
beginTransactionSQL = "begin transaction"

endTransactionSQL :: T.Text
endTransactionSQL = "end transaction"

voidNextRow :: Statement -> IO (Maybe (Only Int64))
voidNextRow = nextRow

execStatement :: ToRow a => DBHandle -> (DBHandle -> Statement) -> a -> IO ()
execStatement h q params  = do 
    void $ withBind stmt params $ (voidNextRow stmt)
    reset stmt
  where stmt = q h

mkQuery :: String -> Query
mkQuery = fromString

mkQueryT :: T.Text -> Query
mkQueryT = mkQuery . T.unpack

-- Schema and operations for the Metadata table.
dbToolName :: String
dbToolName = "pygmalion"

dbMajorVersion, dbMinorVersion :: Int64
dbMajorVersion = 0
dbMinorVersion = 7

defineMetadataTable :: Connection -> IO ()
defineMetadataTable c = execute_ c sql
  where sql = "create table if not exists Metadata(               \
              \ Tool varchar(16) primary key not null,            \
              \ MajorVersion integer zerofill unsigned not null,  \
              \ MinorVersion integer zerofill unsigned not null)"

getDBVersion :: Connection -> IO (Maybe (Int64, Int64))
getDBVersion c = do
    row <- query c sql params
    return $ case row of
              [version] -> Just version
              _         -> Nothing
  where sql = "select MajorVersion, MinorVersion from Metadata \
              \ where Tool = ?"
        params = Only dbToolName

setDBVersion :: Connection -> IO ()
setDBVersion c = execute c sql params
  where sql =  "insert into Metadata (Tool, MajorVersion, MinorVersion) \
              \ values (?, ?, ?)"
        params = (dbToolName, dbMajorVersion, dbMinorVersion)

-- Schema and operations for the Files table.
defineFilesTable :: Connection -> IO ()
defineFilesTable c = execute_ c sql
  where sql = "create table if not exists Files(           \
               \ Hash integer primary key unique not null, \
               \ Name varchar(2048) not null)"

insertFileSQL :: T.Text
insertFileSQL = "insert or ignore into Files (Name, Hash) values (?, ?)"

-- Schema and operations for the Paths table.
definePathsTable :: Connection -> IO ()
definePathsTable c = execute_ c sql
  where sql =  "create table if not exists Paths(   \
               \ Hash integer primary key unique not null, \
               \ Path varchar(2048) not null)"

insertPathSQL :: T.Text
insertPathSQL = "insert or ignore into Paths (Path, Hash) values (?, ?)"

-- Schema and operations for the BuildCommands table.
defineBuildCommandsTable :: Connection -> IO ()
defineBuildCommandsTable c = execute_ c sql
  where sql =  "create table if not exists BuildCommands(  \
               \ Hash integer primary key unique not null, \
               \ Command varchar(2048) not null)"

insertCommandSQL :: T.Text
insertCommandSQL = "insert or ignore into BuildCommands (Command, Hash) values (?, ?)"

-- Schema and operations for the BuildArgs table.
defineBuildArgsTable :: Connection -> IO ()
defineBuildArgsTable c = execute_ c sql
  where sql =  "create table if not exists BuildArgs(      \
               \ Hash integer primary key unique not null, \
               \ Args varchar(2048) not null)"

insertArgsSQL :: T.Text
insertArgsSQL = "insert or ignore into BuildArgs (Args, Hash) values (?, ?)"

-- Schema and operations for the SourceFiles table.
defineSourceFilesTable :: Connection -> IO ()
defineSourceFilesTable c = execute_ c sql
  where sql =  "create table if not exists SourceFiles(        \
               \ File integer primary key unique not null,     \
               \ WorkingDirectory integer not null,            \
               \ BuildCommand integer not null,                \
               \ BuildArgs integer not null,                   \
               \ LastBuilt integer zerofill unsigned not null)"

updateSourceFileSQL :: T.Text
updateSourceFileSQL = "replace into SourceFiles                                     \
                      \(File, WorkingDirectory, BuildCommand, BuildArgs, LastBuilt) \
                      \values (?, ?, ?, ?, ?)"

updateSourceFile :: DBHandle -> CommandInfo -> IO ()
updateSourceFile h (CommandInfo sf wd (Command cmd args) t) = do
    let sfHash = hash sf
    execStatement h insertFileStmt (sf, sfHash)
    let wdHash = hash wd
    execStatement h insertPathStmt (wd, wdHash)
    let cmdHash = hash cmd
    execStatement h insertCommandStmt (cmd, cmdHash)
    let argsJoined = T.intercalate " " args
    let argsHash = hash argsJoined
    execStatement h insertArgsStmt (argsJoined, argsHash)
    execStatement h updateSourceFileStmt (sfHash, wdHash, cmdHash, argsHash, t)

getAllSourceFiles :: DBHandle -> IO [CommandInfo]
getAllSourceFiles h = query_ (conn h) sql
  where sql = "select F.Name, W.Path, C.Command, A.Args, LastBuilt           \
              \ from SourceFiles                                             \
              \ join Files as F on SourceFiles.File = F.Hash                 \
              \ join Paths as W on SourceFiles.WorkingDirectory = W.Hash     \
              \ join BuildCommands as C on SourceFiles.BuildCommand = C.Hash \
              \ join BuildArgs as A on SourceFiles.BuildArgs = A.Hash"

getCommandInfo :: DBHandle -> SourceFile -> IO (Maybe CommandInfo)
getCommandInfo h sf = do
    row <- query (conn h) sql (Only $ hash sf)
    return $ case row of
              (ci : _) -> Just ci
              _        -> Nothing
  where sql = "select F.Name, W.Path, C.Command, A.Args, LastBuilt           \
              \ from SourceFiles                                             \
              \ join Files as F on SourceFiles.File = F.Hash                 \
              \ join Paths as W on SourceFiles.WorkingDirectory = W.Hash     \
              \ join BuildCommands as C on SourceFiles.BuildCommand = C.Hash \
              \ join BuildArgs as A on SourceFiles.BuildArgs = A.Hash        \
              \ where F.Hash = ? limit 1"

-- Eventually this should be more statistical, but right now it will just
-- return an arbitrary file from the same directory.
getSimilarCommandInfo :: DBHandle -> SourceFile -> IO (Maybe CommandInfo)
getSimilarCommandInfo h sf = do
    let path = (++ "%") . normalise . takeDirectory . unSourceFile $ sf
    row <- query (conn h) sql (Only path)
    return $ case row of
              (ci : _) -> Just $ ci { ciSourceFile = sf }
              _        -> Nothing
  where sql = "select F.Name, W.Path, C.Command, A.Args, LastBuilt           \
              \ from SourceFiles                                             \
              \ join Files as F on SourceFiles.File = F.Hash                 \
              \ join Paths as W on SourceFiles.WorkingDirectory = W.Hash     \
              \ join BuildCommands as C on SourceFiles.BuildCommand = C.Hash \
              \ join BuildArgs as A on SourceFiles.BuildArgs = A.Hash        \
              \ where F.Name like ? limit 1"

-- Schema and operations for the Kinds table.
defineKindsTable :: Connection -> IO ()
defineKindsTable c = execute_ c sql
  where sql =  "create table if not exists Kinds(          \
               \ Hash integer primary key unique not null, \
               \ Kind varchar(2048) not null)"

insertKindSQL :: T.Text
insertKindSQL = "insert or ignore into Kinds (Kind, Hash) values (?, ?)"

-- Schema and operations for the Definitions table.
defineDefinitionsTable :: Connection -> IO ()
defineDefinitionsTable c = execute_ c sql
  where sql =  "create table if not exists Definitions(       \
               \ USRHash integer primary key unique not null, \
               \ Name varchar(2048) not null,                 \
               \ USR varchar(2048) not null,                  \
               \ File integer not null,                       \
               \ Line integer not null,                       \
               \ Column integer not null,                     \
               \ Kind integer not null)"

updateDef :: DBHandle -> DefInfo -> IO ()
updateDef h (DefInfo n u (SourceLocation sf l c) k) = do
    let usrHash = hash u
    let sfHash = hash sf
    execStatement h insertFileStmt (sf, sfHash)
    let kindHash = hash k
    execStatement h insertKindStmt (k, kindHash)
    execStatement h updateDefStmt (usrHash, n, u, sfHash, l, c, kindHash)

updateDefSQL :: T.Text
updateDefSQL = "replace into Definitions               \
               \ (USRHash, Name, USR, File, Line, Column, Kind) \
               \ values (?, ?, ?, ?, ?, ?, ?)"

getDef :: DBHandle -> USR -> IO (Maybe DefInfo)
getDef h usr = do
    row <- query (conn h) sql (Only $ hash usr)
    return $ case row of
              (di : _) -> Just di
              _        -> Nothing
  where sql = "select D.Name, D.USR, F.Name, D.Line, D.Column, K.Kind \
              \ from Definitions as D                                 \
              \ join Files as F on D.File = F.Hash                    \
              \ join Kinds as K on D.Kind = K.Hash                    \
              \ where D.USRHash = ? limit 1"
  

-- Checks that the database has the correct schema and sets it up if needed.
ensureSchema :: Connection -> IO ()
ensureSchema c = defineMetadataTable c
              >> defineFilesTable c
              >> definePathsTable c
              >> defineBuildCommandsTable c
              >> defineBuildArgsTable c
              >> defineSourceFilesTable c
              >> defineKindsTable c
              >> defineDefinitionsTable c
              >> ensureVersion c

ensureVersion :: Connection -> IO ()
ensureVersion c = getDBVersion c >>= checkVersion
  where
    checkVersion (Just (major, minor))
                 | (major, minor) == (dbMajorVersion, dbMinorVersion) = return ()
                 | otherwise = throwDBVersionError major minor
    checkVersion _ = setDBVersion c

throwDBVersionError :: Int64 -> Int64 -> IO ()
throwDBVersionError major minor  =  error $ "Database version "
                                 ++ (show major) ++ "." ++ (show minor)
                                 ++ " is different than required version "
                                 ++ (show dbMajorVersion) ++ "."
                                 ++ (show dbMinorVersion)