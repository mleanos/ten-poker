{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Schema where

import           Control.Monad
import           Data.Aeson
import           Data.Aeson.Types
import           Data.Text                      ( Text )
import           Data.Time.Clock
import           Database.Persist.TH

import           Poker.Types

share
  [mkPersist sqlSettings, mkMigrate "migrateAll"]
  [persistLowerCase|
  UserEntity json sql=users
    username Text
    email Text
    password Text
    availableChips Int
    chipsInPlay Int
    createdAt UTCTime default=now()
    UniqueEmail email
    UniqueUsername username
    deriving Show Read
  TableEntity json sql=tables
    name Text
    UniqueName name
    deriving Show Read
  GameEntity json sql=games
    tableID TableEntityId
    createdAt UTCTime default=now()
    players [Player]
    minBuyInChips Int
    maxBuyInChips Int
    maxPlayers Int
    board [Card]
    winners Winners
    waitlist [PlayerName]
    deck [Card]
    smallBlind Int
    bigBlind Int
    street Street
    pot Int
    maxBet Bet
    dealer Int
    currentPosToAct Int Maybe
    deriving Show Read
|]
