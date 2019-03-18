{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TupleSections       #-}

{-# OPTIONS_GHC -Wno-orphans     #-}
module Test.Socket (tests) where

import           Control.Monad
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadSTM
import           Control.Monad.Class.MonadThrow
import           Control.Monad.Class.MonadTimer
import           Control.Exception (IOException)
import qualified Data.ByteString.Lazy as BL
import           Data.List (mapAccumL)
import           Network.Socket hiding (recv, recvFrom, send, sendTo)
import qualified Network.Socket.ByteString.Lazy as Socket (sendAll)

import           Network.TypedProtocol.Core
import qualified Network.TypedProtocol.ReqResp.Type       as ReqResp
import qualified Network.TypedProtocol.ReqResp.Client     as ReqResp
import qualified Network.TypedProtocol.ReqResp.Server     as ReqResp
import qualified Ouroboros.Network.Protocol.ReqResp.Codec as ReqResp

import           Control.Tracer (nullTracer)

import qualified Ouroboros.Network.Mux as Mx
import           Ouroboros.Network.Mux.Interface
import           Ouroboros.Network.Socket

import           Ouroboros.Network.Chain (Chain, ChainUpdate, Point)
import qualified Ouroboros.Network.Chain as Chain
import qualified Ouroboros.Network.ChainProducerState as CPS
import qualified Ouroboros.Network.Protocol.ChainSync.Type     as ChainSync
import qualified Ouroboros.Network.Protocol.ChainSync.Client   as ChainSync
import qualified Ouroboros.Network.Protocol.ChainSync.Codec    as ChainSync
import qualified Ouroboros.Network.Protocol.ChainSync.Examples as ChainSync
import qualified Ouroboros.Network.Protocol.ChainSync.Server   as ChainSync
import           Ouroboros.Network.Testing.Serialise

import           Test.ChainGenerators (TestBlockChainAndUpdates (..))
import qualified Test.Mux as Mxt
import           Test.Mux.ReqResp

import           Test.QuickCheck
import           Text.Show.Functions ()
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.QuickCheck (testProperty)

{-
 - The travis build hosts does not support IPv6 so those test cases are hidden
 - behind the OUROBOROS_NETWORK_IPV6 define for now.
 -}
-- #define OUROBOROS_NETWORK_IPV6

--
-- The list of all tests
--

tests :: TestTree
tests =
  testGroup "Socket"
  [ testProperty "socket send receive IPv4"          prop_socket_send_recv_ipv4
#ifdef OUROBOROS_NETWORK_IPV6
  , testProperty "socket send receive IPv6"          prop_socket_send_recv_ipv6
#endif
  , testProperty "socket close during receive"       prop_socket_recv_close
  , testProperty "socket client connection failure"  prop_socket_client_connect_error
  , testProperty "socket sync demo"                  prop_socket_demo
  ]

--
-- Properties
--

-- | Test chainsync over a socket bearer
prop_socket_demo :: TestBlockChainAndUpdates -> Property
prop_socket_demo (TestBlockChainAndUpdates chain updates) =
    ioProperty $ demo chain updates

-- | Send and receive over IPv4
prop_socket_send_recv_ipv4
  :: (Int -> Int -> (Int, Int))
  -> [Int]
  -> Property
prop_socket_send_recv_ipv4 f xs = ioProperty $ do
    client:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
    server:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "6061")
    prop_socket_send_recv client server f xs


#ifdef OUROBOROS_NETWORK_IPV6

-- | Send and receive over IPv6
prop_socket_send_recv_ipv6 :: (Int ->  Int -> (Int, Int))
                           -> [Int]
                           -> Property
prop_socket_send_recv_ipv6 request response = ioProperty $ do
    client:_ <- getAddrInfo Nothing (Just "::1") (Just "0")
    server:_ <- getAddrInfo Nothing (Just "::1") (Just "6061")
    prop_socket_send_recv client server request response
#endif

-- | Verify that an initiator and a responder can send and receive messages from each other
-- over a TCP socket. Large DummyPayloads will be split into smaller segments and the
-- testcases will verify that they are correctly reassembled into the original message.
prop_socket_send_recv :: AddrInfo
                      -> AddrInfo
                      -> (Int -> Int -> (Int, Int))
                      -> [Int]
                      -> IO Bool
prop_socket_send_recv clientAddr serverAddr f xs = do

    cv <- newEmptyTMVarM
    sv <- newEmptyTMVarM

    let -- Server Node; only req-resp server
        srvPeer :: Peer (ReqResp.ReqResp Int Int) AsServer ReqResp.StIdle IO ()
        srvPeer = ReqResp.reqRespServerPeer (reqRespServerMapAccumL sv (\a -> pure . f a) 0)
        srvPeers Mxt.ReqResp1 = OnlyServer nullTracer ReqResp.codecReqResp srvPeer
        serNet = NetworkInterface {
            nodeAddress = serverAddr,
            protocols   = srvPeers
          }

        -- Client Node; only req-resp client
        cliPeer :: Peer (ReqResp.ReqResp Int Int) AsClient ReqResp.StIdle IO ()
        cliPeer = ReqResp.reqRespClientPeer (reqRespClientMap cv xs)
        cliPeers Mxt.ReqResp1 = OnlyClient nullTracer ReqResp.codecReqResp cliPeer
        cliNet = NetworkInterface {
             nodeAddress = clientAddr,
             protocols   = cliPeers
           }

    serNode <- runNetworkNodeWithSocket serNet
    cliNode <- runNetworkNodeWithSocket cliNet

    res <- withConnection cliNode serverAddr $ \_ ->
      atomically $ (,) <$> takeTMVar sv <*> takeTMVar cv

    killNode cliNode
    killNode serNode

    return (res == mapAccumL f 0 xs)


-- |
-- Verify that we raise the correct exception in case a socket closes during
-- a read.
-- 
-- Note: the socket is closed during version negotation.
prop_socket_recv_close :: (Int -> Int -> (Int, Int))
                       -> [Int]
                       -> Property
prop_socket_recv_close f _ = ioProperty $ do
    b:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "6061")

    sv   <- newEmptyTMVarM
    resq <- atomically $ newTBQueue 1

    let srvPeer :: Peer (ReqResp.ReqResp Int Int) AsServer ReqResp.StIdle IO ()
        srvPeer = ReqResp.reqRespServerPeer (reqRespServerMapAccumL sv (\a -> pure . f a) 0)
        srvPeers Mxt.ReqResp1 = OnlyServer nullTracer ReqResp.codecReqResp srvPeer
        ni = NetworkInterface {
            nodeAddress = b,
            protocols   = srvPeers
          }
            
    nn <- runNetworkNodeWithSocket' ni (Just (rescb resq))

    sd <- socket (addrFamily b) Stream defaultProtocol
    connect sd (addrAddress b)

    Socket.sendAll sd $ BL.singleton 0xa
    close sd

    res <- atomically $ readTBQueue resq

    killNode nn
    case res of
         Just e  ->
             case fromException e of
                  Just me -> return $ Mx.errorType me == Mx.MuxBearerClosed
                  Nothing -> return False
         Nothing -> return False

  where
    rescb resq e_m = atomically $ writeTBQueue resq e_m


