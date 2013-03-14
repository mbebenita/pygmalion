{-# LANGUAGE DeriveDataTypeable #-}

module Pygmalion.Analyze.Source
( clangGetIncludes
) where

import Clang.Alloc.Storable()
import Clang.File
import Clang.FFI
import Clang.TranslationUnit
import Control.Exception
import Data.IORef
import Data.Maybe
import Data.Typeable
import Foreign.StablePtr

import Pygmalion.Core

data ClangException = ClangException String
  deriving (Show, Typeable)
instance Exception ClangException

withStablePtr :: a -> (StablePtr a -> IO b) -> IO b
withStablePtr v = bracket (newStablePtr v) (freeStablePtr)

clangAnalyze :: CommandInfo -> (TranslationUnit -> IO ()) -> IO ()
clangAnalyze (CommandInfo sf _ (Command _ args) _) f = do
    withCreateIndex False False $ \index -> do
      withParse index (Just sf) args [] [TranslationUnit_None] f bail
  where
    bail = throw . ClangException $ "Libclang couldn't parse " ++ sf

clangGetIncludes :: CommandInfo -> IO (Maybe [FilePath])
clangGetIncludes ci = do
    headersRef <- newIORef []
    result <- try $ clangAnalyze ci (getHeaders headersRef)
    case result of
      Right _                 -> readIORef headersRef >>= return . Just
      Left (ClangException _) -> return Nothing
  where
    getHeaders hsRef tu = withStablePtr hsRef $ \hsRefPtr ->
      getInclusions tu visitInclusions (Just hsRefPtr)
    visitInclusions :: InclusionVisitor (StablePtr (IORef [String]))
    visitInclusions file _ hsRefPtr = do
      let name = getName file
      case null name of
        True -> putStrLn "Got null filename"
        False -> do
          hsRef <- deRefStablePtr . fromJust $ hsRefPtr
          modifyIORef hsRef $ \hs -> name : hs
      return hsRefPtr
