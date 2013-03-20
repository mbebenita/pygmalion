import Control.Applicative
import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception (Exception, throw)
import Control.Monad
import Data.List
import System.Environment
import System.Exit
import System.Process

import Pygmalion.Analyze
import Pygmalion.Core
import Pygmalion.Config
import Pygmalion.Database
import Pygmalion.JSON
import Pygmalion.RPC.Server

main :: IO ()
main = do
  args <- (getArgs >>= parseArgs)
  ensureDB dbFile
  cf <- getConfiguration
  port <- newEmptyMVar
  chan <- newChan
  withAsyncBound (runAnalysisThread chan) $ \analysis -> do
    ensureSuccess =<< (race (runRPCServer cf port chan) (executeMake cf port args))
    writeChan chan Nothing  -- Signifies end of data.
    ensureNoException =<< waitCatch analysis
  when (makeCDB cf) writeCompileCommands

usage :: IO a
usage = putStrLn ("Usage: " ++ makeExecutable ++ " [make arguments]")
     >> exitWith (ExitFailure (-1))

parseArgs :: [String] -> IO [String]
parseArgs ["--help"] = usage
parseArgs ["-h"]     = usage
parseArgs as         = return as

executeMake:: Config -> MVar Int -> [String] -> IO ExitCode
executeMake cf portVar args = do
    combinedArgs <- newArgs . show <$> readMVar portVar
    (_, _, _, handle) <- createProcess $ proc (make cf) combinedArgs
    waitForProcess handle
  where
    newArgs port = [compilerEnvVar "CC" port cc ccArgs,
                    compilerEnvVar "CXX" port cpp cppArgs]
                   ++ (makeArgs cf) ++ args
    compilerEnvVar var port cmd cmdArgs = intercalate " " $
      [(var ++ "=" ++ scanExecutable), "--make", port, cmd cf] ++ (cmdArgs cf)

ensureSuccess :: Either () ExitCode -> IO ()
ensureSuccess (Right code@(ExitFailure _)) = exitWith code
ensureSuccess (Right _)                    = return ()
ensureSuccess _                            = error "RPC server terminated early"

ensureNoException :: Exception a => Either a b -> IO b
ensureNoException (Right v) = return v
ensureNoException (Left e)  = putStrLn "Analysis thread threw an exception" >> throw e

writeCompileCommands :: IO ()
writeCompileCommands = withDB dbFile $ \h -> do
  getAllSourceFiles h >>= (writeFile compileCommandsFile) . sourceRecordsToJSON
