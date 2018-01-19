{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-| This module contains:

* Assertion functions to get attributes from a `CapatazEvent`

* Helpers to run the test (reduce boilerplate)

* Actual tests

Tests just exercises the __public API__ and asserts all the events delivered via
the @notifyEvent@ callback are what we are expecting.

NOTE: This tests may be flaky depending on the load of the application, there is
a ticket pending to add dejafu tests to ensure our tests are stable.

-}
module Control.Concurrent.CapatazTest (tests) where

import Protolude

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

import Control.Concurrent.STM.TVar (modifyTVar', newTVarIO, readTVar)

import qualified Control.Concurrent.Capataz as SUT

import Test.Util

--------------------------------------------------------------------------------
-- Actual Tests

tests :: TestTree
tests = testGroup
  "capataz core"
  [ testGroup
    "capataz without workerOptionsList"
    [ testCase "initialize and teardown works as expected" $ testCapatazStream
        [ andP
            [ assertEventType SupervisorStatusChanged
            , assertSupervisorStatusChanged SUT.Initializing SUT.Running
            ]
        ]
        (const $ return ())
        []
        [ andP
          [ assertEventType SupervisorStatusChanged
          , assertSupervisorStatusChanged SUT.Running SUT.Halting
          ]
        , andP
          [ assertEventType SupervisorStatusChanged
          , assertSupervisorStatusChanged SUT.Halting SUT.Halted
          ]
        ]
        Nothing
    ]
  , testGroup
    "capataz with processSpecList"
    [ testCase "initialize and teardown of workers works as expected"
      $ testCapatazStreamWithOptions
          ( \supOptions -> supOptions
            { SUT.supervisorProcessSpecList = [ SUT.WorkerSpec
                                                $ SUT.defWorkerOptions
                                                    { SUT.workerName   = "A"
                                                    , SUT.workerAction = forever
                                                      (threadDelay 10001000)
                                                    }
                                              , SUT.WorkerSpec
                                                $ SUT.defWorkerOptions
                                                    { SUT.workerName   = "B"
                                                    , SUT.workerAction = forever
                                                      (threadDelay 10001000)
                                                    }
                                              ]
            }
          )
          [ assertWorkerStarted "A"
          , assertWorkerStarted "B"
          , andP
            [ assertEventType SupervisorStatusChanged
            , assertSupervisorStatusChanged SUT.Initializing SUT.Running
            ]
          ]
          (const $ return ())
          []
          [ andP
            [ assertEventType SupervisorStatusChanged
            , assertSupervisorStatusChanged SUT.Running SUT.Halting
            ]
          , assertEventType ProcessTerminationStarted
          , assertWorkerTerminated "A"
          , assertWorkerTerminated "B"
          , assertEventType ProcessTerminationFinished
          , andP
            [ assertEventType SupervisorStatusChanged
            , assertSupervisorStatusChanged SUT.Halting SUT.Halted
            ]
          ]
          Nothing
    , testCase "reports error when capataz thread receives async exception"
      $ testCapatazStream
          [ andP
              [ assertEventType SupervisorStatusChanged
              , assertSupervisorStatusChanged SUT.Initializing SUT.Running
              ]
          ]
          ( \capataz -> cancelWith (SUT.getSupervisorAsync capataz)
                                   (ErrorCall "async exception")
          )
          [assertEventType CapatazFailed]
          []
          Nothing
    , testCase "reports error when worker retries violate restart intensity"
      $ do
          lockVar <- newEmptyMVar
          let (signalIntensityReached, waitTillIntensityReached) =
                (putMVar lockVar (), takeMVar lockVar)
          testCapatazStreamWithOptions
            ( \supOptions -> supOptions
              { SUT.supervisorOnIntensityReached = signalIntensityReached
              }
            )
            []
            ( \capataz -> do
              _workerId <- SUT.forkWorker SUT.defWorkerOptions
                                          "test-worker"
                                          (throwIO RestartingWorkerError)
                                          capataz
              waitTillIntensityReached
            )
            [ assertEventType ProcessFailed
            , assertEventType ProcessFailed
            , assertEventType ProcessFailed
            , assertCapatazFailedWith "SupervisorIntensityReached"
            ]
            []
            Nothing
    , testGroup
      "single supervised worker"
      [ testGroup
        "callbacks"
        [ testGroup
          "workerOnCompletion"
          [ testCase
              "does execute callback when worker sub-routine is completed"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (return ())
                    capataz
                  return ()
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnCompletion
                  ]
                , assertEventType ProcessCompleted
                ]
                []
                Nothing
          , testCase "does not execute callback when worker sub-routine fails"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (throwIO RestartingWorkerError)
                    capataz
                  return ()
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnFailure
                  ]
                , assertEventType ProcessFailed
                ]
                [assertEventType CapatazTerminated]
                ( Just $ not . andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnCompletion
                  ]
                )
          , testCase
              "does not execute callback when worker sub-routine is terminated"
            $ testCapatazStream
                []
                ( \capataz -> do
                  workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-wroker"
                    (forever $ threadDelay 1000100)
                    capataz

                  _workerId <- SUT.terminateProcess
                    "testing onCompletion callback"
                    workerId
                    capataz
                  return ()
                )
                [assertEventType ProcessTerminated]
                [assertEventType CapatazTerminated]
                ( Just $ not . andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnCompletion
                  ]
                )
          , testCase "treats as worker sub-routine failed if callback fails"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      , SUT.workerOnCompletion    = throwIO TimeoutError
                      }
                    )
                    "test-worker"
                    (return ())
                    capataz

                  return ()
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnCompletion
                  , assertErrorType "TimeoutError"
                  ]
                , andP
                  [ assertEventType ProcessFailed
                  , assertErrorType "ProcessCallbackFailed"
                  ]
                ]
                []
                Nothing
          ]
        , testGroup
          "workerOnFailure"
          [ testCase "does execute callback when worker sub-routine fails"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (throwIO RestartingWorkerError)
                    capataz
                  return ()
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnFailure
                  ]
                , assertEventType ProcessFailed
                ]
                [assertEventType CapatazTerminated]
                Nothing
          , testCase
              "does not execute callback when worker sub-routine is completed"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (return ())
                    capataz
                  return ()
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnCompletion
                  ]
                , assertEventType ProcessCompleted
                ]
                []
                ( Just
                $ not
                . andP
                    [ assertEventType ProcessCallbackExecuted
                    , assertCallbackType SUT.OnFailure
                    ]
                )
          , testCase
              "does not execute callback when worker sub-routine is terminated"
            $ testCapatazStream
                []
                ( \capataz -> do
                  workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (forever $ threadDelay 1000100)
                    capataz

                  SUT.terminateProcess "testing onFailure callback"
                                       workerId
                                       capataz
                )
                [assertEventType ProcessTerminated]
                []
                ( Just
                $ not
                . andP
                    [ assertEventType ProcessCallbackExecuted
                    , assertCallbackType SUT.OnFailure
                    ]
                )
          , testCase "treats as worker sub-routine failed if callback fails"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      , SUT.workerOnFailure       = const $ throwIO TimeoutError
                      }
                    )
                    "test-worker"
                    (throwIO RestartingWorkerError)
                    capataz

                  return ()
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnFailure
                  , assertErrorType "TimeoutError"
                  ]
                , andP
                  [ assertEventType ProcessFailed
                  , assertErrorType "ProcessCallbackFailed"
                  ]
                ]
                []
                Nothing
          ]
        , testGroup
          "workerOnTermination"
          [ testCase
              "gets brutally killed when TimeoutSeconds termination policy is not met"
            $ testCapatazStream
                []
                ( \capataz -> do
                  workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      , SUT.workerTerminationPolicy = SUT.TimeoutMillis 1
                      , SUT.workerOnTermination = forever $ threadDelay 100100
                      }
                    )
                    "test-worker"
                    (forever $ threadDelay 10001000)
                    capataz

                  SUT.terminateProcess "testing workerOnTermination callback"
                                       workerId
                                       capataz
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnTermination
                  , assertErrorType "BrutallyTerminateProcessException"
                  ]
                , andP
                  [ assertEventType ProcessFailed
                  , assertCallbackType SUT.OnTermination
                  , assertErrorType "ProcessCallbackFailed"
                  ]
                ]
                []
                Nothing
          , testCase
              "does execute callback when worker sub-routine is terminated"
            $ testCapatazStream
                []
                ( \capataz -> do
                  workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (forever $ threadDelay 1000100)
                    capataz

                  SUT.terminateProcess "testing workerOnTermination callback"
                                       workerId
                                       capataz
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnTermination
                  ]
                , assertEventType ProcessTerminated
                ]
                [assertEventType CapatazTerminated]
                Nothing
          , testCase
              "does not execute callback when worker sub-routine is completed"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (return ())
                    capataz
                  return ()
                )
                [assertEventType ProcessCompleted]
                []
                ( Just $ not . andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnTermination
                  ]
                )
          , testCase "does not execute callback when worker sub-routine fails"
            $ testCapatazStream
                []
                ( \capataz -> do
                  _workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    )
                    "test-worker"
                    (throwIO (ErrorCall "surprise!"))
                    capataz
                  return ()
                )
                [assertEventType ProcessFailed]
                []
                ( Just $ not . andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnTermination
                  ]
                )
          , testCase "treats as worker sub-routine failed if callback fails"
            $ testCapatazStream
                []
                ( \capataz -> do
                  workerId <- SUT.forkWorker
                    ( SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      , SUT.workerOnTermination   = throwIO TimeoutError
                      }
                    )
                    "test-worker"
                    (forever $ threadDelay 10001000)
                    capataz

                  SUT.terminateProcess "testing workerOnTermination callback"
                                       workerId
                                       capataz
                )
                [ andP
                  [ assertEventType ProcessCallbackExecuted
                  , assertCallbackType SUT.OnTermination
                  , assertErrorType "TimeoutError"
                  ]
                , andP
                  [ assertEventType ProcessFailed
                  , assertErrorType "ProcessCallbackFailed"
                  ]
                ]
                []
                Nothing
          ]
        ]
      , testGroup
        "with transient strategy"
        [ testCase "does not restart worker on completion" $ testCapatazStream
          []
          ( \capataz -> do
            _workerId <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Transient }
              "test-worker"
              (return ())
              capataz
            return ()
          )
          [assertEventType ProcessStarted, assertEventType ProcessCompleted]
          [assertEventType CapatazTerminated]
          (Just $ not . assertEventType ProcessRestarted)
        , testCase "does not restart worker on termination" $ testCapatazStream
          []
          ( \capataz -> do
            workerId <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Transient }
              "test-worker"
              (forever $ threadDelay 1000100)
              capataz
            SUT.terminateProcess "termination test (1)" workerId capataz
          )
          [assertEventType ProcessTerminated]
          [assertEventType CapatazTerminated]
          (Just $ not . assertEventType ProcessRestarted)
        , testCase "does restart on failure" $ testCapatazStream
          []
          ( \capataz -> do
            subRoutineAction <- mkFailingSubRoutine 1
            _workerId        <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Transient }
              "test-worker"
              subRoutineAction
              capataz
            return ()
          )
          [ assertEventType ProcessStarted
          , assertEventType ProcessFailed
          , andP [assertEventType ProcessRestarted, assertRestartCount (== 1)]
          ]
          []
          Nothing
        , testCase "does increase restart count on multiple worker failures"
          $ testCapatazStream
              []
              ( \capataz -> do
                subRoutineAction <- mkFailingSubRoutine 2
                _workerId        <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Transient
                    }
                  "test-worker"
                  subRoutineAction
                  capataz
                return ()
              )
              [ andP
                [assertEventType ProcessRestarted, assertRestartCount (== 1)]
              , andP
                [assertEventType ProcessRestarted, assertRestartCount (== 2)]
              ]
              []
              Nothing
        ]
      , testGroup
        "with permanent strategy"
        [ testCase "does restart worker on completion" $ testCapatazStream
          []
          ( \capataz -> do
            subRoutineAction <- mkCompletingOnceSubRoutine
            _workerId        <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Permanent }
              "test-worker"
              subRoutineAction
              capataz
            return ()
          )
          [ assertEventType ProcessStarted
          , assertEventType ProcessCompleted
          , assertEventType ProcessRestarted
          ]
          [assertEventType CapatazTerminated]
          Nothing
        , testCase
            "does not increase restart count on multiple worker completions"
          $ testCapatazStream
              []
              ( \capataz -> do
              -- Note the number is two (2) given the assertion list has two `ProcessRestarted` assertions
                let expectedRestartCount = 2
                subRoutineAction <- mkCompletingBeforeNRestartsSubRoutine
                  expectedRestartCount
                _workerId <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "test-worker"
                  subRoutineAction
                  capataz
                return ()
              )
              [ andP
                [assertEventType ProcessRestarted, assertRestartCount (== 1)]
              , andP
                [assertEventType ProcessRestarted, assertRestartCount (== 1)]
              ]
              []
              Nothing
        , testCase "does restart on worker termination" $ testCapatazStream
          []
          ( \capataz -> do
            workerId <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Permanent }
              "test-worker"
              (forever $ threadDelay 10001000)
              capataz
            SUT.terminateProcess "testing termination (1)" workerId capataz
          )
          [assertEventType ProcessTerminated, assertEventType ProcessRestarted]
          []
          Nothing
        , testCase "does increase restart count on multiple worker terminations"
          $ do
              terminationCountVar <- newTVarIO (0 :: Int)
              let signalWorkerTermination =
                    atomically (modifyTVar' terminationCountVar (+ 1))
                  waitWorkerTermination i = atomically $ do
                    n <- readTVar terminationCountVar
                    when (n /= i) retry
              testCapatazStream
                []
                ( \capataz -> do
                  workerId <- SUT.forkWorker
                    SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Permanent
                      , SUT.workerOnTermination   = signalWorkerTermination
                      }
                    "test-worker"
                    (forever $ threadDelay 10001000)
                    capataz

                  SUT.terminateProcess "testing termination (1)"
                                       workerId
                                       capataz
                  waitWorkerTermination 1
                  SUT.terminateProcess "testing termination (2)"
                                       workerId
                                       capataz
                  waitWorkerTermination 2
                )
                [ assertEventType ProcessTerminated
                , andP
                  [assertEventType ProcessRestarted, assertRestartCount (== 1)]
                , assertEventType ProcessTerminated
                , andP
                  [assertEventType ProcessRestarted, assertRestartCount (== 2)]
                ]
                []
                Nothing
        , testCase "does restart on worker failure" $ testCapatazStream
          []
          ( \capataz -> do
            subRoutineAction <- mkFailingSubRoutine 1
            _workerId        <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Permanent }
              "test-worker"
              subRoutineAction
              capataz
            return ()
          )
          [ assertEventType ProcessStarted
          , assertEventType ProcessFailed
          , andP [assertEventType ProcessRestarted, assertRestartCount (== 1)]
          ]
          []
          Nothing
        , testCase "does increase restart count on multiple worker failures"
          $ testCapatazStream
              []
              ( \capataz -> do
                subRoutineAction <- mkFailingSubRoutine 2
                _workerId        <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "test-worker"
                  subRoutineAction
                  capataz
                return ()
              )
              [ andP
                [assertEventType ProcessRestarted, assertRestartCount (== 1)]
              , andP
                [assertEventType ProcessRestarted, assertRestartCount (== 2)]
              ]
              []
              Nothing
        ]
      , testGroup
        "with temporary strategy"
        [ testCase "does not restart on worker completion" $ testCapatazStream
          []
          ( \capataz -> do
            _workerId <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Temporary }
              "test-worker"
              (return ())
              capataz
            return ()
          )
          [assertEventType ProcessStarted, assertEventType ProcessCompleted]
          [assertEventType CapatazTerminated]
          (Just $ not . assertEventType ProcessRestarted)
        , testCase "does not restart on worker termination" $ testCapatazStream
          []
          ( \capataz -> do
            workerId <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Temporary }
              "test-worker"
              (forever $ threadDelay 1000100)
              capataz
            SUT.terminateProcess "termination test (1)" workerId capataz
            threadDelay 100
          )
          [assertEventType ProcessStarted, assertEventType ProcessTerminated]
          [assertEventType CapatazTerminated]
          (Just $ not . assertEventType ProcessRestarted)
        , testCase "does not restart on worker failure" $ testCapatazStream
          []
          ( \capataz -> do
            _workerId <- SUT.forkWorker
              SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Temporary }
              "failing-worker"
              (panic "worker failed!")
              capataz
            threadDelay 100
          )
          [assertEventType ProcessStarted, assertEventType ProcessFailed]
          [assertEventType CapatazTerminated]
          (Just $ not . assertEventType ProcessRestarted)
        ]
      ]
    , testGroup
      "multiple supervised IO sub-routines"
      [ testCase "terminates all supervised worker sub-routines on teardown"
        $ testCapatazStream
            []
            ( \capataz -> do
              _workerA <- SUT.forkWorker
                SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Permanent
                                     }
                "A"
                (forever $ threadDelay 1000100)
                capataz


              _workerB <- SUT.forkWorker
                SUT.defWorkerOptions { SUT.workerRestartStrategy = SUT.Permanent
                                     }
                "B"
                (forever $ threadDelay 1000100)
                capataz

              return ()
            )
            [ andP [assertEventType ProcessStarted, assertProcessName "A"]
            , andP [assertEventType ProcessStarted, assertProcessName "B"]
            ]
            [ andP [assertEventType ProcessTerminated, assertProcessName "A"]
            , andP [assertEventType ProcessTerminated, assertProcessName "B"]
            , assertEventType CapatazTerminated
            ]
            Nothing
      , testGroup
        "with one for one supervisor restart strategy"
        [ testCase "restarts failing worker sub-routine only"
            $ testCapatazStreamWithOptions
                ( \supOptions ->
                  supOptions { SUT.supervisorRestartStrategy = SUT.OneForOne }
                )
                []
                ( \capataz -> do
                  _workerA <- SUT.forkWorker
                    SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Temporary
                      }
                    "A"
                    (forever $ threadDelay 1000100)
                    capataz

                  ioB      <- mkFailingSubRoutine 1

                  _workerB <- SUT.forkWorker
                    SUT.defWorkerOptions
                      { SUT.workerRestartStrategy = SUT.Permanent
                      }
                    "B"
                    (forever $ ioB >> threadDelay 1000100)
                    capataz

                  return ()
                )
                [andP [assertEventType ProcessRestarted, assertProcessName "B"]]
                []
                ( Just $ not . andP
                  [assertEventType ProcessRestarted, assertProcessName "A"]
                )
        ]
      , testGroup
        "with all for one supervisor restart strategy with newest first order"
        [ testCase "does terminate all other workers that did not fail"
          $ testCapatazStreamWithOptions
              ( \supOptions -> supOptions
                { SUT.supervisorRestartStrategy         = SUT.AllForOne
                , SUT.supervisorProcessTerminationOrder = SUT.OldestFirst
                }
              )
              []
              ( \capataz -> do
              -- This lockVar guarantees that workerB executes before workerA
                lockVar  <- newEmptyMVar

                ioA      <- mkFailingSubRoutine 1

                _workerA <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "A"
                  (forever $ readMVar lockVar >> ioA)
                  capataz

                _workerB <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "B"
                  (putMVar lockVar () >> forever (threadDelay 10))
                  capataz

                return ()
              )
              [ andP [assertEventType ProcessStarted, assertProcessName "A"]
              , andP [assertEventType ProcessStarted, assertProcessName "B"]
              , andP [assertEventType ProcessFailed, assertProcessName "A"]
              , andP [assertEventType ProcessRestarted, assertProcessName "A"]
              , andP [assertEventType ProcessTerminated, assertProcessName "B"]
              , andP [assertEventType ProcessRestarted, assertProcessName "B"]
              ]
              []
              Nothing
        , testCase "does not restart workers that are temporary"
          $ testCapatazStreamWithOptions
              ( \supOptions -> supOptions
                { SUT.supervisorRestartStrategy         = SUT.AllForOne
                , SUT.supervisorProcessTerminationOrder = SUT.OldestFirst
                }
              )
              []
              ( \capataz -> do
                lockVar  <- newEmptyMVar

                ioA      <- mkFailingSubRoutine 1

                _workerA <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "A"
                  (forever $ readMVar lockVar >> ioA)
                  capataz

                _workerB <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Temporary
                    }
                  "B"
                  (putMVar lockVar () >> forever (threadDelay 10))
                  capataz

                return ()
              )
              [ andP [assertEventType ProcessStarted, assertProcessName "A"]
              , andP [assertEventType ProcessStarted, assertProcessName "B"]
              , andP [assertEventType ProcessFailed, assertProcessName "A"]
              , andP [assertEventType ProcessRestarted, assertProcessName "A"]
              , andP [assertEventType ProcessTerminated, assertProcessName "B"]
              ]
              []
              ( Just $ not . andP
                [assertEventType ProcessRestarted, assertProcessName "B"]
              )
        , testCase "restarts workers that are not temporary"
          $ testCapatazStreamWithOptions
              ( \supOptions -> supOptions
                { SUT.supervisorRestartStrategy         = SUT.AllForOne
                , SUT.supervisorProcessTerminationOrder = SUT.NewestFirst
                }
              )
              []
              ( \capataz -> do
                ioA      <- mkFailingSubRoutine 1

                lockVar  <- newEmptyMVar

                _workerA <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "A"
                  (forever $ readMVar lockVar >> ioA)
                  capataz

                _workerB <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Transient
                    }
                  "B"
                  (putMVar lockVar () >> forever (threadDelay 10))
                  capataz

                return ()
              )
              [ andP [assertEventType ProcessRestarted, assertProcessName "B"]
              , andP [assertEventType ProcessRestarted, assertProcessName "A"]
              ]
              []
              Nothing
        ]
      , testGroup
        "with all for one capataz restart strategy with oldest first order"
        [ testCase "does not restart workers that are temporary"
          $ testCapatazStreamWithOptions
              ( \supOptions -> supOptions
                { SUT.supervisorRestartStrategy         = SUT.AllForOne
                , SUT.supervisorProcessTerminationOrder = SUT.OldestFirst
                }
              )
              []
              ( \capataz -> do
                ioA      <- mkFailingSubRoutine 1

                -- This lockVar guarantees that workerB executes before workerA
                lockVar  <- newEmptyMVar

                _workerA <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "A"
                  (forever $ readMVar lockVar >> ioA)
                  capataz

                _workerB <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Temporary
                    }
                  "B"
                  (putMVar lockVar () >> forever (threadDelay 10))
                  capataz

                return ()
              )
              [andP [assertEventType ProcessRestarted, assertProcessName "A"]]
              []
              ( Just $ not . andP
                [assertEventType ProcessRestarted, assertProcessName "B"]
              )
        , testCase "restarts workers that are not temporary"
          $ testCapatazStreamWithOptions
              ( \supOptions -> supOptions
                { SUT.supervisorRestartStrategy         = SUT.AllForOne
                , SUT.supervisorProcessTerminationOrder = SUT.OldestFirst
                }
              )
              []
              ( \capataz -> do
                ioA      <- mkFailingSubRoutine 1

                -- This lockVar guarantees that workerB executes before workerA
                lockVar  <- newEmptyMVar

                _workerA <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Permanent
                    }
                  "A"
                  (forever $ readMVar lockVar >> ioA)
                  capataz

                _workerB <- SUT.forkWorker
                  SUT.defWorkerOptions
                    { SUT.workerRestartStrategy = SUT.Transient
                    }
                  "B"
                  (putMVar lockVar () >> forever (threadDelay 10))
                  capataz

                return ()
              )
              [ andP [assertEventType ProcessRestarted, assertProcessName "A"]
              , andP [assertEventType ProcessRestarted, assertProcessName "B"]
              ]
              []
              Nothing
        ]
      ]
    ]
  ]