prop_socket_client_connect_error :: (Int -> Int -> (Int, Int))
                                 -> [Int]
                                 -> Property
prop_socket_client_connect_error _ xs = ioProperty $ do
    clientAddr:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
    serverAddr:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "6061")

    cv <- newEmptyTMVarM

    let cliPeer :: Peer (ReqResp.ReqResp Int Int) AsClient ReqResp.StIdle IO ()
        cliPeer = ReqResp.reqRespClientPeer (reqRespClientMap cv xs)
        cliPeers Mxt.ReqResp1 = OnlyClient nullTracer ReqResp.codecReqResp cliPeer
        ni = NetworkInterface {
            nodeAddress = serverAddr,
            protocols   = cliPeers
          }

    nn <- runNetworkNodeWithSocket ni
    mconn <- try @IO @IOException $ connectTo nn clientAddr
    r <- case mconn of
      -- XXX Disregarding the exact exception type
      Left _     -> return $ property True
      Right conn -> terminate conn >> return (property False)
    killNode nn

    return r

demo :: forall block .
        (Chain.HasHeader block, Serialise block, Eq block, Show block )
     => Chain block -> [ChainUpdate block] -> IO Bool
demo chain0 updates = do
    consumerAddress:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "0")
    producerAddress:_ <- getAddrInfo Nothing (Just "127.0.0.1") (Just "6061")

    producerVar <- newTVarM (CPS.initChainProducerState chain0)
    consumerVar <- newTVarM chain0
    done <- atomically newEmptyTMVar

    let Just expectedChain = Chain.applyChainUpdates updates chain0
        target = Chain.headPoint expectedChain
        consumerPeer :: Peer (ChainSync.ChainSync block (Point block)) AsClient ChainSync.StIdle IO ()
        consumerPeer = ChainSync.chainSyncClientPeer
                        (ChainSync.chainSyncClientExample consumerVar
                        (consumerClient done target consumerVar))
        consumerPeers Mxt.ChainSync1 = OnlyClient nullTracer ChainSync.codecChainSync consumerPeer
        consumerNet = NetworkInterface {
              nodeAddress = consumerAddress,
              protocols   = consumerPeers
            }

        producerPeer :: Peer (ChainSync.ChainSync block (Point block)) AsServer ChainSync.StIdle IO ()
        producerPeer = ChainSync.chainSyncServerPeer (ChainSync.chainSyncServerExample () producerVar)
        producerPeers Mxt.ChainSync1 = OnlyServer nullTracer ChainSync.codecChainSync producerPeer
        producerNet = NetworkInterface {
              nodeAddress = producerAddress,
              protocols   = producerPeers
            }

    producerNode <- runNetworkNodeWithSocket producerNet
    consumerNode <- runNetworkNodeWithSocket consumerNet

    r <- withConnection consumerNode (nodeAddress producerNet) $ \_ -> do

      void $ fork $ sequence_
          [ do threadDelay 10e-3 -- just to provide interest
               atomically $ do
                  p <- readTVar producerVar
                  let Just p' = CPS.applyChainUpdate update p
                  writeTVar producerVar p'
          | update <- updates
          ]

      atomically $ takeTMVar done

    killNode producerNode
    killNode consumerNode

    return r
  where
    checkTip target consumerVar = atomically $ do
      chain <- readTVar consumerVar
      return (Chain.headPoint chain == target)

    -- A simple chain-sync client which runs until it recieves an update to
    -- a given point (either as a roll forward or as a roll backward).
    consumerClient :: TMVar IO Bool
                   -> Point block
                   -> TVar IO (Chain block)
                   -> ChainSync.Client block IO ()
    consumerClient done target chain =
      ChainSync.Client
        { ChainSync.rollforward = \_ -> checkTip target chain >>= \b ->
            if b then do
                    atomically $ putTMVar done True
                    pure $ Left ()
                 else
                    pure $ Right $ consumerClient done target chain
        , ChainSync.rollbackward = \_ _ -> checkTip target chain >>= \b ->
            if b then do
                    atomically $ putTMVar done True
                    pure $ Left ()
                 else
                    pure $ Right $ consumerClient done target chain
        , ChainSync.points = \_ -> pure $ consumerClient done target chain
        }
