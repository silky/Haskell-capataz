{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE NoImplicitPrelude     #-}

{-| This module contains all the types used across all the other modules -}
module Control.Concurrent.Capataz.Internal.Types where

import RIO

import Control.Teardown            (HasTeardown (..), Teardown)
import RIO.Time                   (NominalDiffTime, UTCTime)
import Data.UUID                   (UUID)

type CapatazId = UUID
type WorkerId = UUID
type SupervisorId = UUID
type ProcessId = UUID
type WorkerAction m = m ()
type ProcessThreadId = ThreadId
type ProcessName = Text
type CapatazName = Text
type SupervisorName = Text
type WorkerName = Text
type RestartCount = Int
type ProcessMap m = HashMap ProcessId (Process m)
type ParentSupervisor = Supervisor

-- | Event delivered to the 'notifyEvent' callback sub-routine; these events can
-- be used to monitor the capataz system and track what is doing, providing high
-- levels of telemetry for all supervisors and workers of a capataz system,
-- ergo, should be used for logging, monitoring and testing purposes.
--
-- @since 0.1.0.0
data CapatazEvent
  = InvalidSupervisorStatusReached {
    supervisorId   :: !SupervisorId
  , supervisorName :: !SupervisorName
  , eventTime      :: !UTCTime
  }
  | SupervisorStatusChanged {
    supervisorId         :: !SupervisorId
  , supervisorName       :: !SupervisorName
  , prevSupervisorStatus :: !SupervisorStatus
  , newSupervisorStatus  :: !SupervisorStatus
  , eventTime            :: !UTCTime
  }
  | ProcessTerminated {
    supervisorId      :: !SupervisorId
  , supervisorName    :: !SupervisorName
  , processThreadId   :: !ProcessThreadId
  , processId         :: !ProcessId
  , processName       :: !ProcessName
  , processType       :: !ProcessType
  , terminationReason :: !Text
  , eventTime         :: !UTCTime
  }
  | ProcessStarted {
    supervisorId    :: !SupervisorId
  , supervisorName  :: !SupervisorName
  , processThreadId :: !ProcessThreadId
  , processId       :: !ProcessId
  , processName     :: !ProcessName
  , processType     :: !ProcessType
  , eventTime       :: !UTCTime
  }
  | ProcessRestarted {
    supervisorId        :: !SupervisorId
  , supervisorName      :: !SupervisorName
  , processThreadId     :: !ProcessThreadId
  , processId           :: !ProcessId
  , processName         :: !ProcessName
  , processType         :: !ProcessType
  , processRestartCount :: !Int
  , eventTime           :: !UTCTime
  }
  | ProcessCompleted {
    supervisorId    :: !SupervisorId
  , supervisorName  :: !SupervisorName
  , processThreadId :: !ProcessThreadId
  , processId       :: !ProcessId
  , processName     :: !ProcessName
  , processType     :: !ProcessType
  , eventTime       :: !UTCTime
  }
  | ProcessFailed {
    supervisorName  :: !SupervisorName
  , supervisorId    :: !SupervisorId
  , processThreadId :: !ProcessThreadId
  , processId       :: !ProcessId
  , processName     :: !ProcessName
  , processType     :: !ProcessType
  , processError    :: !SomeException
  , eventTime       :: !UTCTime
  }
  | ProcessCallbackExecuted {
    supervisorId         :: !SupervisorId
  , supervisorName       :: !SupervisorName
  , processThreadId      :: !ProcessThreadId
  , processId            :: !ProcessId
  , processName          :: !ProcessName
  , processType          :: !ProcessType
  , processCallbackError :: !(Maybe SomeException)
  , processCallbackType  :: !CallbackType
  , eventTime            :: !UTCTime
  }
  | ProcessTerminationStarted {
    supervisorName    :: !SupervisorName
  , supervisorId      :: !SupervisorId
  , terminationReason :: !Text
  , eventTime         :: !UTCTime
  }
  | ProcessTerminationFinished {
    supervisorName    :: !SupervisorName
  , supervisorId      :: !SupervisorId
  , terminationReason :: !Text
  , eventTime         :: !UTCTime
  }
  | CapatazFailed {
    supervisorId    :: !SupervisorId
  , supervisorName  :: !SupervisorName
  , supervisorError :: !SomeException
  , eventTime       :: !UTCTime
  }
  | CapatazTerminated {
    supervisorName :: !SupervisorName
  , supervisorId   :: !SupervisorId
  , eventTime      :: !UTCTime
  }
  deriving (Generic, Show)

-- | Defines how a 'Worker' process termination should be handled by its
-- supervisor.
--
-- @since 0.0.0.0
data WorkerTerminationPolicy
  -- | Supervisor waits until infinity for the worker termination callback to
  -- finish execution.
  = Infinity

  -- | Supervisor terminates worker process without a chance to call its
  -- termination callback.
  | BrutalTermination

  -- | Supervisor allows a number of milliseconds for worker termination
  --  callback complete, if not completed by specified milliseconds the
  --  termination is cancelled via a "BrutalTermination" signal.
  | TimeoutMillis !Int
  deriving (Generic, Show, Eq, Ord)

-- | Default worker termination is a timeout of three (3) seconds.
--
-- @since 0.2.0.0
defWorkerTerminationPolicy :: WorkerTerminationPolicy
defWorkerTerminationPolicy = TimeoutMillis 3000

instance NFData WorkerTerminationPolicy

-- | Internal helper record that assesses if a Supervisor error intensity has
-- been breached.
data ProcessRestartAction
  -- | Indicates a Supervisor to restart a failed process _and_ reset the
  -- restart count given this Supervisor's intensity period timeout has passed.
  = ResetRestartCount

  -- | Indicates a Supervisor to restart the failed process _and_ increase the restart
  -- count (normal operation) of the supervised process.
  | IncreaseRestartCount

  -- | Indicates a Supervisor stop executing given the error intensity has been
  -- breached.
  | HaltSupervisor
  deriving (Generic, Show, Eq)

instance NFData ProcessRestartAction

-- | Specifies the order in which supervised process should be terminated by a
-- Supervisor in case of a restart or shutdown.
--
-- @since 0.0.0.0
data ProcessTerminationOrder
  -- | Supervisor terminates supervised process from most recent to oldest.
  = NewestFirst
  -- | Supervisor terminates supervised process from oldest to most recent.
  | OldestFirst
  deriving (Generic, Show, Eq, Ord)

-- | Default termination order is 'OldestFirst'.
--
-- @since 0.2.0.0
defProcessTerminationOrder :: ProcessTerminationOrder
defProcessTerminationOrder = OldestFirst

instance NFData ProcessTerminationOrder

-- | Specifies how a Supervisor restarts a failing process.
--
-- @since 0.0.0.0
data SupervisorRestartStrategy
  -- | Supervisor terminates all sibling supervised processes that didn't fail,
  -- and then restarts all of them together. This strategy serves best when all
  -- processes depend upon each other.
  = AllForOne

  -- | Supervisor only restarts the supervised process that failed.
  | OneForOne
  deriving (Generic, Show, Eq, Ord)

-- | Default restart strategy is 'OneForOne'.
--
-- @since 0.2.0.0
defSupervisorRestartStategy :: SupervisorRestartStrategy
defSupervisorRestartStategy = OneForOne

instance NFData SupervisorRestartStrategy

-- | Allows to:
--
-- * Specify options for the root 'Supervisor' of a capataz system.
--
-- * Provide a 'notifyEvent' callback to monitor or log a capataz system.
--
-- @since 0.1.0.0
data CapatazOptions m
  = CapatazOptions {
    supervisorName                    :: !SupervisorName
  , supervisorIntensity               :: !Int
  , supervisorPeriodSeconds           :: !NominalDiffTime
  , supervisorRestartStrategy         :: !SupervisorRestartStrategy
  , supervisorProcessSpecList         :: ![ProcessSpec m]
  , supervisorProcessTerminationOrder :: !ProcessTerminationOrder
  , supervisorOnIntensityReached      :: !(m ())
    -- | Callback sub-routine that gets executed when the root supervisor fails.
  , supervisorOnFailure               :: !(SomeException -> m ())
    -- | Callback used for telemetry purposes.
  , notifyEvent                       :: !(CapatazEvent -> m ())
  }


-- | Specifies how a Supervisor deals with the lifecycle of worker process in
-- case of completion without errors and failure.
data WorkerRestartStrategy
  -- | Supervisor will __always__ restart a worker process, in both completion
  -- and failure scenarios.
  = Permanent

  -- | Supervisor will __only__ restart worker process if it has a failure in
  -- execution.
  | Transient

  -- | Supervisor will __never__ restart a worker, even on failure.
  | Temporary

  deriving (Generic, Show, Eq)

instance NFData WorkerRestartStrategy

-- |  A worker default restart strategy is "Transient".
defWorkerRestartStrategy :: WorkerRestartStrategy
defWorkerRestartStrategy = Transient

-- | Specifies all options that can be used to create a Worker Process. You may
-- create a record of this type via the smart constructor 'buildWorkerOptions'.
--
-- @since 0.1.0.0
data WorkerOptions m
  = WorkerOptions {
    -- | An @IO ()@ sub-routine that will be executed when the worker
    -- thread is created, this attribute is lazy given we want to this
    -- value on a worker thread environment.
    workerAction            :: WorkerAction m
    -- | Name of the Worker (present on "CapatazEvent" records)
  , workerName              :: !WorkerName
    -- | Callback used when the worker fails with an error
  , workerOnFailure         :: !(SomeException -> m ())
    -- | Callback used when the worker completes execution without error
  , workerOnCompletion      :: !(m ())
    -- | Callback used when the worker is terminated
  , workerOnTermination     :: !(m ())
    -- | Indicates how a worker should be terminated
  , workerTerminationPolicy :: !WorkerTerminationPolicy
    -- | Indicates how a worker should be restarted
  , workerRestartStrategy   :: !WorkerRestartStrategy
  }
  deriving (Generic)

-- | Record that contains the "Async" record (thread reference) of a worker
--
-- @since 0.1.0.0
data Worker m
  = Worker {
    -- | Unique identifier for a worker that is executing
    workerId           :: !WorkerId
    -- | "Async" thread of a worker, this Async executes the @IO ()@ sub-routine
  , workerAsync        :: !(Async ())
    -- | Time where this worker was created (used for error intensity checks)
  , workerCreationTime :: !UTCTime
    -- | Name of the Worker (present on "CapatazEvent" records)
  , workerName         :: !WorkerName
    -- | "WorkerOptions" contains all the options around restart and termination
    -- policies
  , workerOptions      :: !(WorkerOptions m)
  }

data ProcessEnv
  = ProcessEnv {
    processId              :: !ProcessId
  , processName            :: !ProcessName
  , processAsync           :: !(Async ())
  , processCreationTime    :: !UTCTime
  , processRestartStrategy :: !WorkerRestartStrategy
  }

data SupervisorOptions m
  = SupervisorOptions {
    -- | Name of the Supervisor (present on "CapatazEvent" records)
    supervisorName                    :: Text
    -- | How many errors is the Supervisor be able to handle; check:
    -- http://erlang.org/doc/design_principles/sup_princ.html#max_intensity
  , supervisorIntensity               :: !Int
    -- | Period of time where the Supervisor can receive "supervisorIntensity" amount
    -- of errors
  , supervisorPeriodSeconds           :: !NominalDiffTime
    -- | What is the "SupervisorRestartStrategy" for this Capataz
  , supervisorRestartStrategy         :: !SupervisorRestartStrategy
    -- | Static set of workers that start as soon as the "Capataz" is created
  , supervisorProcessSpecList         :: ![ProcessSpec m]
    -- | In which order the "Supervisor" record is going to terminate it's workers
  , supervisorProcessTerminationOrder :: !ProcessTerminationOrder
    -- | Callback used when the error intensity is reached
  , supervisorOnIntensityReached      :: !(m ())
  , supervisorOnFailure               :: !(SomeException -> m ())
  }

data Supervisor m
  = Supervisor {
    supervisorId           :: !SupervisorId
  , supervisorName         :: !SupervisorName
  , supervisorOptions      :: !(SupervisorOptions m)
  , supervisorCreationTime :: !UTCTime
  , supervisorAsync        :: !(Async ())
  , supervisorNotify       :: (SupervisorMessage m) -> m ()
  , supervisorEnv          :: !(SupervisorEnv m)
  }

-- | Internal record that represents an action being sent from threads using
-- the Capataz public API.
data ControlAction m
  = ForkWorker {
    workerOptions  :: !(WorkerOptions m)
  , returnWorkerId :: !(WorkerId -> m ())
  }
  | ForkSupervisor {
    supervisorOptions :: !(SupervisorOptions m)
  , returnSupervisor  :: !(Supervisor m -> m ())
  }
  | TerminateProcess {
    processId                :: !ProcessId
  , processTerminationReason :: !Text
  , notifyProcessTermination :: !(Bool -> m ())
  }
  deriving (Generic)

-- | Internal exception thrown to the Capataz loop to indicate termination of
-- execution
data CapatazSignal
  = CapatazFailure
  | RestartProcessException
  | TerminateProcessException {
      processId                :: !ProcessId
    , processTerminationReason :: !Text
    }
  | BrutallyTerminateProcessException {
      processId                :: !ProcessId
    , processTerminationReason :: !Text
    }
    deriving (Generic, Show)

instance Exception CapatazSignal
instance NFData CapatazSignal

-- | Internal exception triggered when a Worker violates error intensity
-- specification
data CapatazError
  = SupervisorIntensityReached {
    processId           :: !ProcessId
  , processName         :: !ProcessName
  , processRestartCount :: !Int
  }
  deriving (Generic, Show)

instance Exception CapatazError
instance NFData CapatazError

-- | Internal record that indicates what type of callback function is being
-- invoked; this is used for telemetry purposes
data CallbackType
  = OnCompletion
  | OnFailure
  | OnTermination
  deriving (Generic, Show, Eq)

data ProcessType
  = SupervisorType
  | WorkerType
  deriving (Show, Eq)

-- | Internal exception triggered when a callback of a Worker fails
data ProcessError
  = ProcessCallbackFailed {
      processId            :: !WorkerId
    , processError         :: !(Maybe SomeException)
    , processCallbackError :: !SomeException
    , processCallbackType  :: !CallbackType
    }
    deriving (Generic, Show)

instance Exception ProcessError

-- | Internal event delivered from Worker threads to the Capataz thread to
-- indicate completion, failure or termination
data MonitorEvent
  = ProcessTerminated' {
    processId                :: !ProcessId
  , processName              :: !ProcessName
  , processRestartCount      :: !RestartCount
  , processTerminationReason :: !Text
  , monitorEventTime         :: !UTCTime
  }
  | ProcessFailed' {
    processId           :: !WorkerId
  , processName         :: !WorkerName
  , processRestartCount :: !RestartCount
  , processError        :: !SomeException
  , monitorEventTime    :: !UTCTime
  }
  | ProcessCompleted' {
    processId        :: !ProcessId
  , processName      :: !ProcessName
  , monitorEventTime :: !UTCTime
  }
  | ProcessForcedRestart {
    processId        :: !ProcessId
  , processName      :: !ProcessName
  , monitorEventTime :: !UTCTime
  }
  deriving (Show)

