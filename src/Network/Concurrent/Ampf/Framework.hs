{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Concurrent.Ampf.Framework where

import Control.Monad
import Control.Monad.Reader hiding (reader)
import Control.Monad.State as St
import Control.Monad.Catch (catch, finally, SomeException)
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally, catch)
import qualified Control.Monad.Metrics as Metrics
import Data.Typeable
import Data.Binary
import Data.IORef
import qualified Data.HashMap.Strict as H
import Network.Socket hiding (send)
import System.Log.Heavy
import qualified System.Metrics as EKG
import Data.Text.Format.Heavy
import Lens.Micro
import System.Random
import System.Environment
import System.IO

import Network.Concurrent.Ampf.Types
import Network.Concurrent.Ampf.Connection
import Network.Concurrent.Ampf.Logging
import Network.Concurrent.Ampf.Matcher
import Network.Concurrent.Ampf.Monitoring (globalCollector)

askPortsCount :: ProcessMonad m => m Int
askPortsCount = do
  minPort <- asksConfig pcMinPort
  maxPort <- asksConfig pcMaxPort
  return $ fromIntegral $ maxPort - minPort + 1

sendWorker :: (ProcessMonad m, IsMessage msg) => String -> ExtPort -> Maybe ProcessId -> msg -> m ()
sendWorker workerType srcPort Nothing msg = do
  count <- asksConfig pcWorkersCount
  idx <- liftIO $ randomRIO (0, count-1)
  let name = workerType ++ ":" ++ show idx
  liftP $ nsend name (getPortNumber srcPort, msg)
sendWorker _ srcPort (Just worker) msg = do
  liftP $ send worker (getPortNumber srcPort, msg)

sendAllGenerators :: (Binary msg, Typeable msg, ProcessMonad m) => msg -> m ()
sendAllGenerators msg = do
  count <- asksConfig pcWorkersCount
  forM_ [0 .. count-1] $ \idx -> do
    let name = "generator:" ++ show idx
    liftP $ nsend name msg

sendWriter :: (ProcessMonad m, IsMessage msg) => Maybe PortNumber -> msg -> m ()
sendWriter mbPort msg = do
  port <- case mbPort of
           Just srcPort -> return srcPort
           Nothing -> do
              minPort <- asksConfig pcMinPort
              maxPort <- asksConfig pcMaxPort
              let count = fromIntegral $ maxPort - minPort + 1
              idx <- liftIO $ randomRIO (0, count-1)
              return $ minPort + fromIntegral (idx :: Int)
  when (not $ isResponse msg) $ do
      registerRq port (getMatchKey msg)
  let name = "writer:" ++ show port
  liftP $ nsend name msg

reader :: forall proto. Protocol proto => proto -> ExtPort -> ProtocolM (ProtocolState proto) ()
reader proto port = do
    self <- liftP getSelfPid
    $debug "starting reader @{}: {}" (show port, show self)
    loop `finally` closeServerConnection
  where
    loop :: ProtocolM (ProtocolState proto) ()
    loop = forever $ do
            frame <- getFrame proto
            msg <- liftIO $ readMessage port frame :: ProtocolM (ProtocolState proto) (ProtocolMessage proto)
            $traceSensitive "received message: {}" (Single $ showFull msg)
            if isResponse msg
              then do
                Metrics.increment "reader.received.responses"
                mbRequester <- whoSentRq (getPortNumber port) (getMatchKey msg)
                case mbRequester of
                  Nothing -> do
                    $reportError "Late response receive for request #{}" (Single $ showKey msg)
                    Metrics.increment "generator.requests.late"
                  Just requester -> sendWorker "generator" port (Just requester) msg
              else do
                  Metrics.increment "reader.received.requests"
                  sendWorker "processor" port Nothing msg

    closeServerConnection :: ProtocolM (ProtocolState proto) ()
    closeServerConnection = do
      $info "closing connection @{}" (Single $ show port)
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

writer :: forall proto. Protocol proto => proto -> ExtPort -> ProtocolM (ProtocolState proto) ()
writer proto port = do
    let portNumber = getPortNumber port
    self <- liftP getSelfPid
    $debug "starting writer @{}: {}" (show port, show self)
    let name = "writer:" ++ show portNumber
    liftP $ register name self
    loop `finally` closeServerConnection
  where
    loop :: ProtocolM (ProtocolState proto) ()
    loop =
        forever $ do
          -- $ debug "hello from writer: {}" (Single $ show port)
          msg <- liftP expect :: ProtocolM (ProtocolState proto) (ProtocolMessage proto)
          Metrics.increment "writer.sent.messages"
          frame <- getFrame proto
          liftIO $ writeMessage port frame msg
          $traceSensitive "sent message: {}" (Single $ showFull msg)

    closeServerConnection :: ProtocolM (ProtocolState proto) ()
    closeServerConnection = do
      $info "closing connection @{}" (Single $ show port)
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

