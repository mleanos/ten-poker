{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Socket.Clients where


import           Control.Concurrent hiding (each, yield)
import           Control.Concurrent.Async
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TChan
import           Control.Exception
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Reader
import Control.Lens hiding (each , fold)
import Control.Lens.At

import           Data.Either
import           Data.Foldable
import           Data.Map.Lazy                  ( Map )
import qualified Data.Map.Lazy                 as M
import           Data.Text                      ( Text )
import qualified Data.Text                     as T
import           Database.Persist.Postgresql    ( ConnectionString
                                                , entityVal
                                                )
import qualified Network.WebSockets            as WS
import           Prelude
import           Text.Pretty.Simple             ( pPrint )
import qualified Data.ByteString.Lazy          as BL

import qualified Data.Set                      as Set
import           Database
import           Schema
import           Socket.Types
import           Socket.Utils
import           Types
import           Servant.Auth.Server
import qualified Data.ByteString               as BS

import           Crypto.JOSE                   as Jose

import           Data.Maybe
import           System.Timeout
import           Crypto.JWT
import           Poker.Game.Privacy             ( excludeAllPlayerCards
                                                , excludeOtherPlayerCards
                                                )
import qualified Data.ByteString.Lazy.Char8    as C
import           Socket.Auth
import           Pipes.Aeson
import           Pipes
import           Pipes.Core                     ( push )
import           Pipes.Concurrent
import           Pipes.Concurrent
import Prelude
import Poker.Game.Privacy

authClient
  :: BS.ByteString
  -> TVar ServerState
  -> ConnectionString
  -> RedisConfig
  -> WS.Connection
  -> Token
  -> IO (Either Err Username)
authClient secretKey state dbConn redisConfig conn (Token token) = do
  authResult <- runExceptT $ liftIO $ verifyJWT secretKey
                                                (C.pack $ T.unpack token)
  case authResult of
    Left  err               -> return $ Left $ AuthFailed err
    Right (Left  err      ) -> return $ Left $ AuthFailed $ T.pack $ show err
    Right (Right claimsSet) -> case decodeJWT claimsSet of
      Left jwtErr -> return $ Left $ AuthFailed $ T.pack $ show jwtErr
      Right username@(Username name) -> return $ pure $ Username name

removeClient :: Username -> TVar ServerState -> IO ServerState
removeClient username serverStateTVar = do
  ServerState {..} <- readTVarIO serverStateTVar
  let newClients = M.delete username clients
  let newState   = ServerState { clients = newClients, .. }
  atomically $ swapTVar serverStateTVar newState

clientExists :: Username -> Map Username Client -> Bool
clientExists = M.member


insertClient :: Client -> Username -> Map Username Client -> Map Username Client
insertClient client username = M.insert username client

addClient :: TVar ServerState -> Client -> STM ServerState
addClient s c@Client {..} = do
  ServerState {..} <- readTVar s
  swapTVar
    s
    (ServerState
      { clients = insertClient c (Username clientUsername) clients
      , ..
      }
    )

--handleNewConnection :: Map Username Clients -> Username -> Socket
--handleNewConnection cs username conn = 
--  case getClient cs username of 
--      Just Client -> 


getClient :: Map Username Client -> Username -> Maybe Client
getClient cs username = cs ^.at username 

broadcastAllClients :: Map Username Client -> MsgOut -> IO ()
broadcastAllClients clients msg =
  forM_ (M.elems clients) (\Client {..} -> sendMsg conn msg)

broadcastTableSubscribers :: Table -> Map Username Client -> MsgOut -> IO ()
broadcastTableSubscribers Table {..} clients msg = forM_
  subscriberConns
  (\Client {..} -> sendMsg conn msg)
  where subscriberConns = clients `M.restrictKeys` Set.fromList subscribers

sendMsgs :: [WS.Connection] -> MsgOut -> IO ()
sendMsgs conns msg = forM_ conns $ \conn -> sendMsg conn msg

sendMsg :: WS.Connection -> MsgOut -> IO ()
sendMsg conn msg = WS.sendTextData conn (encodeMsgToJSON msg)

sendMsgX :: WS.Connection -> MsgIn -> IO ()
sendMsgX conn msg = WS.sendTextData conn (encodeMsgX msg)

getClientConn :: Client -> WS.Connection
getClientConn Client {..} = conn

broadcastMsg :: Map Username Client -> [Username] -> MsgOut -> IO ()
broadcastMsg clients usernames msg = forM_
  conns
  (\Client {..} -> sendMsg conn $ filterPrivateGameData clientUsername msg)
  where conns = clients `M.restrictKeys` Set.fromList usernames

-- Filter out private data such as other players cards which is not
-- intended for the client.
filterPrivateGameData :: Text -> MsgOut -> MsgOut
filterPrivateGameData username (SuccessfullySatDown tableName game) =
  SuccessfullySatDown tableName (excludeOtherPlayerCards username game)
filterPrivateGameData username (SuccessfullySubscribedToTable tableName game) =
  SuccessfullySubscribedToTable tableName
                                (excludePrivateCards (Just username) game)
filterPrivateGameData username (NewGameState tableName game) =
  NewGameState tableName (excludeOtherPlayerCards username game)
filterPrivateGameData _ unfilteredMsg = unfilteredMsg

getTablesUserSubscribedTo :: Client -> Lobby -> [(TableName, Table)]
getTablesUserSubscribedTo Client{..} (Lobby lobby) = 
  filter (subscriberIncludesClient . snd) (M.toList lobby) 
    where
      subscriberIncludesClient Table{..} = 
        elem (Username clientUsername) subscribers 

tablesToMsgs :: Text -> [(TableName, Table)] -> [MsgOut]
tablesToMsgs clientUsername' =  (<$>) toFilteredMsg
  where 
    gameToMsg (tableName, Table{..}) = NewGameState tableName game
    toFilteredMsg = ((filterPrivateGameData clientUsername') . gameToMsg)

getSubscribedGameStates :: Client -> Lobby -> [MsgOut]
getSubscribedGameStates c@Client{..} l = (tablesToMsgs clientUsername $ getTablesUserSubscribedTo c l)



---- used so that reconnected users can get up to speed on games when they regain connection
---- after a disconnect.
updateWithLatestGames client@Client{..} lobby = do
  async
    $ runEffect
    $ for (each latestGameStates) (\msg -> yield msg >-> toOutput outgoingMailbox)
  return ()
  where latestGameStates = getSubscribedGameStates client lobby
