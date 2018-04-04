
module Connection where

import Control.Monad
import Control.Exception
import Control.Distributed.Process
import Data.Binary
import Data.Word
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Network.Socket hiding (recv)
import Network.Socket.ByteString.Lazy (recv, sendAll)
import Control.Concurrent

import Types

data SimpleFrame = SimpleFrame
  deriving (Eq, Show)

readN :: Word16 -> Socket -> IO L.ByteString
readN sz sock = go sz
  where
    go n = do
      d <- recv sock (fromIntegral n)
      let m = fromIntegral $ L.length d
      if m < n
        then do
             rest <- go (n-m)
             return $ d `L.append` rest
        else return d

instance IsFrame SimpleFrame where
  recvMessage sock _ = do
    putStrLn $ "waiting for message frame on " ++ show sock
    lenStr <- readN 2 sock
    let len = decode (lenStr) :: Word16
    putStrLn $ "reading bytes: " ++ show len
    bin <- readN len sock
    --B.putStrLn bin
    let msg = decode $ bin 
    --utStrLn $ "Read message #" ++ show msg ++ " from port " ++ show port
    return msg

  sendMessage sock _ msg = do 
    let bin = encode msg
    let len = fromIntegral (L.length bin) :: Word16
    let lenStr = encode len
    putStrLn $ "sending bytes: " ++ show len
    sendAll sock $ lenStr `L.append` bin

readMessage :: (IsMessage m, IsFrame f) => ExtPort -> f -> IO m
readMessage port frame = recvMessage (getSocket port) frame

writeMessage :: (IsMessage m, IsFrame f) => ExtPort -> f -> m -> IO ()
writeMessage port frame msg = sendMessage (getSocket port) frame msg

getSocket :: ExtPort -> Socket
getSocket (ClientPort _ sock) = sock
getSocket (ServerPort _ conn _) = conn

getPortNumber :: ExtPort -> PortNumber
getPortNumber (ClientPort p _) = p
getPortNumber (ServerPort p _ _) = p

closePort :: ExtPort -> IO ()
closePort (ClientPort p sock) = do
  putStrLn $ "closing " ++ show p
  close sock
closePort (ServerPort p conn sock) = do
  putStrLn $ "closing " ++ show p
  close conn
  close sock

getClientAddr host port = do
  addrinfos <- getAddrInfo Nothing (Just host) (Just $ show port)
  putStrLn $ "AddrInfos: " ++ show addrinfos
  let serveraddr = head addrinfos
  sock <- socket (addrFamily serveraddr) Stream defaultProtocol
  putStrLn $ "Socket: " ++ show sock
  connect sock (addrAddress serveraddr)
  putStrLn $ "Creating new client port #" ++ show port
  return $ ClientPort port sock

getServerAddr host port = do
  addrinfos <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]})) Nothing (Just $ show port)
  let serveraddr = head addrinfos
  sock <- socket (addrFamily serveraddr) Stream defaultProtocol
  bind sock (addrAddress serveraddr)
  listen sock 100
  putStrLn $ "Listening: " ++ show port
  (conn, _) <- accept sock
  putStrLn $ "Accepted: server port #" ++ show port
  return $ ServerPort port conn sock

serverConnection :: String -> PortNumber -> (ExtPort -> Process ()) -> Process ()
serverConnection host portNumber proc = do
  sock <- liftIO $ do
    addrinfos <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]})) Nothing (Just $ show portNumber)
    let serveraddr = head addrinfos
    sock <- socket (addrFamily serveraddr) Stream defaultProtocol
    bind sock (addrAddress serveraddr)
    listen sock 100
    putStrLn $ "Listening: " ++ show portNumber
    return sock
  forever $ do
    (conn, _) <- liftIO $ accept sock
    liftIO $ putStrLn $ "Accepted: server port #" ++ show portNumber
    let extPort = ServerPort portNumber conn sock
    proc extPort

clientConnection :: String -> PortNumber -> (ExtPort -> Process ()) -> Process ()
clientConnection host portNumber proc = do
  extPort <- liftIO $ getClientAddr host portNumber
  proc extPort

