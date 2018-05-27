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

localhost = "127.0.0.1"

mkExternalService port = (localhost, port)

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

runClient :: Metrics.Metrics -> ProcessConfig -> IO ()
runClient metrics cfg = do
  Right transport <- createTransport localhost "10501" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  let minPort = pcMinPort cfg
      maxPort = pcMaxPort cfg

  rps <- newIORef (0,0)
  let st0 = initialState (MySettings 100)
      st = ProcessState [] metrics cfg (pcGeneratorEnabled cfg) 1000 (pcGeneratorTargetRps cfg) rps st0
      proto = MyProtocol

  runProcess node $ do
    spawnLocal $ logWriter "client.log"

    runAProcess st $ withLogVariable "process" ("client" :: String) $ do
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
            spawnAProcess "port" portNumber $ clientConnection localhost portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber matcherTimeout)
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
        when isGenerator $ do
          forM_ [0 .. nWorkers-1] $ \idx ->
              spawnAProcess "generator" idx $ generator proto idx

        return ()

    runAProcess st $ withLogVariable "process" ("repl" :: String) repl

  return ()

runServer :: Metrics.Metrics -> ProcessConfig -> IO ()
runServer metrics cfg = do
  Right transport <- createTransport localhost "10502" mkExternalService defaultTCPParameters
  node <- newLocalNode transport initRemoteTable

  let minPort = pcMinPort cfg
      maxPort = pcMaxPort cfg

  rps <- newIORef (0,0)
  let st0 = initialState (MySettings 200)
      st = ProcessState [] metrics cfg (pcGeneratorEnabled cfg) 1000 (pcGeneratorTargetRps cfg) rps st0
      proto = MyProtocol

  putStrLn "hello"
  runProcess node $ do
    spawnLocal $ logWriter "server.log"
    runAProcess st $ withLogVariable "process" ("server" :: String) $ do
        spawnAProcess "monitor" 0 $ do
            liftP $ register "monitor" =<< getSelfPid
            globalCollector

        spawnAProcess "rps controller" 0 rpsController

        nWorkers <- asksConfig pcWorkersCount
        isGenerator <- asksConfig pcIsGenerator
        matcherTimeout <- asksConfig pcMatcherTimeout
        when (not isGenerator) $ do
            forM_ [0 .. nWorkers-1] $ \idx -> do
                spawnAProcess "processor" idx $ processor proto idx

        liftIO $ threadDelay $ 100*1000
          
        forM_ [minPort .. maxPort] $ \portNumber -> do
            spawnAProcess "port" portNumber $ serverConnection localhost portNumber $ \extPort -> do
              let portNumber = getPortNumber extPort
              m <- lift $ spawnLocal (matcher portNumber matcherTimeout)
              lift $ link m
              r <- spawnAProcess "reader" portNumber (reader proto extPort)
              lift $ link r
              $debug "server spawned reader: {}" (Single $ show extPort)
              w <- spawnAProcess "writer" portNumber (writer proto extPort)
              lift $ link w
              $debug "server spawned writer: {}" (Single $ show extPort)
              return ()

        when isGenerator $ do
            forM_ [0 .. nWorkers-1] $ \idx -> do
                spawnAProcess "generator" idx $ generator proto idx

        return ()

    runAProcess st $ withLogVariable "process" ("repl" :: String) repl

  return ()
    
