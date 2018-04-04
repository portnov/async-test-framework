
module Types where

import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Map as M
import Data.Binary
import qualified Data.ByteString.Lazy as L
import Network.Socket

data ExtPort =
  ClientPort PortNumber Socket
  | ServerPort PortNumber Socket Socket
  deriving (Eq, Show)

type MatchKey = L.ByteString

class Binary m => IsMessage m where
  isResponse :: m -> Bool
  isAdministrative :: m -> Bool
  getMatchKey :: m -> MatchKey

class IsFrame f where
  recvMessage :: IsMessage m => Socket -> f -> IO m
  sendMessage :: IsMessage m => Socket -> f -> m -> IO ()

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

