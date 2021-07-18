{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TypeFamilies #-}

module Chainweb.Lookups
  ( -- * Endpoints
    headersBetween
  , payloadWithOutputs
  , payloadWithOutputsBatch
  , getNodeInfo
  , queryCut
  , cutMaxHeight
    -- * Transformations
  , mkBlockTransactions
  , mkBlockEvents
  , mkBlockEvents'
  , mkCoinbaseEvents
  , bpwoMinerKeys
  ) where

import           BasePrelude
import           Chainweb.Api.BlockHeader
import           Chainweb.Api.BlockPayloadWithOutputs
import           Chainweb.Api.ChainId (ChainId(..))
import           Chainweb.Api.ChainwebMeta
import           Chainweb.Api.Hash
import           Chainweb.Api.MinerData
import           Chainweb.Api.NodeInfo
import           Chainweb.Api.PactCommand
import           Chainweb.Api.Payload
import qualified Chainweb.Api.Transaction as CW
import           Chainweb.Env
import           ChainwebData.Types (Low(..), High(..))
import           ChainwebDb.Types.Block
import           ChainwebDb.Types.DbHash
import           ChainwebDb.Types.Transaction
import           ChainwebDb.Types.Event
import           Control.Error.Util (hush)
import           Data.Aeson
import           Data.ByteString.Lazy (ByteString,toStrict)
import qualified Data.ByteString.Lazy as B
import qualified Data.ByteString.Base64.URL as B64
import qualified Data.HashMap.Strict as HM
import           Data.Serialize.Get (runGet)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as T
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Data.Tuple.Strict (T2(..))
import qualified Data.Vector as V
import           Database.Beam hiding (insert)
import           Database.Beam.Postgres
import           Control.Lens
import           Data.Aeson.Lens
import           Network.HTTP.Client hiding (Proxy)
import           Network.HTTP.Client (Manager)

--------------------------------------------------------------------------------
-- Endpoints

headersBetween :: Env -> (ChainId, Low, High) -> IO [BlockHeader]
headersBetween env (cid, Low low, High up) = do
  req <- parseRequest url
  res <- httpLbs (req { requestHeaders = requestHeaders req <> encoding })
                 (_env_httpManager env)
  pure . (^.. key "items" . values . _String . to f . _Just) $ responseBody res
  where
    v = _nodeInfo_chainwebVer $ _env_nodeInfo env
    url = showUrlScheme (UrlScheme Https $ _env_p2pUrl env) <> query
    query = printf "/chainweb/0.0/%s/chain/%d/header?minheight=%d&maxheight=%d"
      (T.unpack v) (unChainId cid) low up
    encoding = [("accept", "application/json")]

    f :: T.Text -> Maybe BlockHeader
    f = hush . (B64.decode . T.encodeUtf8 >=> runGet decodeBlockHeader)

payloadWithOutputsBatch :: Env -> ChainId -> [DbHash PayloadHash] -> IO (Maybe [BlockPayloadWithOutputs])
payloadWithOutputsBatch env (ChainId cid) hshes' = do
    initReq <- parseRequest url
    let req = initReq { method = "POST" , requestBody = RequestBodyLBS $ encode requestObject, requestHeaders = encoding}
    res <- httpLbs req (_env_httpManager env)
    let body = responseBody res
    case eitherDecode' body of
      Left e -> do
        putStrLn "Decoding error in payloadWithOutputs (batch mode):"
        putStrLn e
        T.putStrLn $ T.decodeUtf8 $ B.toStrict body
        pure Nothing
      Right as -> pure $ Just as
  where
    hshes = String . unDbHash <$> hshes'
    url = showUrlScheme (UrlScheme Https $ _env_p2pUrl env) <> T.unpack query
    v = _nodeInfo_chainwebVer $ _env_nodeInfo env
    query = "/chainweb/0.0/" <> v <> "/chain/" <>   T.pack (show cid) <> "/payload/outputs/batch"
    encoding = [("content-type", "application/json")]
    requestObject = Array $ V.fromList hshes


payloadWithOutputs :: Env -> T2 ChainId (DbHash PayloadHash) -> IO (Maybe BlockPayloadWithOutputs)
payloadWithOutputs env (T2 cid0 hsh0) = do
  req <- parseRequest url
  res <- httpLbs req (_env_httpManager env)
  let body = responseBody res
  case eitherDecode' body of
    Left e -> do
      putStrLn "Decoding error in payloadWithOutputs:"
      putStrLn e
      putStrLn "Received response:"
      T.putStrLn $ T.decodeUtf8 $ B.toStrict body
      pure Nothing
    Right a -> pure $ Just a
  where
    v = _nodeInfo_chainwebVer $ _env_nodeInfo env
    url = showUrlScheme (UrlScheme Https $ _env_p2pUrl env) <> T.unpack query
    query = "/chainweb/0.0/" <> v <> "/chain/" <> cid <> "/payload/" <> hsh <> "/outputs"
    cid = T.pack $ show cid0
    hsh = unDbHash hsh0

-- | Query a node for the `ChainId` values its current `ChainwebVersion` has
-- available.
getNodeInfo :: Manager -> UrlScheme -> IO (Either String NodeInfo)
getNodeInfo m us = do
  req <- parseRequest $ showUrlScheme us <> "/info"
  res <- httpLbs req m
  pure $ eitherDecode' (responseBody res)

queryCut :: Env -> IO ByteString
queryCut e = do
  let v = _nodeInfo_chainwebVer $ _env_nodeInfo e
      m = _env_httpManager e
      u = _env_p2pUrl e
      url = printf "%s/chainweb/0.0/%s/cut" (showUrlScheme $ UrlScheme Https u) (T.unpack v)
  req <- parseRequest url
  res <- httpLbs req m
  pure $ responseBody res

cutMaxHeight :: ByteString -> Integer
cutMaxHeight bs = maximum $ (0:) $ bs ^.. key "hashes" . members . key "height" . _Integer


--------------------------------------------------------------------------------
-- Transformations

-- | Derive useful database entries from a `Block` and its payload.
mkBlockTransactions :: Block -> BlockPayloadWithOutputs -> [Transaction]
mkBlockTransactions b pl = map (mkTransaction b) $ _blockPayloadWithOutputs_transactionsWithOutputs pl

{- ¡ARRIBA!-}
-- The blockhash is the hash of the current block. A Coinbase transaction's
-- request key is expected to the parent hash of the block it is found in.
-- However, the source key of the event in chainweb-data database instance is
-- the current block hash and NOT the parent hash However, the source key of the
-- event in chainweb-data database instance is the current block hash and NOT
-- the parent hash.
mkBlockEvents' :: Int64 -> ChainId -> DbHash BlockHash -> BlockPayloadWithOutputs -> ([Event], [Event])
mkBlockEvents' height cid blockhash pl = _blockPayloadWithOutputs_transactionsWithOutputs pl
    & concatMap (mkTxEvents height cid)
    & ((,) (mkCoinbaseEvents height cid blockhash pl))

mkBlockEvents :: Int64 -> ChainId -> DbHash BlockHash -> BlockPayloadWithOutputs -> [Event]
mkBlockEvents height cid blockhash pl = uncurry (++) (mkBlockEvents' height cid blockhash pl)

mkCoinbaseEvents :: Int64 -> ChainId -> DbHash BlockHash -> BlockPayloadWithOutputs -> [Event]
mkCoinbaseEvents height cid blockhash pl = _blockPayloadWithOutputs_coinbase pl
    & coerce
    & _toutEvents
    {- idx of coinbase transactions is set to 0.... this value is just a placeholder-}
    <&> \ev -> mkEvent cid height (Right blockhash) ev 0

bpwoMinerKeys :: BlockPayloadWithOutputs -> [T.Text]
bpwoMinerKeys = _minerData_publicKeys . _blockPayloadWithOutputs_minerData

mkTransaction :: Block -> (CW.Transaction, TransactionOutput) -> Transaction
mkTransaction b (tx,txo) = Transaction
  { _tx_chainId = _block_chainId b
  , _tx_block = pk b
  , _tx_creationTime = posixSecondsToUTCTime $ _chainwebMeta_creationTime mta
  , _tx_ttl = fromIntegral $ _chainwebMeta_ttl mta
  , _tx_gasLimit = fromIntegral $ _chainwebMeta_gasLimit mta
  , _tx_gasPrice = _chainwebMeta_gasPrice mta
  , _tx_sender = _chainwebMeta_sender mta
  , _tx_nonce = _pactCommand_nonce cmd
  , _tx_requestKey = hashB64U $ CW._transaction_hash tx
  , _tx_code = _exec_code <$> exc
  , _tx_pactId = _cont_pactId <$> cnt
  , _tx_rollback = _cont_rollback <$> cnt
  , _tx_step = fromIntegral . _cont_step <$> cnt
  , _tx_data = (PgJSONB . _cont_data <$> cnt)
    <|> (PgJSONB <$> (exc >>= _exec_data))
  , _tx_proof = join (_cont_proof <$> cnt)

  , _tx_gas = fromIntegral $ _toutGas txo
  , _tx_badResult = badres
  , _tx_goodResult = goodres
  , _tx_logs = hashB64U <$> _toutLogs txo
  , _tx_metadata = PgJSONB <$> _toutMetaData txo
  , _tx_continuation = PgJSONB <$> _toutContinuation txo
  , _tx_txid = fromIntegral <$> _toutTxId txo
  , _tx_numEvents = Just $ fromIntegral $ length $ _toutEvents txo
  }
  where
    cmd = CW._transaction_cmd tx
    mta = _pactCommand_meta cmd
    pay = _pactCommand_payload cmd
    exc = case pay of
      ExecPayload e -> Just e
      ContPayload _ -> Nothing
    cnt = case pay of
      ExecPayload _ -> Nothing
      ContPayload c -> Just c
    (badres, goodres) = case _toutResult txo of
      PactResult (Left v) -> (Just $ PgJSONB v, Nothing)
      PactResult (Right v) -> (Nothing, Just $ PgJSONB v)

mkTxEvents :: Int64 -> ChainId -> (CW.Transaction,TransactionOutput) -> [Event]
mkTxEvents height cid (tx,txo) = zipWith (mkEvent cid height (Left k)) (_toutEvents txo) [0..]
  where
    k = DbHash $ hashB64U $ CW._transaction_hash tx

mkEvent :: ChainId -> Int64 -> Either (DbHash PayloadHash) (DbHash BlockHash) -> Value -> Int64 -> Event
mkEvent (ChainId chainid) height requestkeyOrBlock ev idx = Event
    { _ev_requestkey = requestkey
    , _ev_block = block
    , _ev_chainid = fromIntegral chainid
    , _ev_height = height
    , _ev_idx = idx
    , _ev_name = ename ev
    , _ev_qualName = qname ev
    , _ev_module = emodule ev
    , _ev_moduleHash = emoduleHash ev
    , _ev_paramText = T.decodeUtf8 $ toStrict $ encode $ params ev
    , _ev_params = PgJSONB $ toList $ params ev
    }
  where
    requestkey = either Just (const Nothing) requestkeyOrBlock
    block = either (const Nothing) Just requestkeyOrBlock
    ename = fromMaybe "" . str "name"
    emodule = fromMaybe "" . join . fmap qualm . lkp "module"
    qname ev' = case join $ fmap qualm $ lkp "module" ev' of
      Nothing -> ename ev'
      Just m -> m <> "." <> ename ev'
    qualm v = case str "namespace" v of
      Nothing -> mn
      Just n -> ((n <> ".") <>) <$> mn
      where mn = str "name" v
    emoduleHash = fromMaybe "" . str "moduleHash"
    params = fromMaybe mempty . fmap ar . lkp "params"
    ar v = case v of
      Array l -> l
      _ -> mempty
    lkp n v = case v of
      Object o -> HM.lookup n o
      _ -> Nothing
    str n v = case lkp n v of
      Just (String s) -> Just s
      _ -> Nothing
