{-# LANGUAGE DeriveGeneric, OverloadedStrings #-}

module Pygmalion.Core
( CommandInfo (..)
, SourceFile
, SourceFileHash
, SourceFileWrapper (..)
, WorkingPath
, Time
, Language (..)
, Inclusion (..)
, DefInfo (..)
, DefUpdate (..)
, SourceLocation (..)
, SourceRange (..)
, Identifier
, USRHash
, SourceLine
, SourceCol
, SourceKind (..)
, Override (..)
, Invocation (..)
, Reference (..)
, ReferenceUpdate (..)
, SourceReferenced (..)
, SourceReference (..)
, SourceContext
, Port
, mkSourceFile
, unSourceFile
--, unSourceFileText
, queryExecutable
, makeExecutable
, daemonExecutable
, indexExecutable
, pygmalionDir
, dbFile
, configFile
, compileCommandsFile
, tagsFile
) where

import Control.Applicative
import qualified Data.ByteString.UTF8 as B
import Data.Int
import Data.Serialize
import Database.SQLite.Simple (FromRow(..), field)
import GHC.Generics
import System.FilePath.Posix ((</>))

import Pygmalion.SourceKind

type Port = Int

-- The information we collect about a compilation command.
data CommandInfo = CommandInfo
  { ciSourceFile  :: !SourceFile
  , ciWorkingPath :: !WorkingPath
  , ciCommand     :: !B.ByteString
  , ciArgs        :: ![B.ByteString]
  , ciLanguage    :: !Language
  , ciLastMTime   :: !Time
  , ciLastIndexed :: !Time
  } deriving (Eq, Read, Show, Generic)

{-
instance Serialize T.Text where
  put = put . TE.encodeUtf16BE
  get = liftM (TE.decodeUtf16BEWith onError) get
      where onError _ _ = Nothing
-}

instance Serialize CommandInfo

instance FromRow CommandInfo where
  fromRow = CommandInfo <$> field               -- ciSourceFile
                        <*> field               -- ciWorkingPath
                        <*> field               -- ciCommand
                        <*> (B.lines <$> field) -- ciArgs
                        <*> fromRow             -- ciLanguage
                        <*> field               -- ciLastMTime
                        <*> field               -- ciLastIndexed

type SourceFile = B.ByteString
type SourceFileHash = Int64

mkSourceFile :: FilePath -> SourceFile
mkSourceFile = B.fromString

unSourceFile :: SourceFile -> FilePath
unSourceFile = B.toString

data SourceFileWrapper = SourceFileWrapper
  { unwrapSourceFile :: !SourceFile
  } deriving (Eq, Show)

instance FromRow SourceFileWrapper where
  fromRow = SourceFileWrapper <$> field

type WorkingPath = B.ByteString
type Time = Int64

data Language = CLanguage
              | CPPLanguage
              | UnknownLanguage
              deriving (Eq, Enum, Generic, Ord, Read, Show)

instance Serialize Language

instance FromRow Language where
  fromRow = toEnum <$> field

-- | Inclusion metadata.
data Inclusion = Inclusion
    { icCommandInfo :: !CommandInfo  -- ^ Information about the included file.
    , icSourceFile  :: !SourceFile   -- ^ The file which does the including.
    , icDirect      :: !Bool         -- ^ Is it included directly?
    } deriving (Eq, Show, Generic)

instance Serialize Inclusion

-- The information we collect about definitions in source code.
data DefInfo = DefInfo
    { diIdentifier     :: !Identifier
    , diUSR            :: !USRHash
    , diSourceLocation :: !SourceLocation
    , diDefKind        :: !SourceKind
    , diContext        :: !USRHash
    } deriving (Eq, Show, Generic)

instance Serialize DefInfo

instance FromRow DefInfo where
  fromRow = DefInfo <$> field <*> field <*> fromRow <*> fromRow <*> field

-- Cheaper variant of DefInfo used for database updates.
data DefUpdate = DefUpdate
    { diuIdentifier :: !Identifier
    , diuUSR        :: !USRHash
    , diuFileHash   :: !SourceFileHash
    , diuLine       :: !SourceLine
    , diuCol        :: !SourceCol
    , diuDefKind    :: !SourceKind
    , diuContext    :: !USRHash
    } deriving (Eq, Show, Generic)

instance Serialize DefUpdate

data SourceLocation = SourceLocation
    { slFile :: !SourceFile
    , slLine :: !SourceLine
    , slCol  :: !SourceCol
    } deriving (Eq, Show, Generic)

instance Serialize SourceLocation

instance FromRow SourceLocation where
  fromRow = SourceLocation <$> field <*> field <*> field

data SourceRange = SourceRange
    { srFile    :: !SourceFile
    , srLine    :: !SourceLine
    , srCol     :: !SourceCol
    , srEndLine :: !SourceLine
    , srEndCol  :: !SourceCol
    } deriving (Eq, Show, Generic)

instance Serialize SourceRange

instance FromRow SourceRange where
  fromRow = SourceRange <$> field <*> field <*> field <*> field <*> field

type Identifier = B.ByteString
type USRHash    = Int64
type RefHash    = Int64
type SourceLine = Int
type SourceCol  = Int

-- This would be the cheaper variant of Override, but we never return these
-- directly from queries (we always return DefInfos) so we don't need the full
-- version at all.
data Override = Override
    { orDef       :: !USRHash
    , orOverrided :: !USRHash
    } deriving (Eq, Show, Generic)

instance Serialize Override

data Invocation = Invocation
    { ivDefInfo        :: !DefInfo
    , ivSourceLocation :: !SourceLocation
    } deriving (Eq, Show, Generic)

instance Serialize Invocation

instance FromRow Invocation where
  fromRow = Invocation <$> fromRow <*> fromRow

data Reference = Reference
    { rfRange   :: !SourceRange
    , rfKind    :: !SourceKind
    , rfContext :: !USRHash
    , rfUSR     :: !USRHash
    } deriving (Eq, Show, Generic)

instance Serialize Reference

-- Cheaper variant of Reference used for database updates.
data ReferenceUpdate = ReferenceUpdate
    { rfuId          :: !RefHash
    , rfuFileHash    :: !SourceFileHash
    , rfuLine        :: !SourceLine
    , rfuCol         :: !SourceCol
    , rfuEndLine     :: !SourceLine
    , rfuEndCol      :: !SourceCol
    , rfuKind        :: !SourceKind
    , rfuViaHash     :: !USRHash
    , rfuDeclHash    :: !RefHash
    , rfuContextHash :: !USRHash
    , rfuUSRHash     :: !USRHash
    } deriving (Eq, Show, Generic)

instance Serialize ReferenceUpdate

data SourceReferenced = SourceReferenced
    { sdDef      :: !DefInfo
    , sdRange    :: !SourceRange
    , sdKind     :: !SourceKind
    , sdViaHash  :: !USRHash
    , sdDeclHash :: !RefHash
    } deriving (Eq, Show, Generic)

instance Serialize SourceReferenced

instance FromRow SourceReferenced where
  fromRow = SourceReferenced <$> fromRow <*> fromRow <*> fromRow <*> field <*> field

data SourceReference = SourceReference
    { srLocation :: !SourceLocation
    , srKind     :: !SourceKind
    , srContext  :: !SourceContext
    } deriving (Eq, Show, Generic)

instance Serialize SourceReference

instance FromRow SourceReference where
  fromRow = SourceReference <$> fromRow <*> fromRow <*> field

type SourceContext = B.ByteString

-- Tool names.
queryExecutable, makeExecutable, daemonExecutable, indexExecutable :: String
queryExecutable  = "pygmalion"
makeExecutable   = "pygmake"
daemonExecutable = "pygd"
indexExecutable  = "pygindex-clang"

-- Data files.
pygmalionDir, dbFile, configFile, compileCommandsFile, tagsFile :: FilePath
pygmalionDir        = ".pygmalion"
dbFile              = pygmalionDir </> "index.sqlite"
configFile          = pygmalionDir </> "pygmalion.yaml"
compileCommandsFile = "compile_commands.json"
tagsFile            = "TAGS"
