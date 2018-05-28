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
import Control.Monad.Trans
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally)
import Control.Distributed.Process.Node
import Control.Monad.Catch (bracket, finally)
import qualified Control.Monad.Metrics as Metrics
import Data.Typeable
import Data.Binary
import Data.Maybe
import Data.IORef
import qualified Data.HashMap.Strict as H
import qualified Data.ByteString.Lazy as L
import Data.String
import Network.Socket hiding (send)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import GHC.Generics
import System.Random
import Text.Printf
import System.Log.Heavy
import qualified System.Metrics.Distribution.Internal as EKG
import qualified System.Metrics as EKG
-- import System.Log.Heavy.Shortcuts
import Data.Text.Format.Heavy
import Lens.Micro
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

sendWorker :: (ProcessMonad m, IsMessage msg) => ExtPort -> Maybe ProcessId -> msg -> m ()
sendWorker srcPort Nothing msg = do
  count <- asksConfig pcWorkersCount
  idx <- liftIO $ randomRIO (0, count-1)
  let name = "worker:" ++ show idx
  liftP $ nsend name (getPortNumber srcPort, msg)
sendWorker srcPort (Just worker) msg = do
  liftP $ send worker (getPortNumber srcPort, msg)

sendAllWorkers :: (Binary msg, Typeable msg, ProcessMonad m) => msg -> m ()
sendAllWorkers msg = do
  count <- asksConfig pcWorkersCount
  forM_ [0 .. count-1] $ \idx -> do
    let name = "worker:" ++ show idx
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
    $debug "hello from reader: {}" (Single $ show port)
    loop `finally` closeServerConnection
  where
    loop :: ProtocolM (ProtocolState proto) ()
    loop = forever $ do
            frame <- getFrame proto
            msg <- liftIO $ readMessage port frame :: ProtocolM (ProtocolState proto) (ProtocolMessage proto)
            if isResponse msg
              then do
                Metrics.increment "reader.received.responses"
                mbRequester <- whoSentRq (getPortNumber port) (getMatchKey msg)
                case mbRequester of
                  Nothing -> do
                    $reportError "Late response receive for request #{}" (Single $ getMatchKey msg)
                    Metrics.increment "generator.requests.late"
                  Just requester -> sendWorker port (Just requester) msg
              else do
                  Metrics.increment "reader.received.requests"
                  sendWorker port Nothing msg

    closeServerConnection :: ProtocolM (ProtocolState proto) ()
    closeServerConnection =
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

writer :: forall proto. Protocol proto => proto -> ExtPort -> ProtocolM (ProtocolState proto) ()
writer proto port = do
    let portNumber = getPortNumber port
    self <- liftP getSelfPid
    let name = "writer:" ++ show portNumber
    liftP $ register name self
    loop `finally` closeServerConnection
  where
    loop :: ProtocolM (ProtocolState proto) ()
    loop =
        forever $ do
          $debug "hello from writer: {}" (Single $ show port)
          msg <- liftP expect :: ProtocolM (ProtocolState proto) (ProtocolMessage proto)
          Metrics.increment "writer.sent.messages"
          frame <- getFrame proto
          liftIO $ writeMessage port frame msg

    closeServerConnection :: ProtocolM (ProtocolState proto) ()
    closeServerConnection =
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
  sendAllWorkers StartGenerator

stopGenerator :: ProtocolM st ()
stopGenerator =
  sendAllWorkers StopGenerator

setTargetRps :: Int -> ProtocolM st ()
setTargetRps rps =
  sendAllWorkers (SetTargetRps rps)

calcGeneratorDelay :: Int -> ProtocolM st Int
calcGeneratorDelay targetRps = do
  st <- gets psRpsStats
  (prevSecondCount, lastSecondCount) <- liftIO $ readIORef st
  let currentRps = fromIntegral (lastSecondCount - prevSecondCount)
  currentDelay <- gets psGeneratorDelay
  let deltaRps = targetRps - currentRps
      newDelay = max 1 $ round $ fromIntegral currentDelay - 500 * fromIntegral deltaRps
  modify $ \st -> st {psGeneratorDelay = newDelay}
  $info "Current RPS {}, target RPS {}, old delay {}, new delay {}"
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
      -- $info "new count: {}" (Single currentCount)
      st <- gets psRpsStats
      liftIO $ modifyIORef st $ \(prev,last) -> (last, currentCount)

