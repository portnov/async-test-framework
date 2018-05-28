{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

module Utils where

import Types

getAllWriterNames :: ProcessMonad m => m [String]
getAllWriterNames = do
    minPort <- asksConfig pcMinPort
    maxPort <- asksConfig pcMaxPort
    return ["writer:" ++ show port | port <- [minPort .. maxPort]]

getAllWorkerNames :: ProcessMonad m => m [String]
getAllWorkerNames = do
  count <- asksConfig pcWorkersCount
  return ["worker:" ++ show i | i <- [0 .. count-1]]

