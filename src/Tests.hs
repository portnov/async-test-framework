{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Tests where

import Control.Monad
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

reader :: ExtPort -> Process ()
reader port = do
    $info "hello from reader: {}" (Single $ show port)
    loop `finally` closeServerConnection
  where
    loop = forever $ do
            msg <- liftIO $ readMessage port SimpleFrame
            nsend "worker" (msg :: MyMessage)

    closeServerConnection =
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

writer :: ExtPort -> Process ()
writer port = do
    let portNumber = getPortNumber port
    self <- getSelfPid
    register ("writer:"++show portNumber) self
    loop `finally` closeServerConnection
  where
    loop =
        forever $ do
          $info "hello from writer: {}" (Single $ show port)
          msg <- expect
          liftIO $ writeMessage port SimpleFrame (msg :: MyMessage)

    closeServerConnection =
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

clientWorker :: [PortNumber] -> Int -> Process ()
clientWorker ports base = do
  self <- getSelfPid
  register "worker" self
  $info "hello from client worker" ()
  forM_ [1 .. 10] $ \id -> do
    let key = (base + (2*id)) :: Int
    let msg = MyMessage False key "request"
    $info "client request: {}" (Single $ show msg)
    let n = length ports
    idx <- liftIO $ randomRIO (0,n-1)
    let portNumber = (ports !! idx)
    nsend ("writer:"++show portNumber) msg
    $info "client sent request: {}" (Single $ show msg)
    msg' <- expect
    $info "client worker {}: response received: {}" (show base, show (msg' :: MyMessage))

serverWorker :: [PortNumber] -> Process ()
serverWorker ports = do
  self <- getSelfPid
  register "worker" self
  $info "hello from server worker" ()
  forever $ do
    msg <- expect
    $info "server worker: request received: {}" (Single $ show (msg :: MyMessage))
    let msg' = msg {mIsResponse = True, mKey = mKey msg + 1, mPayload = "response"}
    let n = length ports
    idx <- liftIO $ randomRIO (0,n-1)
    let portNumber = (ports !! idx)
    nsend ("writer:"++show portNumber) msg'
    $info "server worker: response sent" ()

localhost = "127.0.0.1"

mkExternalService port = (localhost, port)

runClient minPort maxPort = do
  Right transport <- createTransport localhost "10501" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  runProcess node $ do
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnLocal $ clientConnection localhost portNumber $ \extPort -> do
              w <- spawnLocal (writer extPort)
              link w
              $info "client spawned writer" ()
              r <- spawnLocal (reader extPort)
              link r
              $info "client spawned reader" ()
              return ()

        liftIO $ threadDelay $ 100*1000

        $info "hello" ()
        spawnLocal $
            clientWorker [minPort .. maxPort] 100 
        return ()

  putStrLn "hit enter..."
  getLine
  return ()

runServer minPort maxPort = do
  Right transport <- createTransport localhost "10502" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  putStrLn "hello"
  runProcess node $ do
        spawnLocal $ serverWorker [minPort .. maxPort]

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnLocal $ serverConnection localhost portNumber $ \extPort -> do
              r <- spawnLocal (reader extPort)
              link r
              $info "server spawned reader: {}" (Single $ show extPort)
              w <- spawnLocal (writer extPort)
              link w
              $info "server spawned writer: {}" (Single $ show extPort)
              return ()

  putStrLn "hit enter..."
  getLine
  return ()
    