generator :: forall proto. Protocol proto => proto -> Int -> ProtocolM (ProtocolState proto) ()
generator proto myIndex = do
  self <- liftP getSelfPid
  let myName = "worker:" ++ show myIndex
  liftP $ register myName self

  $debug "hello from client worker #{}" (Single myIndex)
  forever $ do
    (enabled, targetRps) <- getGeneratorSettings
    -- liftIO $ putStrLn $ show enabled
    if enabled
      then do
        delay <- calcGeneratorDelay targetRps
        liftIO $ threadDelay $ delay
        Metrics.timed "generator.requests.duration" $ do
            request <- generateRq proto myIndex 
            let key = getMatchKey request
            sendWriter Nothing request
            $info "sent request #{}" (Single key)
            mbResponse <- receiveResponse key :: ProtocolM (ProtocolState proto) (Maybe (ProtocolMessage proto))
            case mbResponse of
              Nothing -> do
                $reportError "Timeout while waiting for response for request #{}" (Single key)
                Metrics.increment "generator.requests.timeouts"
              Just response -> do
                when (getMatchKey response /= key) $
                    fail "Suddenly received incorrect reply"
                $info "response received: #{}" (Single $ getMatchKey response)
      else
        liftIO $ threadDelay 1000

processor :: forall proto. Protocol proto => proto -> Int -> ProtocolM (ProtocolState proto) ()
processor proto myIndex = do
  self <- liftP getSelfPid
  let myName = "worker:" ++ show myIndex
  liftP $ register myName self
  $debug "hello from server worker #{}" (Single myIndex)
  forever $ do
    (srcPort, request) <- liftP expect :: ProtocolM (ProtocolState proto) (PortNumber, ProtocolMessage proto)
    $info "request received: #{}" (Single $ getMatchKey request)
    Metrics.timed "processor.requests.duration" $ do
      minDelay <- asksConfig pcProcessorMinDelay
      maxDelay <- asksConfig pcProcessorMaxDelay
      delay <- liftIO $ randomRIO (minDelay, maxDelay)
      liftIO $ threadDelay $ delay * 1000
      response <- processRq request
      sendWriter (Just srcPort) response
      $info "response sent: #{}" (Single $ getMatchKey response)

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
      liftIO $ putStrLn "unknown command"
      repl

runSite :: Protocol proto
        => Bool            -- ^ True for client side, False for server side
        -> proto
        -> ProtocolSettings proto
        -> Metrics.Metrics
        -> ProcessConfig
        -> Process ()
runSite isClient proto settings metrics cfg = do

    let connector = if isClient
                      then clientConnection
                      else serverConnection

    let minPort = pcMinPort cfg
        maxPort = pcMaxPort cfg

    rps <- liftIO $ newIORef (0,0)
    let st0 = initialState settings
        st = ProcessState [] metrics cfg (pcGeneratorEnabled cfg) 1000 (pcGeneratorTargetRps cfg) rps st0

    spawnLocal $ logWriter (pcLogFilePath cfg)
    myName <- liftIO getProgName

    runAProcess st $ withLogVariable "process" myName $ do
        spawnAProcess "monitor" 0 $ do
            liftP $ register "monitor" =<< getSelfPid
            globalCollector

        spawnAProcess "rps controller" 0 rpsController

        nWorkers <- asksConfig pcWorkersCount
        isGenerator <- asksConfig pcIsGenerator
        matcherTimeout <- asksConfig pcMatcherTimeout
        when (not isGenerator) $ do
          forM_ [0 .. nWorkers-1] $ \idx ->
              spawnAProcess "processor" idx $ processor proto idx

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess "port" portNumber $ connector (pcHost cfg) portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber matcherTimeout)
              lift $ link m
              w <- spawnAProcess "writer" portNumber (writer proto extPort)
              lift $ link w
              $debug "{} spawned writer" (Single myName)
              r <- spawnAProcess "reader" portNumber (reader proto extPort)
              lift $ link r
              $debug "{} spawned reader" (Single myName)
              return ()

        liftIO $ threadDelay $ 100*1000

        $debug "hello" ()
        when isGenerator $ do
          forM_ [0 .. nWorkers-1] $ \idx ->
              spawnAProcess "generator" idx $ generator proto idx

        return ()

    if pcUseRepl cfg
      then runAProcess st $ withLogVariable "process" ("repl" :: String) repl
      else liftIO $ do
        putStrLn "press return to exit..."
        getLine
        return ()


