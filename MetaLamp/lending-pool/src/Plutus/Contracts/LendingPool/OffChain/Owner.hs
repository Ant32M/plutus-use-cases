{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}

module Plutus.Contracts.LendingPool.OffChain.Owner where

import qualified Control.Lens                                as Lens
import           Control.Monad                               hiding (fmap)
import qualified Data.ByteString                             as BS
import qualified Data.Map                                    as Map
import           Data.Monoid                                 (Last (..))
import           Data.Proxy                                  (Proxy (..))
import           Data.Text                                   (Text, pack)
import qualified Data.Text                                   as Text
import           Data.Void                                   (Void)
import           Ledger                                      hiding (singleton)
import           Ledger.Constraints                          as Constraints
import           Ledger.Constraints.OnChain                  as Constraints
import           Ledger.Constraints.TxConstraints            as Constraints
import qualified Ledger.Scripts                              as Scripts
import qualified Ledger.Typed.Scripts                        as Scripts
import           Playground.Contract
import           Plutus.Abstract.ContractResponse            (ContractResponse,
                                                              withContractResponse)
import           Plutus.Abstract.OutputValue                 (OutputValue (..))
import qualified Plutus.Abstract.TxUtils                     as TxUtils
import           Plutus.Contract                             hiding (when)
import           Plutus.Contracts.Currency                   as Currency
import qualified Plutus.Contracts.LendingPool.OffChain.State as State
import qualified Plutus.Contracts.LendingPool.OnChain.AToken as AToken
import           Plutus.Contracts.LendingPool.OnChain.Core   (Aave,
                                                              AaveDatum (..),
                                                              AaveRedeemer (..),
                                                              Reserve (..),
                                                              UserConfig (..))
import qualified Plutus.Contracts.LendingPool.OnChain.Core   as Core
import qualified Plutus.Contracts.Service.FungibleToken      as FungibleToken
import qualified Plutus.Contracts.Service.Oracle             as Oracle
import           Plutus.V1.Ledger.Ada                        (adaValueOf,
                                                              lovelaceValueOf)
import qualified Plutus.V1.Ledger.Address                    as Addr
import           Plutus.V1.Ledger.Value                      as Value
import qualified PlutusTx
import qualified PlutusTx.AssocMap                           as AssocMap
import           PlutusTx.Prelude                            hiding
                                                             (Monoid (..),
                                                              Semigroup (..),
                                                              mconcat, unless)
import           Prelude                                     (Monoid (..),
                                                              Semigroup (..),
                                                              show, subtract)
import qualified Prelude
import           Text.Printf                                 (printf)

data CreateParams =
    CreateParams
        { cpAsset  :: AssetClass,
          cpOracle :: Oracle.Oracle
         }
    deriving stock (Prelude.Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON, ToSchema)

PlutusTx.makeLift ''CreateParams

createReserve :: Aave -> CreateParams -> Reserve
createReserve aave CreateParams {..} =
    Reserve
        { rCurrency = cpAsset,
          rAmount = 0,
          rAToken = AToken.makeAToken (Core.aaveHash aave) cpAsset,
          rLiquidityIndex = 1,
          rCurrentStableBorrowRate = 11 % 10, -- TODO configure borrow rate when lending core will be ready
          rTrustedOracle = Oracle.toTuple cpOracle
           }

-- | Starts the Lending Pool protocol: minting pool NFTs, creating empty user configuration state and all specified liquidity reserves
start :: [CreateParams] -> Contract w s Text Aave
start = start' $ do
    pkh <- pubKeyHash <$> ownPubKey
    fmap Currency.currencySymbol $
           mapError (pack . show @Currency.CurrencyError) $
           Currency.forgeContract pkh [(Core.aaveProtocolName, 1)]

start' :: Contract w s Text CurrencySymbol -> [CreateParams] -> Contract w s Text Aave
start' getAaveToken params = do
    aaveToken <- getAaveToken
    pkh <- pubKeyHash <$> ownPubKey
    let aave = Core.aave aaveToken
        payment = assetClassValue (Core.aaveProtocolInst aave) 1
    let aaveTokenTx = TxUtils.mustPayToScript (Core.aaveInstance aave) pkh (Core.LendingPoolDatum pkh) payment
    -- TODO how to ensure that newly minted owner token is paid to the script before someone else spends it?
    ledgerTx <- TxUtils.submitTxPair aaveTokenTx
    void $ awaitTxConfirmed $ txId ledgerTx

    let reserveMap = AssocMap.fromList $ fmap (\params -> (cpAsset params, createReserve aave params)) params
    reservesTx <- State.putReserves aave Core.StartRedeemer reserveMap
    ledgerTx <- TxUtils.submitTxPair reservesTx
    void $ awaitTxConfirmed $ txId ledgerTx
    userConfigsTx <- State.putUserConfigs aave Core.StartRedeemer AssocMap.empty
    ledgerTx <- TxUtils.submitTxPair userConfigsTx
    void $ awaitTxConfirmed $ txId ledgerTx

    logInfo @Prelude.String $ printf "started Aave %s at address %s" (show aave) (show $ Core.aaveAddress aave)
    pure aave

type AaveOwnerSchema =
    Endpoint "start" [CreateParams]

data OwnerContractState = Started Aave
    deriving (Prelude.Eq, Show, Generic, FromJSON, ToJSON)

ownerEndpoints :: Contract (ContractResponse Text OwnerContractState) AaveOwnerSchema Void ()
ownerEndpoints = forever $ withContractResponse (Proxy @"start") Started start