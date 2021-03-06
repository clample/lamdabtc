{-# LANGUAGE TemplateHaskell #-}
module Protocol.ConnectionM where

import Protocol.Messages (Message(..))
import General.Types ( HasVersion(..)
                     , HasRelay(..)
                     , HasTime(..)
                     , HasPeerAddr(..)
                     , Network(..)
                     , HasPool(..)
                     , HasNetwork(..))
import General.Config (HasAppChan(..), HasUIUpdaterChan(..))
import General.Util (Addr(..))
import General.InternalMessaging (UIUpdaterMessage(..), InternalMessage(..))
import Protocol.Util (HasLastBlock(..), BlockIndex(..))

import Data.Conduit.TMChan (TBMChan)
import Data.Time.Clock.POSIX (POSIXTime)
import System.Random (StdGen)
import Control.Lens (makeLenses, (^.))
import Network.Socket (Socket)
import Database.Persist.Sql (ConnectionPool)
import BitcoinCore.BlockHeaders (BlockHeader)


-- Only elements of `mutableContext` will be exposed for updates in the Connection' monad
data ConnectionContext = ConnectionContext
  { _connectionContextVersion :: Int
  , _myAddr :: Addr
  , _connectionContextPeerAddr :: Addr
  , _connectionContextRelay :: Bool
    -- https://github.com/bitcoin/bips/blob/master/bip-0037.mediawiki#extensions-to-existing-messages
    -- Relay should be set to False when functioning as an SPV node
  , _connectionContextTime :: POSIXTime
  , _connectionContextNetwork :: Network
  , _mutableContext :: MutableConnectionContext
  }

data MutableConnectionContext = MutableConnectionContext
  { _randGen :: StdGen
  , _rejectedBlocks :: [BlockHeader]
  , _connectionContextLastBlock :: BlockIndex
  }

makeLenses ''ConnectionContext
makeLenses ''MutableConnectionContext

data IOHandlers = IOHandlers
  { _peerSocket :: Socket
  , _writerChan :: TBMChan Message
  , _listenChan :: TBMChan Message
  , _ioHandlersUIUpdaterChan :: TBMChan UIUpdaterMessage
  , _ioHandlersAppChan :: TBMChan InternalMessage
  , _ioHandlersPool :: ConnectionPool
  }

makeLenses ''IOHandlers

instance HasPool IOHandlers where
  pool = ioHandlersPool

instance HasUIUpdaterChan IOHandlers where
  uiUpdaterChan = ioHandlersUIUpdaterChan

instance HasAppChan IOHandlers where
  appChan = ioHandlersAppChan

instance HasVersion ConnectionContext where
  version = connectionContextVersion

instance HasRelay ConnectionContext where
  relay = connectionContextRelay

instance HasTime ConnectionContext where
  time = connectionContextTime

instance HasLastBlock MutableConnectionContext where
  lastBlock = connectionContextLastBlock

instance HasPeerAddr ConnectionContext where
  peerAddr = connectionContextPeerAddr

instance HasNetwork ConnectionContext where
  network = connectionContextNetwork

data InterpreterContext = InterpreterContext
  { _ioHandlers  :: IOHandlers
  , _context     :: ConnectionContext
  , _logFilter   :: LogFilter
  }

data LogEntry = LogEntry
  { _logLevel :: LogLevel
  , _logStr   :: String
  } deriving (Show, Eq)

data LogLevel = Debug | Error
  deriving (Show, Eq)

type LogFilter = LogLevel -> Bool

makeLenses ''InterpreterContext
makeLenses ''LogEntry

displayLogs :: LogFilter -> [LogEntry] -> String
displayLogs f ls = unlines
                   . map formatLog
                   . filter (f . _logLevel) $ ls
  where
    formatLog l = show (l^.logLevel) ++  " " ++ (l^.logStr)
