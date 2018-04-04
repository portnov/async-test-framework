module Main where

import System.Environment

import Types
import Connection
import Pool
import Tests

main :: IO ()
main = do
  [arg] <- getArgs
  case arg of
    "client" -> runClient 9090 9091
    "server" -> runServer 9090 9091