-- | Internal record used as a state machine, indicating the state of a
-- supervisor process
data SupervisorStatus
  -- | This state is set when the process is created and it starts spawning its
  -- static process list.
  = Initializing
  -- | This state is set when the supervisor process starts listenting to both
  -- "ControlAction" and "MonitorEvent" messages.
  | Running
  -- | This state is set when the supervisor process is terminating it's
  -- assigned worker
  | Halting
  -- | This state is set when the supervisor process is finished
  | Halted
  deriving (Generic, Show, Eq)

instance NFData SupervisorStatus

-- | Internal message delivered to a supervisor process that can either be a
-- call from public API or an event from its monitored worker process.
data SupervisorMessage m
  -- | Represents a request from done to the supervisor thread from another
  -- thread using the public API
  = ControlAction !(ControlAction m)
  -- | Represents an event (failure, completion, etc) from a monitored worker
  -- process to the supervisor
  | MonitorEvent !MonitorEvent
  deriving (Generic)

-- | Internal Type to manage both 'Worker' and 'Supervisor' processes
--
-- @since 0.1.0.0
data Process m
  = WorkerProcess  !(Worker m)
  | SupervisorProcess !(Supervisor m)

-- | Record used to specify how to __build__ a runtime 'Process' in a static
-- supervision tree; to create values of this type, you must use:
--
-- * 'workerSpec' or 'workerSpecWithDefaults' to build a worker process
--
-- * 'supervisorSpec' or 'supervisorSpecWithDefaults' to build a supervisor
-- process
--
-- @since 0.1.0.0
data ProcessSpec m
  = WorkerSpec (WorkerOptions m)
  | SupervisorSpec (SupervisorOptions m)

