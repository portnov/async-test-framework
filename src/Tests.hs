{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Tests where

import Control.Monad
import Control.Monad.Reader hiding (reader)
import Control.Monad.Trans
import Control.Concurrent
import Control.Distributed.Process hiding (bracket, finally)
import Control.Distributed.Process.Node
import Control.Monad.Catch (bracket, finally)
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

data MyMessage = MyMessage {
    mIsResponse :: Bool
  , mKey :: Int
  , mPayload :: L.ByteString
  }
  deriving (Eq, Show, Generic)

instance Binary MyMessage where

instance IsMessage MyMessage where
  isResponse = mIsResponse
  isAdministrative _ = False
  getMatchKey m = fromString (show $ mKey m)

askPortsCount :: AProcess Int
askPortsCount = do
  minPort <- asks pcMinPort
  maxPort <- asks pcMaxPort
  return $ fromIntegral $ maxPort - minPort + 1

sendWorker :: ExtPort -> Maybe ProcessId -> MyMessage -> AProcess ()
sendWorker srcPort Nothing msg = do
  count <- asks pcWorkersCount
  idx <- liftIO $ randomRIO (0, count-1)
  let name = "worker:" ++ show idx
  lift $ nsend name (getPortNumber srcPort, msg)
sendWorker srcPort (Just worker) msg = do
  lift $ send worker (getPortNumber srcPort, msg)

sendWriter :: Maybe PortNumber -> MyMessage -> AProcess ()
sendWriter mbPort msg = do
  port <- case mbPort of
           Just srcPort -> return srcPort
           Nothing -> do
              minPort <- asks pcMinPort
              maxPort <- asks pcMaxPort
              let count = fromIntegral $ maxPort - minPort + 1
              idx <- liftIO $ randomRIO (0, count-1)
              return $ minPort + fromIntegral (idx :: Int)
  when (not $ mIsResponse msg) $ do
      lift $ registerRq port (mKey msg)
  let name = "writer:" ++ show port
  lift $ nsend name msg

reader :: ExtPort -> AProcess ()
reader port = do
    $debug "hello from reader: {}" (Single $ show port)
    loop `finally` closeServerConnection
  where
    loop :: AProcess ()
    loop = forever $ do
            msg <- liftIO $ readMessage port SimpleFrame
            if mIsResponse msg
              then do
                mbRequester <- lift $ whoSentRq (getPortNumber port) (mKey msg)
                case mbRequester of
                  Nothing -> 
                    $reportError "Received response #{} for request that we did not send, skipping" (Single $ mKey msg)
                  Just requester -> sendWorker port (Just requester) msg
              else sendWorker port Nothing msg

    closeServerConnection =
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

writer :: ExtPort -> AProcess ()
writer port = do
    let portNumber = getPortNumber port
    self <- lift getSelfPid
    let name = "writer:" ++ show portNumber
    lift $ register name self
    loop `finally` closeServerConnection
  where
    loop =
        forever $ do
          $debug "hello from writer: {}" (Single $ show port)
          msg <- lift expect
          liftIO $ writeMessage port SimpleFrame (msg :: MyMessage)

    closeServerConnection =
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

receiveResponse :: Int -> AProcess MyMessage
receiveResponse key =
    lift $ receiveWait [
      matchIf isSuitable (return . snd)
    ]
  where
    isSuitable :: (PortNumber, MyMessage) -> Bool
    isSuitable (_, msg) =
      mIsResponse msg && mKey msg == key

generator :: Int -> AProcess ()
generator myIndex = do
  self <- lift getSelfPid
  let myName = "worker:" ++ show myIndex
  lift $ register myName self

  $debug "hello from client worker #{}" (Single myIndex)
  forM_ [1 .. 40] $ \id -> do
    let key = (myIndex*100 + (2*id)) :: Int
    let msg = MyMessage False key "request"
    sendWriter Nothing msg
    $info "sent request #{}" (Single key)
    msg' <- receiveResponse (mKey msg)
    when (mKey msg' /= mKey msg) $
        fail "Suddenly received incorrect reply"
    $info "response received: #{}" (Single $ mKey msg')

processor :: Int -> AProcess ()
processor myIndex = do
  self <- lift getSelfPid
  let myName = "worker:" ++ show myIndex
  lift $ register myName self
  $debug "hello from server worker #{}" (Single myIndex)
  forever $ do
    (srcPort, msg) <- lift expect :: AProcess (PortNumber, MyMessage)
    $info "request received: #{}" (Single $ mKey msg)
    let msg' = msg {mIsResponse = True, mPayload = "response"}
    delay <- liftIO $ randomRIO (0, 10)
    liftIO $ threadDelay $ delay * 100 * 1000
    sendWriter (Just srcPort) msg'
    $info "response sent: #{}" (Single $ mKey msg)

localhost = "127.0.0.1"

mkExternalService port = (localhost, port)

runClient cfg = do
  Right transport <- createTransport localhost "10501" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  let minPort = pcMinPort cfg
      maxPort = pcMaxPort cfg

  runProcess node $ do
    spawnLocal $ logWriter "client.log"
    runAProcess cfg $ withLogVariable "process" ("client" :: String) $ do
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess "port" portNumber $ clientConnection localhost portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber)
              lift $ link m
              w <- spawnAProcess "writer" portNumber (writer extPort)
              lift $ link w
              $debug "client spawned writer" ()
              r <- spawnAProcess "reader" portNumber (reader extPort)
              lift $ link r
              $debug "client spawned reader" ()
              return ()

        liftIO $ threadDelay $ 100*1000

        $debug "hello" ()
        nWorkers <- asks pcWorkersCount
        forM_ [0 .. nWorkers-1] $ \idx ->
            spawnAProcess "generator" idx $ generator idx
        return ()

  putStrLn "hit enter..."
  getLine
  return ()

runServer cfg = do
  Right transport <- createTransport localhost "10502" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  let minPort = pcMinPort cfg
      maxPort = pcMaxPort cfg

  putStrLn "hello"
  runProcess node $ do
    spawnLocal $ logWriter "server.log"
    runAProcess cfg $ withLogVariable "process" ("server" :: String) $ do
        nWorkers <- asks pcWorkersCount
        forM_ [0 .. nWorkers-1] $ \idx ->
            spawnAProcess "processor" idx $ processor idx

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess "port" portNumber $ serverConnection localhost portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber)
              lift $ link m
              r <- spawnAProcess "reader" portNumber (reader extPort)
              lift $ link r
              $debug "server spawned reader: {}" (Single $ show extPort)
              w <- spawnAProcess "writer" portNumber (writer extPort)
              lift $ link w
              $debug "server spawned writer: {}" (Single $ show extPort)
              return ()

  putStrLn "hit enter..."
  getLine
  return ()
    