receiveResponse :: forall m msg. (ProcessMonad m, IsMessage msg) => MatchKey -> m (Maybe msg)
receiveResponse key = do
    timeout <- asksConfig pcGeneratorTimeout
    liftP $ receiveTimeout (timeout * 1000) [
              matchIf isSuitable (return . snd)
            ]
  where
    isSuitable :: (PortNumber, msg) -> Bool
    isSuitable (_, msg) =
      isResponse msg && getMatchKey msg == key

getGeneratorSettings :: ProtocolM st (Bool, Int)
getGeneratorSettings = do
  mbCommand <- liftP $ expectTimeout 0
  case mbCommand of
    Nothing -> do
      enabled <- gets psGeneratorEnabled
      rps <- gets psTargetRps
      return (enabled, rps)
    Just StartGenerator -> do
      modify $ \st -> st {psGeneratorEnabled = True}
      rps <- gets psTargetRps
      return (True, rps)
    Just StopGenerator -> do
      modify $ \st -> st {psGeneratorEnabled = False}
      rps <- gets psTargetRps
      return (False, rps)
    Just (SetTargetRps rps) -> do
      modify $ \st -> st {psTargetRps = rps}
      enabled <- gets psGeneratorEnabled
      return (enabled, rps)

startGenerator :: ProtocolM st ()
startGenerator =
  sendAllGenerators StartGenerator

stopGenerator :: ProtocolM st ()
stopGenerator =
  sendAllGenerators StopGenerator

setTargetRps :: Int -> ProtocolM st ()
setTargetRps rps =
  sendAllGenerators (SetTargetRps rps)

calcGeneratorDelay :: Int -> ProtocolM st Int
calcGeneratorDelay targetRps = do
  st <- gets psRpsStats
  (prevSecondCount, lastSecondCount) <- liftIO $ readIORef st
  let currentRps = fromIntegral (lastSecondCount - prevSecondCount)
  currentDelay <- gets psGeneratorDelay
  let deltaRps = targetRps - currentRps
      newDelay = max 1 $ round $ fromIntegral currentDelay - 500 * fromIntegral deltaRps
  modify $ \st -> st {psGeneratorDelay = newDelay}
  $debug "Current RPS {}, target RPS {}, old delay {}, new delay {}"
      (currentRps, targetRps, currentDelay, newDelay)
  return newDelay

rpsController :: ProtocolM st ()
rpsController = forever $ do
  liftIO $ threadDelay $ 1000 * 1000
  metrics <- Metrics.getMetrics
  let store = metrics ^. Metrics.metricsStore
  sample <- liftIO $ EKG.sampleAll store
  case H.lookup "writer.sent.messages" sample of
    Nothing -> return ()
    Just (EKG.Counter currentCount) -> do
      st <- gets psRpsStats
      liftIO $ modifyIORef st $ \(prev,last) -> (last, currentCount)

generator :: forall proto. Protocol proto => proto -> Int -> ProtocolM (ProtocolState proto) ()
generator proto myIndex = do
  self <- liftP getSelfPid
  let myName = "generator:" ++ show myIndex
  liftP $ register myName self

  $debug "starting generator #{}: #{}" (myIndex, show self)
  forever $ do
    (enabled, targetRps) <- getGeneratorSettings
    -- liftIO $ putStrLn $ show enabled
    if enabled
      then do
        delay <- calcGeneratorDelay targetRps
        liftIO $ threadDelay $ delay
        Metrics.timed "generator.requests.duration" (do
            request <- generateRq proto myIndex 
            let key = getMatchKey request
            sendWriter Nothing request
            $debug "sent request #{}" (Single $ showKey request)
            mbResponse <- receiveResponse key :: ProtocolM (ProtocolState proto) (Maybe (ProtocolMessage proto))
            case mbResponse of
              Nothing -> do
                $reportError "Timeout while waiting for response for request #{}" (Single $ showKey request)
                Metrics.increment "generator.requests.timeouts"
              Just response -> do
                when (getMatchKey response /= key) $
                    fail "Suddenly received incorrect reply"
                $debug "response received: #{}" (Single $ showKey response)
                if isRequestDeclinedResponse response
                  then do
                       Metrics.increment "generator.requests.declined"
                       $debug "request declined: #{}" (Single $ showKey response)
                  else Metrics.increment "generator.requests.approved"
            ) `catch` \(e :: SomeException) -> do
                $reportError "Exception: {}" (Single $ show e)
      else
        liftIO $ threadDelay 1000

