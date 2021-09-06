{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Plutus.Contracts.LendingPool.OffChain.State where

import           Control.Lens
import           Control.Monad                             hiding (fmap)
import qualified Data.ByteString                           as BS
import qualified Data.Map                                  as Map
import           Data.Monoid                               (Last (..))
import           Data.Proxy                                (Proxy (..))
import           Data.Text                                 (Text, pack)
import qualified Data.Text                                 as Text
import           Data.Void                                 (Void)
import           Ledger                                    hiding (singleton)
import           Ledger.Constraints                        as Constraints
import           Ledger.Constraints.OnChain                as Constraints
import           Ledger.Constraints.TxConstraints          as Constraints
import qualified Ledger.Scripts                            as Scripts
import qualified Ledger.Typed.Scripts                      as Scripts
import           Playground.Contract
import           Plutus.Abstract.IncentivizedAmount        (accrue)
import           Plutus.Abstract.OutputValue               (OutputValue (..),
                                                            _ovValue,
                                                            getOutputValue)
import qualified Plutus.Abstract.State                     as State
import           Plutus.Abstract.State.Update              (PutStateHandle (..),
                                                            StateHandle (..))
import qualified Plutus.Abstract.TxUtils                   as TxUtils
import           Plutus.Contract                           hiding (when)
import           Plutus.Contracts.Currency                 as Currency
import           Plutus.Contracts.LendingPool.OnChain.Core (Aave (..),
                                                            AaveDatum (..),
                                                            AaveNewState (..),
                                                            AaveRedeemer (..),
                                                            AaveScript,
                                                            Reserve (..),
                                                            UserConfig (..),
                                                            UserConfigId,
                                                            aaveStateToken)
import qualified Plutus.Contracts.LendingPool.OnChain.Core as Core
import qualified Plutus.Contracts.Service.FungibleToken    as FungibleToken
import           Plutus.V1.Ledger.Ada                      (adaValueOf,
                                                            lovelaceValueOf)
import           Plutus.V1.Ledger.Value                    as Value
import qualified PlutusTx
import qualified PlutusTx.AssocMap                         as AssocMap
import           PlutusTx.Prelude                          hiding (Functor (..),
                                                            Semigroup (..),
                                                            unless)
import           Prelude                                   (Semigroup (..),
                                                            fmap)
import qualified Prelude

findOutputsBy :: Aave -> AssetClass -> (AaveDatum -> Maybe a) -> Contract w s Text [OutputValue a]
findOutputsBy aave = State.findOutputsBy (Core.aaveAddress aave)

findOutputBy :: Aave -> AssetClass -> (AaveDatum -> Maybe a) -> Contract w s Text (OutputValue a)
findOutputBy aave = State.findOutputBy (Core.aaveAddress aave)

findAaveOwnerToken :: Aave -> Contract w s Text (OutputValue PubKeyHash)
findAaveOwnerToken aave@Aave{..} = findOutputBy aave aaveProtocolInst (^? Core._LendingPoolDatum)

findAaveReserves :: Aave -> Contract w s Text (OutputValue (AssocMap.Map AssetClass Reserve))
findAaveReserves aave = findOutputBy aave (aaveStateToken aave) (fmap Core.ansReserves . (^? Core._StateDatum . _2))

getAaveCollateralValue :: Aave -> Contract w s Text Value
getAaveCollateralValue aave = foldMap getValue <$> State.getOutputsAt (Core.aaveAddress aave)
    where
        getValue out@OutputValue {..} = case ovValue of
            Core.ReserveFundsDatum -> getOutputValue out
            _                      -> mempty

findAaveReserve :: Aave -> AssetClass -> Contract w s Text Reserve
findAaveReserve aave reserveId = do
    reserves <- ovValue <$> findAaveReserves aave
    maybe (throwError "Reserve not found") pure $ AssocMap.lookup reserveId reserves

findAaveUserConfigs :: Aave -> Contract w s Text (OutputValue (AssocMap.Map UserConfigId UserConfig))
findAaveUserConfigs aave = findOutputBy aave (aaveStateToken aave) (fmap Core.ansUserConfigs . (^? Core._StateDatum . _2))

findAaveUserConfig :: Aave -> UserConfigId -> Contract w s Text UserConfig
findAaveUserConfig aave userConfigId = do
    configs <- ovValue <$> findAaveUserConfigs aave
    maybe (throwError "UserConfig not found") pure $ AssocMap.lookup userConfigId configs

putState :: Aave -> StateHandle AaveScript a -> a -> Contract w s Text (TxUtils.TxPair AaveScript)
putState aave stateHandle newState = do
    ownerTokenOutput <- fmap Core.LendingPoolDatum <$> findAaveOwnerToken aave
    State.putState
        PutStateHandle { script = Core.aaveInstance aave, ownerToken = aaveProtocolInst aave, ownerTokenOutput = ownerTokenOutput }
        stateHandle
        newState

updateState :: Aave ->  StateHandle AaveScript a -> OutputValue a -> Contract w s Text (TxUtils.TxPair AaveScript, a)
updateState aave = State.updateState (Core.aaveInstance aave)

findAaveState :: Aave -> Contract w s Text (OutputValue AaveNewState)
findAaveState aave = findOutputBy aave (aaveStateToken aave) (^? Core._StateDatum . _2)

makeStateHandle :: Aave -> (AaveNewState -> AaveRedeemer) -> StateHandle AaveScript AaveNewState
makeStateHandle aave toRedeemer =
    StateHandle {
        stateToken = aaveStateToken aave,
        toDatum = Core.StateDatum (aaveStateToken aave),
        toRedeemer = toRedeemer
    }

putAaveState :: Aave -> AaveRedeemer -> AaveNewState -> Contract w s Text (TxUtils.TxPair AaveScript)
putAaveState aave redeemer = putState aave $ makeStateHandle aave (const redeemer)

updateAaveState :: Aave -> AaveRedeemer -> OutputValue AaveNewState -> Contract w s Text (TxUtils.TxPair AaveScript, AaveNewState)
updateAaveState aave redeemer = updateState aave $ makeStateHandle aave (const redeemer)

addUserConfig :: UserConfigId -> UserConfig -> AaveNewState -> Contract w s Text AaveNewState
addUserConfig userConfigId userConfig state@AaveNewState{..} = do
    _ <- maybe (pure ()) (const $ throwError "Add user config failed: config exists") $
        AssocMap.lookup userConfigId ansUserConfigs
    pure $ state { ansUserConfigs = AssocMap.insert userConfigId userConfig ansUserConfigs }

updateUserConfig :: UserConfigId -> UserConfig -> AaveNewState -> Contract w s Text AaveNewState
updateUserConfig userConfigId userConfig state@AaveNewState{..} = do
    _ <- maybe (throwError "Update failed: user config not found") pure $
        AssocMap.lookup userConfigId ansUserConfigs
    pure $ state { ansUserConfigs = AssocMap.insert userConfigId userConfig ansUserConfigs }

updateReserveNew :: AssetClass -> Reserve -> AaveNewState -> Contract w s Text AaveNewState
updateReserveNew reserveId reserve state@AaveNewState{..} = do
    _ <- maybe (throwError "Update failed: reserve not found") pure $
        AssocMap.lookup reserveId ansReserves
    pure $ state { ansReserves = AssocMap.insert reserveId reserve ansReserves }

modifyAaveState :: Aave -> AaveRedeemer -> (AaveNewState -> Contract w s Text AaveNewState) -> Contract w s Text (TxUtils.TxPair AaveScript, AaveNewState)
modifyAaveState aave redeemer f = do
    stateOutput <- findAaveState aave
    newState <- f (ovValue stateOutput)
    updateAaveState aave redeemer (fmap (const newState) stateOutput)