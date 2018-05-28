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
import Data.IORef
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
import System.IO

import Types
import Connection
import Pool
import Logging
import Matcher
import Framework
import Monitoring

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

  generateRq _ myIndex = do
    key <- getP
    putP $ key+1
    n <- asksConfig pcWorkersCount
    let key' = key * n + myIndex
    return $ MyMessage False key' "request"

  processRq msg = do
    return $ msg {mIsResponse = True, mPayload = "response"}

type MyMessage = ProtocolMessage MyProtocol

instance Binary (ProtocolMessage MyProtocol) where

instance IsMessage (ProtocolMessage MyProtocol) where
  isResponse = mIsResponse
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
    
