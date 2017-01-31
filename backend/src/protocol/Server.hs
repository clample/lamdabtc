{-# LANGUAGE DuplicateRecordFields #-}
module Protocol.Server where

import qualified Data.ByteString.Char8 as Char8
import Protocol.Parser (parseMessage)
import Messages (getAddr, putMessage)
import Protocol.Types (Network(..), Addr(..), MessageContext(..), Message(..), MessageBody(..))
import Text.Megaparsec (parseMaybe)
import Network.Socket (connect
                      , socket
                      , Family(..)
                      , SocketType(..)
                      , defaultProtocol
                      , connect
                      , SockAddr(..)
                      , tupleToHostAddress
                      , getAddrInfo
                      , AddrInfo(..)
                      , iNADDR_ANY
                      , bind
                      , defaultHints
                      , AddrInfoFlag(..)
                      , setSocketOption
                      , SocketOption(..)
                      , hostAddressToTuple
                      , Socket)
import Network.Socket.ByteString (send, recv )
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Data.ByteString.Base16 (decode, encode)
import Control.Monad.State.Lazy (StateT(..), runStateT, liftIO)
import qualified Control.Monad.State.Lazy as State
import System.Random (randomR, StdGen, getStdGen)
import Conduit (Producer(..), runConduit, (.|), mapC, mapMC)
import Data.Conduit.Combinators (encodeBase16, stdout)
import Data.Conduit.Network (sourceSocket, sinkSocket)
import Data.Conduit.Serialization.Binary (conduitGet, conduitPut)
import Data.Conduit.TMChan (sourceTBMChan, sinkTBMChan, newTBMChan, TBMChan, writeTBMChan, readTBMChan)
import Control.Concurrent.STM (atomically, STM(..))
import Control.Concurrent (forkIO)
import Data.ByteString (ByteString)
import Data.Binary.Get ()
import Data.Binary.Put (runPut)
import Data.Binary (Binary(..))
import qualified Data.ByteString.Lazy as BL


data ConnectionContext = ConnectionContext
  { version' :: Int
  , lastBlock' :: Integer
  , myAddr' :: Addr
  , peer' :: Peer
  , relay' :: Bool
    -- https://github.com/bitcoin/bips/blob/master/bip-0037.mediawiki#extensions-to-existing-messages
    -- Relay should be set to False when functioning as an SPV node
  , network' :: Network
  , writerChan :: TBMChan Message
  , listenChan :: TBMChan Message
  , time :: POSIXTime
  , randGen :: StdGen
  } 

data Peer = Peer Socket Addr
  deriving (Show, Eq)


type Connection a = StateT ConnectionContext STM a

runConnection :: Connection a -> ConnectionContext -> STM (a, ConnectionContext)
runConnection connection state = runStateT connection state

-- Find testnet hosts with `nslookup testnet-seed.bitcoin.petertodd.org`

connectTestnet :: Int -> IO () 
connectTestnet n = do
  addrInfo <- (!! n) <$> getAddrInfo Nothing (Just "testnet-seed.bitcoin.petertodd.org") (Just "18333")
  peerSocket <- socket (addrFamily addrInfo) Stream defaultProtocol
  setSocketOption peerSocket KeepAlive 1
  connect peerSocket (addrAddress addrInfo)
  writeChan <- atomically $ newTBMChan 16
  listenChan <- atomically $ newTBMChan 16
  time' <- getPOSIXTime
  randGen' <- getStdGen
  let context = ConnectionContext
        { version' = 60002
        , lastBlock' = 100
        , myAddr' = Addr (0, 0, 0, 0) 18333 
        , peer' = Peer peerSocket (getAddr $ addrAddress addrInfo)
        , relay' = False 
        , network' = TestNet3
        , writerChan = writeChan
        , listenChan = listenChan
        , time = time'
        , randGen = randGen'
        }
  -- Fork listener then writer
  forkIO $ listener listenChan peerSocket
  forkIO $ writer writeChan peerSocket
  connection context
  

instance Binary Message where
  put = putMessage
  get = parseMessage


listener :: TBMChan Message -> Socket -> IO ()
listener chan socket = runConduit
  $  sourceSocket socket
  .| conduitGet parseMessage
  .| logMessages "incoming"
  .| sinkTBMChan chan True 


writer :: TBMChan Message  -> Socket -> IO ()
writer chan socket = runConduit
  $  sourceTBMChan chan
  .| logMessages "outgoing"
  .| mapC put
  .| conduitPut
  .| sinkSocket socket


logMessages context =
  mapMC logAndReturn
  where logAndReturn message = do
          putStrLn $ context ++ " " ++ show message
          return message

connection :: ConnectionContext -> IO ()
connection context = do
  atomically $ runConnection sendVersion context
  connectionLoop context

connectionLoop :: ConnectionContext -> IO ()
connectionLoop context = do
  atomically $ flip runConnection context $ do
    mResponse <-  State.lift $ readTBMChan (listenChan context)
    case mResponse of
      Nothing -> fail "listenChan is closed and empty"
      Just response -> handleResponse response
  connectionLoop context
  
handleResponse :: Message -> Connection ()

handleResponse (Message (VersionMessage {}) _) = do
  connectionContext <- State.get
  let
    network = network' connectionContext
    writerChan' = writerChan connectionContext
    verackMessage = Message VerackMessage (MessageContext network)
  State.lift $ writeTBMChan writerChan' verackMessage

handleResponse (Message PingMessage _) = do
  connectionContext <- State.get
  let
    network = network' connectionContext
    writerChan' = writerChan connectionContext
    pongMessage = Message PongMessage (MessageContext network)
  State.lift $ writeTBMChan writerChan' pongMessage

handleResponse _ = do
  return ()

sendVersion :: Connection ()
sendVersion = do
  connectionContext <- State.get
  let (ConnectionContext
       { version' = version'
       , lastBlock' = lastBlock'
       , relay' = relay'
       , myAddr' = myAddr'
       , peer' = Peer peerSocket peerAddr'
       , network' = network'
       , writerChan = writerChan
       , time = time
       , randGen = randGen
       }) = connectionContext
      nonce' = fst $ randomR (0, 0xffffffffffffffff ) randGen
      versionMessage = Message
          (VersionMessage version' nonce' lastBlock' peerAddr' myAddr' relay' time)
          (MessageContext network')
  State.lift $ do
    writeTBMChan writerChan versionMessage

   
  
