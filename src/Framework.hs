{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Framework where

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

getAllWriterNames :: ProcessMonad m => m [String]
getAllWriterNames = do
    minPort <- asksConfig pcMinPort
    maxPort <- asksConfig pcMaxPort
    return ["writer:" ++ show port | port <- [minPort .. maxPort]]

getAllWorkerNames :: ProcessMonad m => m [String]
getAllWorkerNames = do
  count <- asksConfig pcWorkersCount
  return ["worker:" ++ show i | i <- [0 .. count-1]]

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

checkGeneratorEnabled :: ProtocolM st Bool
checkGeneratorEnabled = do
  mbCommand <- liftP $ expectTimeout 0
  case mbCommand of
    Nothing -> gets psGeneratorEnabled
    Just StartGenerator -> do
      modify $ \st -> st {psGeneratorEnabled = True}
      return True
    Just StopGenerator -> do
      modify $ \st -> st {psGeneratorEnabled = False}
      return False

startGenerator :: ProtocolM st ()
startGenerator =
  sendAllWorkers StartGenerator

stopGenerator :: ProtocolM st ()
stopGenerator =
  sendAllWorkers StopGenerator

generator :: forall proto. Protocol proto => proto -> Int -> ProtocolM (ProtocolState proto) ()
generator proto myIndex = do
  self <- liftP getSelfPid
  let myName = "worker:" ++ show myIndex
  liftP $ register myName self

  $debug "hello from client worker #{}" (Single myIndex)
  forever $ do
    enabled <- checkGeneratorEnabled
    -- liftIO $ putStrLn $ show enabled
    if enabled
      then do
        request <- generateRq proto myIndex 
        let key = getMatchKey request
        Metrics.timed "generator.requests.duration" $ do
            sendWriter Nothing request
            $info "sent request #{}" (Single key)
            response <- receiveResponse (getMatchKey request) :: ProtocolM (ProtocolState proto) (ProtocolMessage proto)
            when (getMatchKey response /= getMatchKey request) $
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
    Metrics.timed "processor.requests.duration" $ do
      (srcPort, request) <- liftP expect :: ProtocolM (ProtocolState proto) (PortNumber, ProtocolMessage proto)
      $info "request received: #{}" (Single $ getMatchKey request)
      response <- processRq request
      -- delay <- liftIO $ randomRIO (0, 10)
      -- liftIO $ threadDelay $ delay * 100 * 1000
      sendWriter (Just srcPort) response
      $info "response sent: #{}" (Single $ getMatchKey response)


