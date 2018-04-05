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
import System.Log.Heavy.TH
import Data.Text.Format.Heavy

import Types
import Connection
import Pool

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

reader :: ExtPort -> AProcess ()
reader port = do
    $info "hello from reader: {}" (Single $ show port)
    loop `finally` closeServerConnection
  where
    loop = forever $ do
            msg <- liftIO $ readMessage port SimpleFrame
            lift $ nsend "worker" (msg :: MyMessage)

    closeServerConnection =
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

writer :: ExtPort -> AProcess ()
writer port = do
    let portNumber = getPortNumber port
    self <- lift getSelfPid
    lift $ register ("writer:"++show portNumber) self
    loop `finally` closeServerConnection
  where
    loop =
        forever $ do
          $info "hello from writer: {}" (Single $ show port)
          msg <- lift expect
          liftIO $ writeMessage port SimpleFrame (msg :: MyMessage)

    closeServerConnection =
      case port of
        ServerPort _ conn _ -> liftIO $ close conn
        _ -> return ()

clientWorker :: [PortNumber] -> Int -> AProcess ()
clientWorker ports base = do
  self <- lift getSelfPid
  lift $ register "worker" self
  $info "hello from client worker" ()
  forM_ [1 .. 10] $ \id -> do
    let key = (base + (2*id)) :: Int
    let msg = MyMessage False key "request"
    $info "client request: {}" (Single $ show msg)
    let n = length ports
    idx <- liftIO $ randomRIO (0,n-1)
    let portNumber = (ports !! idx)
    lift $ nsend ("writer:"++show portNumber) msg
    $info "client sent request: {}" (Single $ show msg)
    msg' <- lift expect
    $info "client worker {}: response received: {}" (show base, show (msg' :: MyMessage))

serverWorker :: [PortNumber] -> AProcess ()
serverWorker ports = do
  self <- lift getSelfPid
  lift $ register "worker" self
  $info "hello from server worker" ()
  forever $ do
    msg <- lift expect
    $info "server worker: request received: {}" (Single $ show (msg :: MyMessage))
    let msg' = msg {mIsResponse = True, mKey = mKey msg + 1, mPayload = "response"}
    let n = length ports
    idx <- liftIO $ randomRIO (0,n-1)
    let portNumber = (ports !! idx)
    lift $ nsend ("writer:"++show portNumber) msg'
    $info "server worker: response sent" ()

localhost = "127.0.0.1"

mkExternalService port = (localhost, port)

logSettings = defaultSyslogSettings {ssFormat = "[{level}] {source} {process} {thread}: {message}"}

runClient minPort maxPort = do
  Right transport <- createTransport localhost "10501" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  runProcess node $ do
    withLoggingT (LoggingSettings logSettings) $ do
      let frame = LogContextFrame [("process", Variable ("client" :: String))] noChange
      withLogContext frame $ do
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess $ clientConnection localhost portNumber $ \extPort -> do
              w <- spawnAProcess (writer extPort)
              lift $ link w
              $info "client spawned writer" ()
              r <- spawnAProcess (reader extPort)
              lift $ link r
              $info "client spawned reader" ()
              return ()

        liftIO $ threadDelay $ 100*1000

        $info "hello" ()
        spawnAProcess $
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
    withLoggingT (LoggingSettings logSettings) $ do
      let frame = LogContextFrame [("process", Variable ("server" :: String))] noChange
      withLogContext frame $ do
        spawnAProcess $ serverWorker [minPort .. maxPort]

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess $ serverConnection localhost portNumber $ \extPort -> do
              r <- spawnAProcess (reader extPort)
              lift $ link r
              $info "server spawned reader: {}" (Single $ show extPort)
              w <- spawnAProcess (writer extPort)
              lift $ link w
              $info "server spawned writer: {}" (Single $ show extPort)
              return ()

  putStrLn "hit enter..."
  getLine
  return ()
    
