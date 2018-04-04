{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Tests where

import Control.Monad
import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Data.Binary
import qualified Data.ByteString.Lazy as L
import Data.String
import Network.Socket
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import GHC.Generics
import Text.Printf

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

serverTalker :: ExtPort -> Process ()
serverTalker port = do
    liftIO $ putStrLn $ "accepted: " ++ show port
    msg <- liftIO $ readMessage port SimpleFrame 
    liftIO $ printf "server talker %s: request received: %s\n" (show port) (show (msg :: MyMessage))
    let msg' = msg {mIsResponse = True, mKey = mKey msg + 1, mPayload = "response"}
    liftIO $ writeMessage port SimpleFrame msg'
    liftIO $ printf "server talker %s: response sent\n" (show port)

clientTalker :: Int -> Int -> ExtPort -> Process ()
clientTalker base id port = do
    let key = (base + (2*id)) :: Int
    let msg = MyMessage False key "request"
    liftIO $ writeMessage port SimpleFrame msg
    liftIO $ printf "client talker %s: request sent\n" (show base)
    msg' <- liftIO $ readMessage port SimpleFrame
    liftIO $ printf "client talker %s: response received: %s\n" (show base) (show (msg' :: MyMessage))

localhost = "127.0.0.1"

mkExternalService port = (localhost, port)

runClient minPort maxPort = do
  Right transport <- createTransport localhost "10501" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  forM_ [minPort .. maxPort] $ \portNumber -> do
    forkProcess node $ do
      clientConnection localhost portNumber $ \extPort -> do
        forM_ [1 .. 10] $ \id -> do
          clientTalker (fromIntegral portNumber) id extPort
  putStrLn "hit enter..."
  getLine
  return ()

runServer minPort maxPort = do
  Right transport <- createTransport localhost "10502" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  forM_ [minPort .. maxPort] $ \portNumber -> do
    forkProcess node $ do
      serverConnection localhost portNumber $ \extPort -> do
        forever $ serverTalker extPort
  putStrLn "hit enter..."
  getLine
  return ()
    