-- | Record that contains the environment of a capataz monitor, this is used as
-- the main record to create workers and to stop the supervisor thread.
--
-- @since 0.0.0.0
data Capataz m
  = Capataz {
    capatazSupervisor :: !(Supervisor m)
  , capatazTeardown   :: !Teardown
  }

instance HasTeardown (Capataz m) where
  getTeardown Capataz {capatazTeardown} =
    capatazTeardown

-- | Internal utility record used to hold part of the runtime information of a
-- supervisor that acts as a parent of another supervisor.
data ParentSupervisorEnv m
  = ParentSupervisorEnv {
    supervisorId     :: !SupervisorId
  , supervisorName   :: !SupervisorName
  , supervisorNotify :: !((SupervisorMessage m) -> m ())
  , notifyEvent      :: !(CapatazEvent -> m ())
  }

-- | Convenience internal utility record that contains all values related to a
-- supervisor process.
data SupervisorEnv m
  = SupervisorEnv {
    supervisorId                      :: !SupervisorId
  , supervisorName                    :: !SupervisorName
  , supervisorNotify                  :: !((SupervisorMessage m) -> m ())
  , supervisorGetNotification         :: !(STM (SupervisorMessage m))
  , supervisorProcessMap              :: !(IORef (ProcessMap m))
  , supervisorStatusVar               :: !(TVar SupervisorStatus)
  , supervisorOptions                 :: !(SupervisorOptions m)
  , supervisorIntensity               :: !Int
    -- ^ http://erlang.org/doc/design_principles/sup_princ.html#max_intensity
  , supervisorPeriodSeconds           :: !NominalDiffTime
  , supervisorRestartStrategy         :: !SupervisorRestartStrategy
  , supervisorProcessTerminationOrder :: !ProcessTerminationOrder
  , supervisorOnIntensityReached      :: !(m ())
  , supervisorOnIntensityReached      :: !(SomeException -> m ())
  , notifyEvent                       :: !(CapatazEvent -> m ())
  }

