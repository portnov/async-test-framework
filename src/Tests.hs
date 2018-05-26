{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Tests where

import Control.Monad
import Control.Monad.Reader hiding (reader)
import Control.Monad.State as St
import Control.Monad.Trans
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally)
import Control.Distributed.Process.Node
import Control.Monad.Catch (bracket, finally)
import qualified Control.Monad.Metrics as Metrics
import Data.Binary
import Data.Maybe
import qualified Data.ByteString.Lazy as L
import Data.String
import Network.Socket hiding (send)
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import GHC.Generics
import System.Random
import Text.Printf
import System.Log.Heavy
-- import System.Log.Heavy.Shortcuts
import Data.Text.Format.Heavy

import Types
import Connection
import Pool
import Logging
import Matcher

data MyProtocol = MyProtocol

instance Protocol MyProtocol where
  type ProtocolFrame MyProtocol = SimpleFrame
  data ProtocolMessage MyProtocol = 
    MyMessage {
        mIsResponse :: Bool
      , mKey :: Int
      , mPayload :: L.ByteString
      }
      deriving (Eq, Show, Generic)

  data ProtocolSettings MyProtocol = MySettings Int

  type ProtocolState MyProtocol = Int

  getFrame _ = return SimpleFrame

  -- initProtocol (MySettings key) = putP key

  initialState (MySettings key) = key

  makeLogonMsg = return $ MyMessage False 0 "logon"

  generateRq _ = do
    key <- getP
    putP $ key+1
    return $ MyMessage False key "request"

  processRq msg = do
    delay <- liftIO $ randomRIO (0, 2)
    liftIO $ threadDelay $ delay * 100 * 1000
    return $ msg {mIsResponse = True, mPayload = "response"}

type MyMessage = ProtocolMessage MyProtocol

instance Binary (ProtocolMessage MyProtocol) where

instance IsMessage (ProtocolMessage MyProtocol) where
  isResponse = mIsResponse
  isAdministrative _ = False
  getMatchKey m = fromString (show $ mKey m)

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
      liftP $ registerRq port (getMatchKey msg)
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
                mbRequester <- liftP $ whoSentRq (getPortNumber port) (getMatchKey msg)
                case mbRequester of
                  Nothing -> 
                    $reportError "Received response #{} for request that we did not send, skipping" (Single $ getMatchKey msg)
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

receiveResponse :: forall proto. Protocol proto => MatchKey -> ProtocolM (ProtocolState proto) (ProtocolMessage proto)
receiveResponse key =
    liftP $ receiveWait [
      matchIf isSuitable (return . snd)
    ]
  where
    isSuitable :: (PortNumber, ProtocolMessage proto) -> Bool
    isSuitable (_, msg) =
      isResponse msg && getMatchKey msg == key

generator :: forall proto. Protocol proto => proto -> Int -> ProtocolM (ProtocolState proto) ()
generator proto myIndex = do
  self <- liftP getSelfPid
  let myName = "worker:" ++ show myIndex
  liftP $ register myName self

  $debug "hello from client worker #{}" (Single myIndex)
  forM_ [1 .. 2000] $ \id -> do
    request <- generateRq proto
    let key = getMatchKey request
    Metrics.timed "generator.requests.duration" $ do
        sendWriter Nothing request
        $info "sent request #{}" (Single key)
        response <- receiveResponse (getMatchKey request) :: ProtocolM (ProtocolState proto) (ProtocolMessage proto)
        when (getMatchKey response /= getMatchKey request) $
            fail "Suddenly received incorrect reply"
        $info "response received: #{}" (Single $ getMatchKey response)

processor :: forall proto. Protocol proto => proto -> Int -> ProtocolM (ProtocolState proto) ()
processor proto myIndex = do
  self <- liftP getSelfPid
  let myName = "worker:" ++ show myIndex
  liftP $ register myName self
  $debug "hello from server worker #{}" (Single myIndex)
  forever $ do
    Metrics.timed "processor.requests.duration" $ do
      (srcPort, request) <- liftP expect :: ProtocolM (ProtocolState proto) (PortNumber, ProtocolMessage proto)
      $info "request received: #{}" (Single $ getMatchKey request)
      response <- processRq request
      -- delay <- liftIO $ randomRIO (0, 10)
      -- liftIO $ threadDelay $ delay * 100 * 1000
      sendWriter (Just srcPort) response
      $info "response sent: #{}" (Single $ getMatchKey response)

localhost = "127.0.0.1"

mkExternalService port = (localhost, port)

runClient :: Metrics.Metrics -> ProcessConfig -> IO ()
runClient metrics cfg = do
  Right transport <- createTransport localhost "10501" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  let minPort = pcMinPort cfg
      maxPort = pcMaxPort cfg

  let st0 = initialState (MySettings 100)
      st = ProcessState [] metrics cfg st0
      proto = MyProtocol

  runProcess node $ do
    spawnLocal $ logWriter "client.log"
    runAProcess st $ withLogVariable "process" ("client" :: String) $ do
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess "port" portNumber $ clientConnection localhost portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber)
              lift $ link m
              w <- spawnAProcess "writer" portNumber (writer proto extPort)
              lift $ link w
              $debug "client spawned writer" ()
              r <- spawnAProcess "reader" portNumber (reader proto extPort)
              lift $ link r
              $debug "client spawned reader" ()
              return ()

        liftIO $ threadDelay $ 100*1000

        $debug "hello" ()
        nWorkers <- asksConfig pcWorkersCount
        forM_ [0 .. nWorkers-1] $ \idx ->
            spawnAProcess "generator" idx $ generator proto idx
        return ()

  putStrLn "hit enter..."
  getLine
  return ()

runServer :: Metrics.Metrics -> ProcessConfig -> IO ()
runServer metrics cfg = do
  Right transport <- createTransport localhost "10502" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  let minPort = pcMinPort cfg
      maxPort = pcMaxPort cfg

  let st0 = initialState (MySettings 200)
      st = ProcessState [] metrics cfg st0
      proto = MyProtocol

  putStrLn "hello"
  runProcess node $ do
    spawnLocal $ logWriter "server.log"
    runAProcess st $ withLogVariable "process" ("server" :: String) $ do
        nWorkers <- asksConfig pcWorkersCount
        forM_ [0 .. nWorkers-1] $ \idx ->
            spawnAProcess "processor" idx $ processor proto idx

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess "port" portNumber $ serverConnection localhost portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber)
              lift $ link m
              r <- spawnAProcess "reader" portNumber (reader proto extPort)
              lift $ link r
              $debug "server spawned reader: {}" (Single $ show extPort)
              w <- spawnAProcess "writer" portNumber (writer proto extPort)
              lift $ link w
              $debug "server spawned writer: {}" (Single $ show extPort)
              return ()

  putStrLn "hit enter..."
  getLine
  return ()
    