processor :: forall proto. Protocol proto => proto -> Int -> ProtocolM (ProtocolState proto) ()
processor proto myIndex = do
  self <- liftP getSelfPid
  let myName = "processor:" ++ show myIndex
  liftP $ register myName self
  $debug "starting processor worker #{}: {}" (myIndex, show self)
  forever $ do
    (srcPort, request) <- liftP expect :: ProtocolM (ProtocolState proto) (PortNumber, ProtocolMessage proto)
    $debug "request received: #{}" (Single $ showKey request)
    Metrics.timed "processor.requests.duration" $ do
      minDelay <- asksConfig pcProcessorMinDelay
      maxDelay <- asksConfig pcProcessorMaxDelay
      delay <- liftIO $ randomRIO (minDelay, maxDelay)
      liftIO $ threadDelay $ delay * 1000
      response <- processRq proto request
      sendWriter (Just srcPort) response
      $debug "response sent: #{}" (Single $ showKey response)

repl :: ProtocolM st ()
repl = do
  liftIO $ hSetBuffering stdout NoBuffering
  liftIO $ putStr "> "
  command <- liftIO getLine
  case words command of
    ["start"] -> do
      startGenerator
      repl
    ["stop"] -> do
      stopGenerator
      repl
    ["rps", ns] -> do
      let rps = read ns
      setTargetRps rps
      repl
    [] -> repl
    [""] -> repl
    ["exit"] -> return ()
    ["quit"] -> return ()
    _ -> do
      lift $ nsend "controller" (ReplCommand command)
      repl

watcher :: forall proto. Protocol proto => proto -> ProtocolM (ProtocolState proto) ()
watcher proto =
  processMessages proto [
      matchP proto monitorEvent
  ]
  where
    monitorEvent :: ProcessMonitorNotification -> ProtocolM (ProtocolState proto) ()
    monitorEvent (ProcessMonitorNotification ref pid reason) = do
      $reportError "Process exited: {}: {}" (show pid, show reason)
      
controller :: Protocol proto => proto -> ProtocolM (ProtocolState proto) ()
controller proto =
  processMessages proto [
    matchAnyP proto (\m -> processCommand proto m)
  ]


runSite :: Protocol proto
        => Bool            -- ^ True for client side, False for server side
        -> ProtocolSettings proto
        -> Metrics.Metrics
        -> ProcessConfig
        -> Process ()
runSite isClient settings metrics cfg = do

    let connector = if isClient
                      then clientConnection
                      else serverConnection

    let minPort = pcMinPort cfg
        maxPort = pcMaxPort cfg

    rps <- liftIO $ newIORef (0,0)
    let st0 = initialState settings
        st = ThreadState [] metrics cfg (pcGeneratorEnabled cfg) 1000 (pcGeneratorTargetRps cfg) rps st0

    link =<< (spawnLocal $ logWriter (defaultLogSettings cfg))
    myName <- liftIO getProgName

    evalProtocolM st $ withLogVariable "process" myName $ do
        proto <- initProtocol settings
        spawnAProcess "monitor" 0 $ do
            liftP $ register "monitor" =<< getSelfPid
            globalCollector

        spawnAProcess "controller" 0 $ do
            liftP $ register "controller" =<< getSelfPid
            controller proto

        spawnAProcess "rps controller" 0 rpsController

        nWorkers <- asksConfig pcWorkersCount
        isGenerator <- asksConfig pcIsGenerator
        isProcessor <- asksConfig pcIsProcessor
        matcherTimeout <- asksConfig pcMatcherTimeout
        when isProcessor $ do
          forM_ [0 .. nWorkers-1] $ \idx -> do
              p <- spawnAProcess "processor" idx $ processor proto idx
              lift $ monitor p

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess "port" portNumber $ connector (pcHost cfg) portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber matcherTimeout)
              lift $ monitor m
              w <- spawnAProcess "writer" portNumber (writer proto extPort)
              lift $ monitor w
              $debug "{} spawned writer" (Single myName)
              r <- spawnAProcess "reader" portNumber (reader proto extPort)
              lift $ monitor r
              $debug "{} spawned reader" (Single myName)
              watcher proto
              return ()

        liftIO $ threadDelay $ 100*1000

        $debug "hello" ()
        when isGenerator $ do
          forM_ [0 .. nWorkers-1] $ \idx -> do
              g <- spawnAProcess "generator" idx $ generator proto idx
              lift $ monitor g

        -- lift watcher
        return ()

    if pcUseRepl cfg
      then evalProtocolM st $ withLogVariable "process" ("repl" :: String) repl
      else liftIO $ do
        putStrLn "press return to exit..."
        getLine
        return ()