-- | Builds a 'CapatazOptions' record with defaults on how to create a capataz
-- root supervisor, these defaults are:
--
-- * Intensity error tolerance is set to 1 error every 5 seconds
--
-- * A 'SupervisorRestartStrategy' of 'OneForOne'
--
-- * A 'ProcessTerminationOrder' of 'OldestFirst'
--
-- This function is intended to be used in combination with 'forkCapataz'.
--
-- @since 0.1.0.0
defCapatazOptions
  :: Monad m
  => Text
  -> (CapatazOptions m -> CapatazOptions m) -- ^ Function to modify root supervisor
  -> CapatazOptions m
defCapatazOptions supervisorName modFn = modFn CapatazOptions
  { supervisorName
  , supervisorIntensity               = 2
  , supervisorPeriodSeconds           = 5
  , supervisorRestartStrategy         = defSupervisorRestartStategy
  , supervisorProcessSpecList         = []
  , supervisorProcessTerminationOrder = OldestFirst
  , supervisorOnIntensityReached      = return ()
  , supervisorOnFailure               = const $ return ()
  , notifyEvent                       = const $ return ()
  }

-- | Builds a 'ProcessSpec' record for a supervisor process with defaults from
-- 'supervisorSpecWithDefaults'. This function allows overrides of these
-- defaults using lenses.
--
-- This function is used when building a supervisor branch in a static
-- supervision trees.
--
-- @since 0.1.0.0
supervisorSpec
  :: Monad m
  => SupervisorName -- ^ Name used for telemetry purposes
  -> (SupervisorOptions m -> SupervisorOptions m) -- ^ 'SupervisorOptions' modifier
  -> ProcessSpec m
