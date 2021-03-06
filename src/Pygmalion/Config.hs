{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Pygmalion.Config
( Config(..)
, getConfiguration
) where

import Control.Applicative
import Control.Monad
import Data.Int
import Data.Yaml
import qualified Data.ByteString as B
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath.Posix (takeDirectory, (</>))
import Text.Libyaml (Event(..))

import Pygmalion.Core
import Pygmalion.Log

-- The make command is a shell command specified as a format string
-- with the following substitutions:
-- $(idx)      - The indexer.
-- $(idxargs)  - Arguments for the indexer.
-- $(cc)       - The C compiler.
-- $(ccargs)   - Arguments for the C compiler.
-- $(cpp)      - The C++ compiler.
-- $(cppargs)  - Arguments for the C++ compiler.
-- $(makeargs) - Arguments for make.
--
-- A default format string for GNU make is below.
-- For CMake, this would work:
-- cmake $(makeargs)
--   -DCMAKE_C_COMPILER="$(idx)"
--   -DCMAKE_C_FLAGS="$(idxargs) $(cc) $(ccargs)"
--   -DCMAKE_CXX_COMPILER="$(idx)"
--   -DCMAKE_CXX_FLAGS="$(idxargs) $(cxx) $(cxxargs)"

data Config = Config
  { ifAddr     :: String   -- Address of interface to bind to.
  , ifPort     :: Port     -- Port to bind to.
  , makeCmd    :: String   -- Format string for the make command. See above.
  , makeArgs   :: String   -- Format string for the make command. See above.
  , ccCmd      :: String   -- C compiler executable to use.
  , ccArgs     :: String   -- Extra C compiler args, if any.
  , cppCmd     :: String   -- C++ compiler executable to use.
  , cppArgs    :: String   -- Extra C++ compiler args, if any.
  , idxCmd     :: String   -- Indexer command to use. INTERNAL USE ONLY. (For now.)
  , idxThreads :: Int      -- Number of indexing threads to run.
  , genCDB     :: Bool     -- If true, pygmake generates a CDB automatically.
  , genTAGS    :: Bool     -- If true, pygmake generates a TAGS file automatically.
  , idleDelay  :: Int64    -- Numbers of seconds with no activity before we're idle.
  , logLevel   :: Priority -- The level of logging to enable.
  , projectDir :: FilePath -- The location of ".pygmalion". Set automatically.
  } deriving (Eq, Show)

defaultConfig :: Config
defaultConfig = Config
  { ifAddr     = "127.0.0.1"
  , ifPort     = 7999
  , makeCmd    = "make CC=\"$(idx) $(idxargs) $(cc) $(ccargs)\" " ++
                 "CXX=\"$(idx) $(idxargs) $(cpp) $(cppargs)\" $(makeargs)"
  , makeArgs   = ""
  , ccCmd      = "clang"
  , ccArgs     = ""
  , cppCmd     = "clang++"
  , cppArgs    = ""
  , idxCmd     = "pygindex-clang"
  , idxThreads = 4
  , genCDB     = False
  , genTAGS    = False
  , idleDelay  = 1
  , logLevel   = INFO
  , projectDir = ""
  }

instance FromJSON Priority where
  parseJSON (String s)
    | s == "debug"     = return DEBUG
    | s == "info"      = return INFO
    | s == "notice"    = return NOTICE
    | s == "warning"   = return WARNING
    | s == "error"     = return ERROR
    | s == "critical"  = return CRITICAL
    | s == "alert"     = return ALERT
    | s == "emergency" = return EMERGENCY
  parseJSON _ = mzero

instance FromJSON Config where
  parseJSON (Object o) =
    Config <$> o .:? "address"             .!= ifAddr defaultConfig
           <*> o .:? "port"                .!= ifPort defaultConfig
           <*> o .:? "make"                .!= makeCmd defaultConfig
           <*> o .:? "makeArgs"            .!= makeArgs defaultConfig
           <*> o .:? "cc"                  .!= ccCmd defaultConfig
           <*> o .:? "ccArgs"              .!= ccArgs defaultConfig
           <*> o .:? "cpp"                 .!= cppCmd defaultConfig
           <*> o .:? "cppArgs"             .!= cppArgs defaultConfig
           <*> o .:? "indexer"             .!= idxCmd defaultConfig
           <*> o .:? "indexingThreads"     .!= idxThreads defaultConfig
           <*> o .:? "compilationDatabase" .!= genCDB defaultConfig
           <*> o .:? "tags"                .!= genTAGS defaultConfig
           <*> o .:? "idleDelay"           .!= idleDelay defaultConfig
           <*> o .:? "logLevel"            .!= logLevel defaultConfig
           <*> pure (projectDir defaultConfig)
  parseJSON _ = mzero

findConfigFile :: FilePath -> IO (FilePath, FilePath)
findConfigFile dir = do
  let dirConfigFile = dir </> configFile
  exists <- doesFileExist dirConfigFile

  case (exists, dir) of
    (True, _)    -> return (dir, dirConfigFile)
    (False, "")  -> error "Couldn't locate pygmalion configuration file"
    (False, "/") -> error "Couldn't locate pygmalion configuration file"
    _            -> findConfigFile $ takeDirectory dir

checkError :: FilePath -> ParseException -> IO Config
checkError dir (UnexpectedEvent Nothing
                (Just EventStreamStart)) = return $ defaultConfig { projectDir = dir }
checkError dir (UnexpectedEvent (Just EventStreamEnd)
                (Just EventDocumentStart)) = return $ defaultConfig { projectDir = dir }
checkError _ ex = reportError . show $ ex

reportError :: String -> IO a
reportError err = error $ "Couldn't parse configuration file: " ++ err

checkConfig :: FilePath -> Config -> IO Config
checkConfig dir conf@Config { ifPort = port }
  | port == 0 = reportError "Port 0 is invalid"
  | otherwise = return $ conf { projectDir = dir }

getConfiguration :: IO Config
getConfiguration = do
  (dir, conf) <- findConfigFile =<< getCurrentDirectory
  result <- decodeEither' <$> B.readFile conf
  either (checkError dir) (checkConfig dir) result
