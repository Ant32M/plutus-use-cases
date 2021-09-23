{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeFamilies       #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE TemplateHaskell    #-}

module Types.Game
     where

import           Control.Lens    
import           Data.Map             (fromList, lookup)
import qualified Data.Map   as Map 
import           Data.Maybe           (fromMaybe)
import           Data.Aeson
import           Data.Aeson.TH        
import           Data.Text            (Text)
import           GHC.Generics         (Generic)

type GameId = Integer
type TeamId = Integer

skipUnderscore:: String -> String
skipUnderscore = drop 1

renameLabel:: String -> String -> String -> String
renameLabel toRenameLabel targetLabel value = if value == toRenameLabel then targetLabel else value

data Team = Team 
    { _teamId :: !TeamId
    , _name   :: !Text
    , _logo   :: !Text
    , _winner :: !Bool
    }  deriving (Show,Generic)
instance FromJSON Team where
    parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = renameLabel "teamId" "id" . skipUnderscore  }
instance ToJSON Team where
    toJSON = genericToJSON defaultOptions { fieldLabelModifier = renameLabel "teamId" "id" . skipUnderscore   }
makeLenses ''Team

data GameTeams = GameTeams 
    { _home :: !Team
    , _away :: !Team
    }  deriving (Show,Generic)
instance FromJSON GameTeams where
    parseJSON = genericParseJSON defaultOptions{fieldLabelModifier = skipUnderscore}
instance ToJSON GameTeams where 
   toJSON = genericToJSON defaultOptions{fieldLabelModifier = skipUnderscore}
makeLenses ''GameTeams

data FixtureStatusShort = NS | LIVE | FT 
    deriving (Generic, Show, Enum, Eq, Ord)
instance FromJSON FixtureStatusShort
instance ToJSON FixtureStatusShort 

fixureStatusLong :: Map.Map FixtureStatusShort Text
fixureStatusLong = fromList [(NS,"Not Started"), (LIVE,"In Progress"), (FT, "Match Finished")]

createFixtureStatus :: FixtureStatusShort -> FixtureStatus 
createFixtureStatus status = FixtureStatus
        {_short = status
        , _long = fromMaybe "" $ Map.lookup status fixureStatusLong
        } 
data FixtureStatus = FixtureStatus 
    { _long    :: !Text
    , _short   :: !FixtureStatusShort
    } deriving (Show,Generic)
instance FromJSON FixtureStatus where
    parseJSON = genericParseJSON defaultOptions{fieldLabelModifier = skipUnderscore}
instance ToJSON FixtureStatus where 
   toJSON = genericToJSON defaultOptions{fieldLabelModifier = skipUnderscore}
makeLenses ''FixtureStatus

data Fixture = Fixture
    { _fixtureId :: !GameId
    , _referee   :: !Text
    , _timezone  :: !Text
    , _date      :: !Text  
    , _status    :: !FixtureStatus
    } deriving (Show,Generic)
instance FromJSON Fixture where
    parseJSON = genericParseJSON defaultOptions { fieldLabelModifier = renameLabel "fixtureId" "id" . skipUnderscore }
instance ToJSON Fixture where
    toJSON = genericToJSON defaultOptions { fieldLabelModifier = renameLabel "fixtureId" "id" . skipUnderscore   }
makeLenses ''Fixture

data Game = Game  
    { _fixture :: !Fixture
    , _teams   :: !GameTeams
    } 
    deriving  (Show, Generic)
makeLenses ''Game
instance FromJSON Game where
    parseJSON = genericParseJSON defaultOptions{fieldLabelModifier = skipUnderscore}
instance ToJSON Game where 
   toJSON = genericToJSON defaultOptions{fieldLabelModifier = skipUnderscore}
instance Eq Game where
    a == b = (a ^. fixture . fixtureId == b ^. fixture . fixtureId)

getWinnerTeamId :: Either String Game -> Either String Integer
getWinnerTeamId gameE = case gameE of
    Right game | game ^. fixture . status . short /= FT -> Left "Game not finished"
    Right game | game ^. fixture . status . short == FT -> do
        let team1 = game ^. teams . home
        let team2 = game ^. teams . away
        if (team1 ^. winner) 
            then Right (team1 ^. teamId ) 
            else Right (team2 ^. teamId) 
    Left e -> Left e