{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module Network.Concurrent.Ampf.Utils where

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Builder as Builder
import Network.Concurrent.Ampf.Types

getAllWriterNames :: ProcessMonad m => m [String]
getAllWriterNames = do
    minPort <- asksConfig pcMinPort
    maxPort <- asksConfig pcMaxPort
    return ["writer:" ++ show port | port <- [minPort .. maxPort]]

getAllWorkerNames :: ProcessMonad m => m [String]
getAllWorkerNames = do
  count <- asksConfig pcWorkersCount
  return ["worker:" ++ show i | i <- [0 .. count-1]]

getAllProcessorNames :: ProcessMonad m => m [String]
getAllProcessorNames = do
  count <- asksConfig pcWorkersCount
  return ["processor:" ++ show i | i <- [0 .. count-1]]

getAllGeneratorNames :: ProcessMonad m => m [String]
getAllGeneratorNames = do
  count <- asksConfig pcWorkersCount
  return ["generator:" ++ show i | i <- [0 .. count-1]]

hex :: L.ByteString -> L.ByteString
hex str = Builder.toLazyByteString $ Builder.lazyByteStringHex str

