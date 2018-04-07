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
import Network.Socket
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

sendWorker :: ExtPort -> MyMessage -> AProcess ()
sendWorker srcPort msg = do
  count <- asks pcWorkersCount
  idx <- liftIO $ randomRIO (0, count-1)
  let name = "worker:" ++ show idx
  lift $ nsend name (getPortNumber srcPort, msg)

sendWriter :: Maybe ExtPort -> MyMessage -> AProcess ()
sendWriter mbPort msg = do
  port <- case mbPort of
           Just extPort -> return $ getPortNumber extPort
           Nothing -> do
              minPort <- asks pcMinPort
              maxPort <- asks pcMaxPort
              let count = fromIntegral $ maxPort - minPort + 1
              idx <- liftIO $ randomRIO (0, count-1)
              return $ minPort + fromIntegral (idx :: Int)
  let name = "writer:" ++ show port
  lift $ nsend name msg

reader :: ExtPort -> AProcess ()
reader port = do
    $debug "hello from reader: {}" (Single $ show port)
    loop `finally` closeServerConnection
  where
    loop = forever $ do
            msg <- liftIO $ readMessage port SimpleFrame
            sendWorker port msg

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

clientWorker :: Int -> AProcess ()
clientWorker myIndex = do
  self <- lift getSelfPid
  let myName = "worker:" ++ show myIndex
  lift $ register myName self

  $debug "hello from client worker #{}" (Single myIndex)
  forM_ [1 .. 40] $ \id -> do
    let key = (myIndex*100 + (2*id)) :: Int
    let msg = MyMessage False key "request"
    sendWriter Nothing msg
    $info "client worker #{}: sent request #{}" (myIndex, key)
    (_, msg') <- lift expect :: AProcess (PortNumber, MyMessage)
    $info "client worker #{}: response received: #{}" (myIndex, mKey msg')

serverWorker :: Int -> AProcess ()
serverWorker myIndex = do
  self <- lift getSelfPid
  let myName = "worker:" ++ show myIndex
  lift $ register myName self
  $debug "hello from server worker #{}" (Single myIndex)
  forever $ do
    (_,msg) <- lift expect :: AProcess (PortNumber, MyMessage)
    $info "server worker #{}: request received: #{}" (myIndex, mKey msg)
    let msg' = msg {mIsResponse = True, mPayload = "response"}
    delay <- liftIO $ randomRIO (0, 5)
    liftIO $ threadDelay $ delay * 100 * 1000
    sendWriter Nothing msg'
    $info "server worker #{}: response sent: #{}" (myIndex, mKey msg)

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
            spawnAProcess $ clientConnection localhost portNumber $ \extPort -> do
              w <- spawnAProcess (writer extPort)
              lift $ link w
              $debug "client spawned writer" ()
              r <- spawnAProcess (reader extPort)
              lift $ link r
              $debug "client spawned reader" ()
              return ()

        liftIO $ threadDelay $ 100*1000

        $debug "hello" ()
        nWorkers <- asks pcWorkersCount
        forM_ [0 .. nWorkers-1] $ \idx ->
            spawnAProcess $ clientWorker idx
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
            spawnAProcess $ serverWorker idx

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess $ serverConnection localhost portNumber $ \extPort -> do
              r <- spawnAProcess (reader extPort)
              lift $ link r
              $debug "server spawned reader: {}" (Single $ show extPort)
              w <- spawnAProcess (writer extPort)
              lift $ link w
              $debug "server spawned writer: {}" (Single $ show extPort)
              return ()

  putStrLn "hit enter..."
  getLine
  return ()
    
