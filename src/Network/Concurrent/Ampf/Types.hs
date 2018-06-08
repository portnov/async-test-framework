{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DefaultSignatures #-}

module Network.Concurrent.Ampf.Types where

import Control.Monad.Reader
import Control.Monad.State as St
import Control.Monad.Catch 
import Control.Distributed.Process hiding (bracket, mask, catch)
import Control.Distributed.Process.Serializable
import qualified Control.Monad.Metrics as Metrics
import qualified Data.Map as M
import qualified Data.Text.Lazy as TL
import Data.Typeable
import Data.Binary
import Data.Int
import Data.String
import Data.IORef
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Builder as Builder
import Network.Socket
import System.Log.Heavy
import System.Log.Heavy.Instances.Binary () -- import instances only
import GHC.Generics

data ExtPort =
  ClientPort PortNumber Socket
  | ServerPort PortNumber Socket Socket
  deriving (Eq, Show)

type MatchKey = L.ByteString

data MatcherStats = MatcherStats Int
  deriving (Typeable, Generic)

instance Binary MatcherStats

data ReplCommand = ReplCommand String
  deriving (Typeable, Generic)

instance Binary ReplCommand

class (Binary m, Typeable m) => IsMessage m where
  isResponse :: m -> Bool
  isAdministrative :: m -> Bool
  getMatchKey :: m -> MatchKey

  showKey :: m -> MatchKey
  showKey m = hex (getMatchKey m)

  isRequestDeclinedResponse :: m -> Bool
  isRequestDeclinedResponse m = not (isRequestApprovedResponse m)

  isRequestApprovedResponse :: m -> Bool
  isRequestApprovedResponse m = not (isRequestDeclinedResponse m)

  showFull :: m -> L.ByteString
  default showFull :: (Show m, IsMessage m) => m -> L.ByteString
  showFull m = fromString (show m)

  showMasked :: m -> L.ByteString
  showMasked = showFull

hex :: L.ByteString -> L.ByteString
hex str = Builder.toLazyByteString $ Builder.lazyByteStringHex str

class IsFrame f where
  recvMessage :: IsMessage m => Socket -> f -> IO m
  sendMessage :: IsMessage m => Socket -> f -> m -> IO ()

class (Monad m, MonadIO m, HasLogContext m, Metrics.MonadMetrics m, MonadMask m) => ProcessMonad m where
  liftP :: Process a -> m a
  askConfig :: m ProcessConfig
  -- spawnP :: m () -> m ProcessId

class (IsFrame (ProtocolFrame proto), IsMessage (ProtocolMessage proto))
    => Protocol proto where
  type ProtocolFrame proto
  type ProtocolMessage proto
  data ProtocolSettings proto
  type ProtocolState proto

  getFrame :: proto -> ProtocolM (ProtocolState proto) (ProtocolFrame proto)

  initProtocol :: ProtocolSettings proto -> ProtocolM (ProtocolState proto) proto

  initialState :: ProtocolSettings proto -> ProtocolState proto

  generateRq :: proto -> Int -> ProtocolM (ProtocolState proto) (ProtocolMessage proto)

  processRq :: proto -> ProtocolMessage proto -> ProtocolM (ProtocolState proto) (ProtocolMessage proto)

  processCommand :: proto -> Message -> ProtocolM (ProtocolState proto) ()
  processCommand _ _ = return ()

  onStartupCompleted :: proto -> ProtocolM (ProtocolState proto) ()
  onStartupCompleted _ = return ()


data PoolSettings = PoolSettings {
    pIsClient :: Bool
  , pHost :: String
  , pMinPort :: PortNumber
  , pMaxPort :: PortNumber
  }
  deriving (Eq, Show)

data ConnectionPool = ConnectionPool {
    cpSettings :: PoolSettings,
    cpPorts :: M.Map PortNumber ExtPort
  }

data SimpleLogMessage = SimpleLogMessage Level (Either String ProcessId) TL.Text
  deriving (Eq, Show, Typeable, Generic)

deriving instance Typeable LogMessage

instance Binary SimpleLogMessage

deriving instance Generic PortNumber

instance Binary PortNumber

data ProcessConfig = ProcessConfig {
    pcIsGenerator :: Bool,
    pcIsProcessor :: Bool,
    pcIsPort :: Bool,
    pcIsClient :: Bool,
    pcControlPort :: PortNumber,
    pcPeers :: [String],
    pcGeneratorEnabled :: Bool,
    pcGeneratorTargetRps :: Int,
    pcHost :: String,
    pcMinPort :: PortNumber,
    pcMaxPort :: PortNumber,
    pcWorkersCount :: Int,
    pcMonitorDelay :: Int,
    pcProcessorMinDelay :: Int,
    pcProcessorMaxDelay :: Int,
    pcEkgPort :: PortNumber,
    pcMatcherTimeout :: Int,
    pcGeneratorTimeout :: Int,
    pcLogFilePath :: FilePath,
    pcLogLevel :: Level,
    pcUseRepl :: Bool
  }
  deriving (Show)

class HasNetworkConfig cfg where
  getHostname :: cfg -> String
  getMinPort :: cfg -> PortNumber
  getMaxPort :: cfg -> PortNumber

instance HasNetworkConfig ProcessConfig where
  getHostname = pcHost
  getMinPort = pcMinPort
  getMaxPort = pcMaxPort

class HasNetworkConfig cfg => HasGeneratorConfig cfg where
  isGenerator :: cfg -> Bool
  runGeneratorAtStartup :: cfg -> Bool
  generatorTargetRps :: cfg -> Int
  generatorWorkersCount :: cfg -> Int
  generatorRequestTimeout :: cfg -> Int
  generatorMatchTimeout :: cfg -> Int

instance HasGeneratorConfig ProcessConfig where
  isGenerator = pcIsGenerator
  runGeneratorAtStartup = pcGeneratorEnabled
  generatorTargetRps = pcGeneratorTargetRps
  generatorWorkersCount = pcWorkersCount
  generatorRequestTimeout = pcGeneratorTimeout
  generatorMatchTimeout = pcMatcherTimeout

class HasNetworkConfig cfg => HasProcessorConfig cfg where
  isProcessor :: cfg -> Bool
  processorMinDelay :: cfg -> Int
  processorMaxDelay :: cfg -> Int

instance HasProcessorConfig ProcessConfig where
  isProcessor = pcIsProcessor
  processorMinDelay = pcProcessorMinDelay
  processorMaxDelay = pcProcessorMaxDelay

class HasLoggingSettings backend cfg where
  getLoggingSettings :: cfg -> LogBackendSettings backend

-- this is ProtocolM-specific
data ThreadState st = ThreadState {
    psContext :: LogContext,
    psMetrics :: Metrics.Metrics,
    psConfig :: ProcessConfig,
    psGeneratorEnabled :: Bool,
    psGeneratorDelay :: Int,
    psTargetRps :: Int,
    psRpsStats :: IORef (Int64, Int64),
    psState :: st
  }

data GeneratorCommand =
    StartGenerator
  | StopGenerator
  | SetTargetRps Int
  deriving (Typeable, Generic)

instance Binary GeneratorCommand

type ProtocolM st a = StateT (ThreadState st) Process a

getP :: ProtocolM st st
getP = gets psState

getsP :: (st -> a) -> ProtocolM st a
getsP fn = gets (fn . psState)

putP :: st -> ProtocolM st ()
putP x = modify $ \st -> st {psState = x}

instance HasLogContext (StateT (ThreadState st) Process) where
  getLogContext = gets psContext

  withLogContext frame actions = do
    context <- gets psContext
    let context' = frame : context
    modify $ \cfg -> cfg {psContext = context'}
    result <- actions
    modify $ \cfg -> cfg {psContext = context}
    return result

instance Metrics.MonadMetrics (StateT (ThreadState st) Process) where
  getMetrics = gets psMetrics

instance ProcessMonad (StateT (ThreadState st) Process) where
  liftP = lift

  askConfig = gets psConfig

asksConfig :: ProcessMonad m => (ProcessConfig -> a) -> m a
asksConfig fn = do
  cfg <- askConfig
  return $ fn cfg

spawnAProcess :: Show idx => String -> idx -> ProtocolM st () -> ProtocolM st ProcessId
spawnAProcess name idx proc = do
    cfg <- St.get
    lift $ spawnLocal $ do
             self <- getSelfPid
             evalProtocolM cfg $ withContext self proc
  where
    withContext pid =
          withLogVariable "pid" (show pid) .
          withLogVariable "thread" name .
          withLogVariable "index" (show idx)

type MatchP proto a = ThreadState (ProtocolState proto) -> Match (a, ThreadState (ProtocolState proto))

matchP :: (Protocol proto, Serializable a) => proto -> (a -> ProtocolM (ProtocolState proto) b) -> MatchP proto b
matchP proto handler st = match (\m -> runProtocolM st $ handler m)

matchAnyP :: (Protocol proto) => proto -> (Message -> ProtocolM (ProtocolState proto) b) -> MatchP proto b
matchAnyP proto handler st = matchAny (\m -> runProtocolM st $ handler m)

processMessages :: Protocol proto => proto -> [MatchP proto a] -> ProtocolM (ProtocolState proto) ()
processMessages _ handlers = St.get >>= go
  where
    go st = do
      (a, st) <- liftP $ receiveWait [handler st | handler <- handlers]
      go st

-- spawnAProcess :: forall m idx. (MonadBaseControl Process m, HasLogContext m, Show idx) => String -> idx -> m () -> m ProcessId
-- spawnAProcess name idx proc = do
-- 
--     -- Outside `control' call, we're in the `m' monad
--     liftBaseWith $ \runInProcess -> do -- runInProcess :: m a -> Process (StM m a)
--       -- here we're in the Process monad
--       self <- getSelfPid
--       step1 runInProcess self
-- 
--   where
--     step1 :: RunInBase m Process -> ProcessId -> Process ProcessId
--     step1 runInProcess self = do
--       spawnLocal $ do
--                 -- stm :: StM m ()
--                 stm <- runInProcess $ -- runInProcess (something :: m a) :: Process (StM m a)
--                         -- here we're in the `m' monad again
--                         withContext self proc
--                 return (restoreM stm) --  Process (m ())
-- 
--     withContext pid =
--           withLogVariable "pid" (show pid) .
--           withLogVariable "thread" name .
--           withLogVariable "index" (show idx)
    
evalProtocolM :: ThreadState st -> ProtocolM st () -> Process ()
evalProtocolM cfg proc = evalStateT proc cfg

runProtocolM :: ThreadState st -> ProtocolM st a -> Process (a, ThreadState st)
runProtocolM cfg proc = runStateT proc cfg

