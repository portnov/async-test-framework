{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

module Network.Concurrent.Ampf.Logging where

import Control.Monad
import Control.Monad.Trans
import Control.Monad.Logger (liftLoc, defaultLoc)
import Control.Distributed.Process hiding (bracket, finally)
import Control.Distributed.Process.MonadBaseControl () -- instances only
import qualified Data.Text.Lazy as TL
import Language.Haskell.TH hiding (match)
import Language.Haskell.TH.Syntax (qLocation)
import qualified Language.Haskell.TH.Lift as TH
import System.Log.Heavy
import System.Log.Heavy.TH ()

import Network.Concurrent.Ampf.Types

defaultLogSettings :: ProcessConfig -> LogBackendSettings (Filtering FastLoggerBackend) 
defaultLogSettings cfg =
  let fltr = [([], pcLogLevel cfg)]
  in filtering fltr $
          (defFileSettings (pcLogFilePath cfg)) {
            lsFormat = "{time} [{level}] {source} {process} {thread}#{index}: {message}\n"
          }

instance HasLoggingSettings (Filtering FastLoggerBackend) ProcessConfig where
  getLoggingSettings = defaultLogSettings

putMessage :: Level -> Q Exp
putMessage level = [| \msg vars -> do
  context <- getLogContext
  let loc = $(qLocation >>= liftLoc)
      src = splitDots (loc_module loc)
      message = LogMessage $(TH.lift level) src loc msg vars context
  lift $ nsend "logger" message
  |]

trace :: Q Exp
trace = putMessage trace_level

-- | TH macro to log a message with DEBUG level. Usage:
--
-- @
-- \$debug "hello, {}!" (Single name)
-- @
--
debug :: Q Exp
debug = putMessage debug_level

-- | TH macro to log a message with INFO level. Usage:
--
-- @
-- \$info "hello, {}!" (Single name)
-- @
--
info :: Q Exp
info = putMessage info_level

-- | TH macro to log a message with WARN level. Usage:
--
-- @
-- \$warning "Beware the {}!" (Single name)
-- @
--
warning :: Q Exp
warning = putMessage warn_level

-- | TH macro to log a message with ERROR level. Usage:
--
-- @
-- \$reportError "Transaction #{} was declined." (Single transactionId)
-- @
--
reportError :: Q Exp
reportError = putMessage error_level

-- | TH macro to log a message with FATAL level. Usage:
--
-- @
-- \$fatal "Cannot establish database connection" ()
-- @
--
fatal :: Q Exp
fatal = putMessage fatal_level

logWriter :: IsLogBackend b => LogBackendSettings b -> Process()
logWriter settings = do
    self <- getSelfPid
    reregister "logger" self
    withLoggingT (LoggingSettings settings) $ forever $ do
      logger <- getLogger
      lift $ receiveWait
        [match (\msg -> liftIO $ logger (fromSimple msg)),
         match (\msg -> liftIO $ logger (fromSay msg)),
         match (\msg -> liftIO $ logger msg)
        ]
  where
    fromSimple :: SimpleLogMessage -> LogMessage
    fromSimple (SimpleLogMessage lvl src text) =
      LogMessage {
        lmLevel = lvl,
        lmSource = [either id show src],
        lmLocation = defaultLoc,
        lmFormatString = text,
        lmFormatVars = (),
        lmContext = []
      }

    fromSay :: (String, ProcessId, String) -> LogMessage
    fromSay (time, pid, message) = LogMessage {
      lmLevel = debug_level,
      lmSource = ["Say", show pid],
      lmLocation = defaultLoc,
      lmFormatString = TL.pack message,
      lmFormatVars = (),
      lmContext = []
    }

