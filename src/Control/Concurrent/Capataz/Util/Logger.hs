{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Offers functions to build a supervised thread dedicated to logging all the
-- application traces
--
-- | @since 0.2.1.0
module Control.Concurrent.Capataz.Util.Logger
  (
    buildLogWorkerSpec
  , buildLogWorkerOptions
  )
  where

import RIO
import Control.Concurrent.Capataz

data LogMsg
  = LogMsg
  {
    lmCallStack :: !CallStack
  , lmThreadId  :: !ThreadId
  , lmLogSource :: !LogSource
  , lmLogLevel  :: !LogLevel
  , lmPayload   :: !Utf8Builder
  }


runLoggerThread :: MonadUnliftIO m => LogOptions -> TBQueue LogMsg -> m a
runLoggerThread logOptions inputQueue = withLogFunc logOptions $ \logFunc ->
  runRIO logFunc $ forever $ do
    logMsg <- atomically $ readTBQueue inputQueue
    let LogMsg { lmCallStack, lmThreadId, lmLogSource, lmLogLevel, lmPayload } = logMsg
    -- TODO: create a ticket for a logGenericWithStack function in rio
    logGenericFromThread lmCallStack lmThreadId lmLogSource lmLogLevel lmPayload

-- | Builds a 'ProcessSpec' that spawns a thread that logs messages written with
-- the returned 'LogFunc'. Use this function when your want your logger to be
-- part of a static supervision tree.
--
--
-- __IMPORTANT__ If you use the returned 'LogFunc' to log functions and the
-- 'ProcessSpec' is not used in a supervision tree, your logging won't work and
-- your application will eventually block the current thread when logging.
--
-- A minimal example:
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE NoImplicitPrelude #-}
-- import RIO
-- import Capataz
--
-- main :: IO ()
-- main = do
--   logOptions <- logOptionsHandle stdout True
--   (loggerSpec, logFunc) <- buildLogWorkerSpec logOptions "app-logger" 100 id
--   runRIO logFunc $ do
--     bracket (forkCapataz "application" (set supervisorProcessSpecListL [loggerSpec]))
--             terminateCapataz_ $ \_capataz -> do
--       logInfo "this log message is written by a dedicated supervised thread"
--       threadDelay 1000100
-- @
--
-- @since 0.2.0.0
buildLogWorkerSpec
  :: (MonadUnliftIO m, MonadIO m0)
  => LogOptions  -- ^ options for the 'LogFunc' instance
  -> WorkerName  -- ^ name of the logger worker process
  -> Int         -- ^ how many log messages can be in-flight when writer is slow?
  -> (WorkerOptions m -> WorkerOptions m) -- ^ worker process modifier
  -> m0 (ProcessSpec m, LogFunc)
buildLogWorkerSpec logOptions procName bufferSize modOptions = do
  inputQueue <- newTBQueueIO bufferSize
  let myLogFunc =
        mkLogFunc $ \lmCallStack lmThreadId lmLogSource lmLogLevel lmPayload -> do
          minLevel <- getLogMinLevel logOptions
          when (lmLogLevel >= minLevel)
            $ atomically
                (writeTBQueue
                  inputQueue
                  LogMsg {lmCallStack , lmThreadId ,  lmLogSource , lmLogLevel , lmPayload }
                )

      loggerSpec = workerSpec
        procName
        (runLoggerThread logOptions inputQueue)
        (modOptions . set workerRestartStrategyL Permanent)

  return (loggerSpec, myLogFunc)

-- | Builds a 'WorkerOptions' record that spawns a thread that logs messages
-- written with the returned 'LogFunc'. Use this function if you want to build a
-- logger thread dynamically via 'forkWorker'.
--
--
-- __IMPORTANT__ If you use the returned 'LogFunc' to log functions and the
-- 'WorkerOptions' is not used in a 'forkWorker' call, your logging won't work
-- and your application will eventually block the current thread when logging.
--
-- A minimal example:
--
-- @
-- {-# LANGUAGE OverloadedStrings #-}
-- {-# LANGUAGE NoImplicitPrelude #-}
-- import RIO
-- import Capataz
--
-- main :: IO ()
-- main = do
--   logOptions <- logOptionsHandle stdout True
--   (loggerOptions, logFunc) <- buildLogWorkerOptions logOptions "app-logger" 100 id
--   runRIO logFunc $ do
--     bracket (forkCapataz "application" id)
--             terminateCapataz_ $ \capataz -> do
--       _workerId <- forkWorker loggerOptions capataz
--       logInfo "this log message is written by a dedicated supervised thread"
--       threadDelay 1000100
-- @
--
-- @since 0.2.0.0
buildLogWorkerOptions
  :: (MonadUnliftIO m, MonadIO m0)
  => LogOptions
  -> WorkerName
  -> Int
  -> (WorkerOptions m -> WorkerOptions m)
  -> m0 (WorkerOptions m, LogFunc)
buildLogWorkerOptions logOptions procName bufferSize modOptions = do
  inputQueue <- newTBQueueIO bufferSize
  let myLogFunc =
        mkLogFunc $ \lmCallStack lmThreadId lmLogSource lmLogLevel lmPayload -> atomically
          (writeTBQueue
            inputQueue
            LogMsg {lmCallStack , lmThreadId, lmLogSource , lmLogLevel , lmPayload }
          )

      loggerSpec = buildWorkerOptions
        procName
        (runLoggerThread logOptions inputQueue)
        (modOptions . set workerRestartStrategyL Permanent)

  return (loggerSpec, myLogFunc)
