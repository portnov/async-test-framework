{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}

module MyProtocol where

import Control.Distributed.Process.Node
import qualified Control.Monad.Metrics as Metrics
import Data.Binary
import qualified Data.ByteString.Lazy as L
import Data.String
import Network.Transport.TCP (createTransport, defaultTCPParameters)
import GHC.Generics

import Network.Concurrent.Ampf
import Network.Concurrent.Ampf.Connection (LeadingSize (..))

data MyProtocol = MyProtocol

data MyMessage = 
    MyMessage {
        mIsResponse :: Bool
      , mKey :: Int
      , mPayload :: L.ByteString
      }
      deriving (Eq, Show, Generic)

instance Protocol MyProtocol where
  type ProtocolFrame MyProtocol = LeadingSize
  type ProtocolMessage MyProtocol = MyMessage

  data ProtocolSettings MyProtocol = MySettings Int

  type ProtocolState MyProtocol = Int

  getFrame _ = return LeadingSize

  -- initProtocol (MySettings key) = putP key

  initialState (MySettings key) = key

  makeLogonMsg _ = return $ MyMessage False 0 "logon"

  generateRq _ myIndex = do
    key <- getP
    putP $ key+1
    n <- asksConfig pcWorkersCount
    let key' = key * n + myIndex
    return $ MyMessage False key' "request"

  processRq _ msg = do
    return $ msg {mIsResponse = True, mPayload = "response"}

instance Binary MyMessage where

instance IsMessage MyMessage where
  isResponse = mIsResponse
  isRequestDeclinedResponse _ = False
  isAdministrative _ = False
  getMatchKey m = fromString (show $ mKey m)

mkExternalService cfg port = (pcHost cfg, port)

runClient :: Metrics.Metrics -> ProcessConfig -> IO ()
runClient metrics cfg = do
  Right transport <- createTransport (pcHost cfg) "10501" (mkExternalService cfg) defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  runProcess node $ do
    runSite True MyProtocol (MySettings 100) metrics cfg

  return ()

runServer :: Metrics.Metrics -> ProcessConfig -> IO ()
runServer metrics cfg = do
  Right transport <- createTransport (pcHost cfg) "10502" (mkExternalService cfg) defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  runProcess node $ do
    runSite False MyProtocol (MySettings 200) metrics cfg

  return ()
    
