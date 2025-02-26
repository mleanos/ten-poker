{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards #-}
{- 
  Public API for Poker Game Logic
-}
module Poker.Poker
  ( initialGameState
  , initPlayer
  , progressGame
  , canProgressGame
  , runPlayerAction
  , handlePlayerTimeout
  , getAllValidPlayerActions
  )
where

import           Control.Lens            hiding ( Fold )
import           Control.Concurrent.STM.TVar

import           Data.Either
import           Data.Functor
import           Data.List
import           Data.Maybe
import           Data.Monoid
import           Data.Text                      ( Text )
import           System.Random

import           Text.Pretty.Simple             ( pPrint )

import           Poker.ActionValidation
import           Poker.Game.Actions
import           Poker.Game.Blinds
import           Poker.Game.Game
import           Poker.Game.Hands
import           Poker.Game.Utils
import           Poker.Types
import Debug.Trace

-- the function takes a player action and returns either a new game for a valid 
-- player action or an err signifying an invalid player action with the reason why
-- if the current game stage is showdown then the next game state will have a newly shuffled
-- deck and pocket cards/ bets reset
runPlayerAction :: Game -> PlayerAction -> Either GameErr Game
runPlayerAction game playerAction'@PlayerAction {..} =
  updatePlayersPossibleActions <$> handlePlayerAction game playerAction'

canProgressGame :: Game -> Bool
canProgressGame game@Game {..}
  | (length _players) < 2 = False -- -- | (null $ getActivePlayers _players) = False
  | _street == Showdown = True
  | _street == PreDeal && haveRequiredBlindsBeenPosted game = True
  | _street == PreDeal && haveAllPlayersActed game = True
  | otherwise           = haveAllPlayersActed game

    --  ((length $ getActivePlayers _players) < 2 && haveAllPlayersActed game) ||
--  (haveAllPlayersActed game && (length $ getActivePlayers _players) >= 2))

-- when no player action is possible we can can call this function to get the game 
-- to the next stage.
-- When the stage is showdown there are no possible player actions so this function is called
-- to progress the game to the next hand.
-- A similar situation occurs when no further player action is possible but  the game is not over
-- - in other words more than one players are active and all or all but one are all in

progressGame :: RandomGen g => g -> Game -> Game
progressGame gen = updatePlayersPossibleActions . nextStage gen

-- | Just get the identity function if not all players acted otherwise we return 
-- the function necessary to progress the game to the next stage.
-- toDO - make function pure by taking stdGen as an arg
nextStage :: RandomGen g => g -> Game -> Game
nextStage gen game@Game {..}
  | _street == Showdown = nextHand
  | notEnoughPlayersToStartGame = nextHand
  | haveAllPlayersActed game
    && (  not (allButOneFolded game)
       || (_street == PreDeal || _street == Showdown)
       ) = case getNextStreet _street of
      PreFlop  -> progressToPreFlop game
      Flop     -> progressToFlop game
      Turn     -> progressToTurn game
      River    -> progressToRiver game
      Showdown -> progressToShowdown game
      PreDeal  -> nextHand
  | allButOneFolded game && _street /= Showdown = progressToShowdown game
  | otherwise = game
 where
  nextHand = getNextHand game (shuffledDeck gen)
  numberPlayersSatIn = length $ getActivePlayers _players
  notEnoughPlayersToStartGame =
    _street == PreDeal && haveAllPlayersActed game && numberPlayersSatIn < 2


handlePlayerAction :: Game -> PlayerAction -> Either GameErr Game
handlePlayerAction game@Game {..} PlayerAction {..} = case action of
  PostBlind blind -> validateAction game name action $> postBlind blind name game
  Fold            -> validateAction game name action $> foldCards name game
  Call            -> validateAction game name action $> call name game
  Raise amount    -> validateAction game name action $> makeBet amount name game
  Check           -> validateAction game name action $> check name game
  Bet amount      -> validateAction game name action $> makeBet amount name game
  SitDown player  -> validateAction game name action $> seatPlayer player game
  SitIn           -> validateAction game name action $> sitIn name game
  LeaveSeat'      -> validateAction game name action $> leaveSeat name game
  Timeout         -> handlePlayerTimeout name game


-- TODO - "Except" or ExceptT Identity has a more reliable Alternative instance.
-- Use except and remove the guards and just use <|> to combine all the 
-- eithers and return the first right. I.e try each action in turn and return the first
-- valid action. 
handlePlayerTimeout :: PlayerName -> Game -> Either GameErr Game
handlePlayerTimeout name game@Game {..}
  | playerCanCheck && handStarted
  = validateAction game name Check $> check name game
  | not playerCanCheck && handStarted
  = validateAction game name Timeout $> foldCards name game
  | not handStarted
  = validateAction game name SitOut $> sitOut name game
 where
  handStarted    = _street /= PreDeal
  playerCanCheck = isRight $ canCheck name game


initialGameState :: Deck -> Game
initialGameState shuffledDeck = Game
   {  _players         = []
    , _waitlist        = []
    , _minBuyInChips   = 1500
    , _maxBuyInChips   = 3000
    , _maxPlayers      = 6
    , _dealer          = 0
    , _currentPosToAct = Nothing
    , _board           = []
    , _deck            = shuffledDeck
    , _smallBlind      = 25
    , _bigBlind        = 50
    , _pot             = 0
    , _street          = PreDeal
    , _maxBet          = 0
    , _winners         = NoWinners
  }

updatePlayersPossibleActions :: Game -> Game
updatePlayersPossibleActions g@Game {..} = Game { _players = updatedPlayers , ..}
  where
    updatedPlayers = (\Player{..} ->
      Player { _possibleActions = traceShow (replicate 8 $ getValidPlayerActions g _playerName) (getValidPlayerActions g _playerName) , ..}) <$> _players

getAllValidPlayerActions :: Game -> [[Action]] 
getAllValidPlayerActions g@Game{..} = 
  (getValidPlayerActions g) . _playerName <$> _players 

getValidPlayerActions :: Game -> PlayerName -> [Action]
getValidPlayerActions g@Game {..} name
  -- | not canPlayerAct = []  -- PAUSE THREEADALY INTERFERS WITH TIMEPLAYER - MOVE PROGRESS PAUSE TO CLIENT
  | length _players < 2 = []
  | _street == PreDeal = -- && (isNothing _currentPosToAct) = -- game not underway so any player an can post any blind to get a game started
   --  [PostBlind Small, PostBlind Big]
    case blindRequiredByPlayer g name of
          Small   -> [PostBlind Small]
          Big     -> [PostBlind Big]
          NoBlind -> []
--  | _street == PreDeal = 
--    let possibleActions = actions _street chipCount
--    in
--       filter (isRight . validateAction g name) possibleActions
  | otherwise = 
    let 
      minRaise = 2 * _maxBet
      possibleActions  = actions _street chipCount
    in
       traceShow  ((validateAction g name) <$> possibleActions) (filter (isRight . validateAction g name) possibleActions)
 where
  actions :: Street -> Int -> [Action]
  actions st chips | st == PreDeal = [PostBlind Big, PostBlind Small]
                   | otherwise     = [Check, Call, Fold, Bet chips, Raise chips]
  lowerBetBound = if _maxBet > 0 then 2 * _maxBet else _bigBlind
  chipCount     = maybe 0 (^. chips) (getGamePlayer g name)
  panic         = do
    print $ "UHOH no valid actions for " <> show name
    print g
    error $ "UHOH no valid actions"
                                       
                                       