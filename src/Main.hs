module Main where

import System.Environment

import Types
import Connection
import Pool
import Tests

main :: IO ()
main = do
  [arg] <- getArgs
  let cfg = ProcessConfig [] 9090 9100 4
  case arg of
    "client" -> runClient cfg
    "server" -> runServer cfg
