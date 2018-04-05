
module Connection where

import Control.Monad
-- import Control.Exception.Lifted (bracket)
import Control.Monad.Catch (bracket)
import Control.Concurrent
import Control.Distributed.Process hiding (bracket)
import Control.Distributed.Process.MonadBaseControl () -- instances only
import Data.Binary
import Data.Word
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Network.Socket hiding (recv)
import Network.Socket.ByteString.Lazy (recv, sendAll)
import Text.Printf

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
    printf "reading bytes: %s from: %s\n" (show len) (show sock)
    bin <- readN len sock
    --B.putStrLn bin
    let msg = decode $ bin 
    --utStrLn $ "Read message #" ++ show msg ++ " from port " ++ show port
    return msg

  sendMessage sock _ msg = do 
    let bin = encode msg
    let len = fromIntegral (L.length bin) :: Word16
    let lenStr = encode len
    printf "sending bytes: %s to: %s\n" (show len) (show sock)
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
  let extPort = ServerPort port conn sock
  putStrLn $ "Accepted: server port #" ++ show extPort
  return extPort

serverConnection :: String -> PortNumber -> (ExtPort -> Process ()) -> Process ()
serverConnection host portNumber proc = bracket init done loop
  where
    init = liftIO $ do
      addrinfos <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]})) Nothing (Just $ show portNumber)
      let serveraddr = head addrinfos
      sock <- socket (addrFamily serveraddr) Stream defaultProtocol
      bind sock (addrAddress serveraddr)
      listen sock 100
      putStrLn $ "Listening: " ++ show portNumber
      return sock

    done sock = liftIO $ close sock

    loop sock = 
      forever $ do
        (conn, _) <- liftIO $ accept sock
        let extPort = ServerPort portNumber conn sock
        liftIO $ putStrLn $ "Accepted: server port #" ++ show extPort
        spawnLocal $ proc extPort

clientConnection :: String -> PortNumber -> (ExtPort -> Process ()) -> Process ()
clientConnection host portNumber proc = do
  extPort <- liftIO $ getClientAddr host portNumber
  proc extPort