supervisorSpec sName modFn =
  SupervisorSpec (buildSupervisorOptions sName modFn)
{-# INLINE supervisorSpec #-}

-- | Builds a 'ProcessSpec' record for a supervisor process with defaults from
--  'buildSupervisorOptionsWithDefaults'.
--
-- This function is used when building a supervisor branch in a static
-- supervision trees.
--
-- @since 0.1.0.0
supervisorSpecWithDefaults
  :: Monad m
  => SupervisorName -- ^ Name used for telemetry purposes
  -> ProcessSpec m
supervisorSpecWithDefaults sName = supervisorSpec sName id
{-# INLINE supervisorSpecWithDefaults #-}

-- | Builds a 'ProcessSpec' record for a worker process with defaults from
-- 'workerSpecWithDefaults'. This function allows overrides of these
-- defaults using lenses.
--
-- This function is used when building a worker in a static supervision tree.
--
-- @since 0.1.0.0
workerSpec
  :: Monad m
  => WorkerName -- ^ Name used for telemetry purposes
  -> m () -- ^ 'IO' sub-routine to be supervised
  -> (WorkerOptions m -> WorkerOptions m) -- ^ Function to modify default worker
                                      -- options
  -> ProcessSpec m
workerSpec wName wAction modFn =
  WorkerSpec (buildWorkerOptions wName wAction modFn)
{-# INLINE workerSpec #-}

-- | Builds a 'ProcessSpec' record for a worker process with defaults from
-- 'buildSupervisorOptionsWithDefaults'.
--
-- This function is used when building a worker in a static supervision tree.
--
-- @since 0.1.0.0
workerSpecWithDefaults
  :: Monad m
  => WorkerName -- ^ Name used for telemetry purposes
  -> m () -- ^ IO sub-routine to be supervised
  -> ProcessSpec m
workerSpecWithDefaults wName wAction = workerSpec wName wAction id
{-# INLINE workerSpecWithDefaults #-}

-- | Builds a 'SupervisorOptions' record with defaults from
-- 'buildSupervisorOptionsWithDefaults'. This function allows overrides of these
-- defaults using lenses.
--
-- This function is intended to be used in combination with 'forkSupervisor'.
--
-- @since 0.1.0.0
buildSupervisorOptions
  :: Monad m
  => SupervisorName -- ^ Name used for telemetry purposes
  -> (SupervisorOptions m -> SupervisorOptions m) -- ^ Function to modify default
                                              -- supervisor options
  -> SupervisorOptions m
buildSupervisorOptions supervisorName modFn = modFn SupervisorOptions
  { supervisorName
  , supervisorIntensity               = 2
  , supervisorPeriodSeconds           = 5
  , supervisorRestartStrategy         = defSupervisorRestartStategy
  , supervisorProcessSpecList         = []
  , supervisorProcessTerminationOrder = OldestFirst
  , supervisorOnIntensityReached      = return ()
  , supervisorOnFailure               = const $ return ()
  }
{-# INLINE buildSupervisorOptions #-}

-- | Builds a 'SupervisorOptions' record with defaults to create a supervisor
-- process, these defaults are:
--
-- * Intensity error tolerance is set to 1 error every 5 seconds
--
-- * A 'SupervisorRestartStrategy' of 'OneForOne'
--
-- * A 'ProcessTerminationOrder' of 'OldestFirst'
--
-- This function is intended to be used in combination with 'forkSupervisor'.
--
-- @since 0.1.0.0
buildSupervisorOptionsWithDefaults
  :: Monad m
  => SupervisorName -- ^ Name used for telemetry purposes
  -> SupervisorOptions m
buildSupervisorOptionsWithDefaults = flip buildSupervisorOptions id
{-# INLINE buildSupervisorOptionsWithDefaults #-}

-- | Builds a 'WorkerOptions' record, keeps the defaults from
--   'buildWorkerOptionsWithDefaults' but allows overrides using lenses.
--
-- This function is intended to be used in combination with 'forkWorker'. See the
-- capataz-simple-example project in the examples directory for a demonstration.
--
-- @since 0.1.0.0
buildWorkerOptions
  :: Monad m
  => WorkerName -- ^ Name used for telemetry purposes
  -> m () -- ^ Process sub-routine to be supervised
  -> (WorkerOptions m -> WorkerOptions m) -- ^ Function to modify default worker
                                      -- options
  -> WorkerOptions m
buildWorkerOptions workerName workerAction f = f WorkerOptions
  { workerName
  , workerAction
  , workerOnFailure         = const $ return ()
  , workerOnCompletion      = return ()
  , workerOnTermination     = return ()
  , workerTerminationPolicy = defWorkerTerminationPolicy
  , workerRestartStrategy   = defWorkerRestartStrategy
  }
{-# INLINE buildWorkerOptions #-}

-- | Builds a 'WorkerOptions' record with defaults to create a worker process,
-- the defaults are:
--
-- * A 'Transient' 'WorkerRestartStrategy'
--
-- * A 'WorkerTerminationPolicy' of a 3 seconds timeout
--
-- * A _completion_ callback that just returns unit
--
-- * A _termination_ callback that just returns unit
--
-- * A _failure_ callback that just returns unit
--
-- This function is intended to be used in combination with 'forkWorker', for creating a
-- worker in an static supervision tree, use "workerSpecWithDefaults" instead. See the
-- capataz-simple-example project in the examples directory for a demonstration.
--
-- @since 0.1.0.0
buildWorkerOptionsWithDefaults
  :: Monad m
  => WorkerName -- ^ Name used for telemetry purposes
  -> m () -- ^ 'IO' sub-routine to be supervised
  -> WorkerOptions m
buildWorkerOptionsWithDefaults wName wAction =
  buildWorkerOptions wName wAction id
{-# INLINE buildWorkerOptionsWithDefaults #-}
