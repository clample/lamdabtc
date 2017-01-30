{-# LANGUAGE DuplicateRecordFields #-}
module Protocol.Server where

import qualified Data.ByteString.Char8 as Char8
import Protocol.Parser (parseMessage)
import Messages (getAddr, showMessage)
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
import Control.Monad.State.Lazy (StateT(..), runStateT, get, liftIO)
import System.Random (randomRIO)
import Conduit (Producer(..), runConduit, (.|), mapC)
import Data.Conduit.Combinators (encodeBase16, stdout)
import Data.Conduit.Network (sourceSocket, sinkSocket)
import Data.Conduit.Serialization.Binary (conduitGet)
import Data.ByteString (ByteString)
import Data.Binary.Get ()

data ConnectionContext = ConnectionContext
  { peer' :: Peer
  , version' :: Int
  , lastBlock' :: Integer
  , myAddr' :: Addr
  , relay' :: Bool
  , network' :: Network
  } deriving (Show, Eq)

data Peer = Peer Socket Addr
  deriving (Show, Eq)


type Connection a = StateT ConnectionContext IO a

runConnection :: Connection a -> ConnectionContext -> IO (a, ConnectionContext)
runConnection connection state = runStateT connection state

-- Find testnet hosts with `nslookup testnet-seed.bitcoin.petertodd.org`

connectTestnet :: Int -> IO () -- ConnectionContext
connectTestnet n = do
  addrInfo <- (!! n) <$> getAddrInfo Nothing (Just "testnet-seed.bitcoin.petertodd.org") (Just "18333")
  peerSocket <- socket (addrFamily addrInfo) Stream defaultProtocol
  setSocketOption peerSocket KeepAlive 1
  connect peerSocket (addrAddress addrInfo)
  let context = ConnectionContext
        { peer' = Peer peerSocket (getAddr $ addrAddress addrInfo)
        , version' = 60002
        , lastBlock' = 100
        , myAddr' = Addr (0, 0, 0, 0) 18333 -- Addr (207, 251, 103, 46 ) 18333
        , relay' = False
        , network' = TestNet3
        }
  return ()
  runConnection versionHandshake context
  inputConnection peerSocket


inputConnection :: Socket -> IO ()
inputConnection socket = runConduit
  $  sourceSocket socket
  .| conduitGet parseMessage
  .| mapC show
  .| stdout




versionHandshake :: Connection ()
versionHandshake  = do
  connectionContext <- get
  let (ConnectionContext
       { version' = version'
       , lastBlock' = lastBlock'
       , relay' = relay'
       , myAddr' = myAddr'
       , peer' = Peer peerSocket peerAddr'
       , network' = network'}) = connectionContext
  liftIO $ do
    nonce' <- randomRIO (0, 0xffffffffffffffff )
    time <- getPOSIXTime
    let versionMessage =
          showMessage $ Message
          (VersionMessage version' nonce' lastBlock' peerAddr' myAddr' relay')
          (MessageContext network' time)
    putStrLn $ "Sending message " ++ Char8.unpack versionMessage
    send peerSocket $ fst . decode $ versionMessage
    return ()
