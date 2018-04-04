
module Pool where

import Control.Monad
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import qualified Data.Map as M
import Network.Socket

import Types
import Connection

createPool :: PoolSettings -> IO ConnectionPool
createPool ps = do
    -- var <- newMVar M.empty
    -- when (not $ pIsClient ps) $ openAllServerPorts var
    pool <- startMap
    return $ ConnectionPool ps pool
  where
    startMap = do
      pairs <- forM [pMinPort ps .. pMaxPort ps] $ \portNumber -> do
                   putStrLn $ "startup: " ++ show portNumber
                   port <- if pIsClient ps
                             then getClientAddr (pHost ps) portNumber
                             else getServerAddr (pHost ps) portNumber
                   return (portNumber, port)
      return $ M.fromList pairs


getExtPort :: ConnectionPool -> PortNumber -> IO ExtPort
getExtPort (ConnectionPool ps pool) portNumber = do
    let portGetter = if pIsClient ps
                       then getClientAddr (pHost ps) portNumber
                       else getServerAddr (pHost ps) portNumber
    res <- case M.lookup portNumber pool of
                Nothing -> do -- port is not open
                  fail $ "port is not open: " ++ show portNumber
                Just port -> return port
    putStrLn $ "get: " ++ show res
    return res

releaseExtPort :: ConnectionPool -> ExtPort -> IO ()
releaseExtPort (ConnectionPool ps pool) port = do
  putStrLn $ "releasing port " ++ show port
  return ()

closePool :: ConnectionPool -> IO ()
closePool (ConnectionPool ps pool) = do
  forM_ (M.assocs pool) $ \(portNumber, port) -> do
        closePort port

