{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores#-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
module Plutus.Contract.Blockchain.MarketPlace
--     Price(..),
--     valueOfPrice,
--     Market(..),
--     DirectSale(..),
--     SellType(..),
--     Auction(..),
--     MarketRedeemer(..),
--     marketValidator,
--     marketAddress,
--     -- TODO remove the exports below
--     MarketScriptType,
--     mkMarket
-- )
where

import GHC.Generics (Generic)
import qualified Prelude (Show, Eq)
import PlutusTx.Prelude
import  PlutusTx
import Ledger
    ( getContinuingOutputs,
      txSignedBy,
      valuePaidTo,
      ScriptContext(ScriptContext, scriptContextTxInfo),
      TxInfo(txInfoValidRange),
      TxOut(txOutValue),
      Value,
      POSIXTimeRange,
      PubKeyHash,
      CurrencySymbol,
      TokenName,
      scriptAddress,
      contains,
      mkValidatorScript,
      Address (addressCredential),
      Validator,
      AssetClass, TxInInfo, toValidatorHash, Interval (Interval, ivFrom, ivTo), Extended (PosInf), after )
import Ledger.Value hiding(lt)
import Ledger.Credential
import qualified Ledger.Typed.Scripts as Scripts
import Data.Aeson (FromJSON, ToJSON)
import Plutus.Contract.Data.Payment
import Plutus.Contract.Blockchain.Utils
import Ledger.Ada (adaSymbol,adaToken)
import Playground.Contract
import qualified PlutusTx.AssocMap as AssocMap
import Ledger.Contexts
    ( ScriptContext(ScriptContext, scriptContextTxInfo),
      getContinuingOutputs,
      ownHash,
      txSignedBy,
      valuePaidTo,
      TxInInfo(TxInInfo),
      TxInfo(TxInfo, txInfoInputs, txInfoValidRange),
      TxOut(TxOut, txOutValue) )
import Ledger.Interval (UpperBound(UpperBound),LowerBound(LowerBound))
import Ledger.Time (POSIXTime)


---------------------------------------------------------------------------------------------
----- Foreign functions (these used be in some other file but PLC plugin didn't agree)
---------------------------------------------------------------------------------------------

-- moving this function to Data/Payment.hs will give following error
--
--GHC Core to PLC plugin: E043:Error: Reference to a name which is not a local, a builtin, or an external INLINABLE function:
-- Variable Plutus.Contract.Data.Payment.$s$fFoldable[]_$cfoldMap
--            OtherCon []
--Context: Compiling expr: Plutus.Contract.Data.Payment.$s$fFoldable[]_$cfoldMap

{-# INLINABLE validatePayment#-}
validatePayment :: (PubKeyHash ->  Value -> Bool )-> Payment ->Bool
validatePayment f p=
 all  (\pkh -> f pkh (paymentValue p pkh)) (paymentPkhs p)



-- moving this function to Blockchain/Utils.hs will give following error
--
--GHC Core to PLC plugin: E043:Error: Reference to a name which is not a local, a builtin,
--  or an external INLINABLE function: Variable
--  Plutus.Contract.Blockchain.Utils.$s$fFoldable[]_$cfoldMap
--           No unfolding

{-# INLINABLE allowSingleScript #-}
allowSingleScript:: ScriptContext  -> Bool
allowSingleScript ctx@ScriptContext{scriptContextTxInfo=TxInfo{txInfoInputs}} =
    all checkScript txInfoInputs
  where
    checkScript (TxInInfo _ (TxOut address _ _))=
      case addressCredential  address of
        ScriptCredential vhash ->  traceIfFalse  "Reeming other Script utxo is Not allowed" (thisScriptHash == vhash)
        _ -> True
    thisScriptHash= ownHash ctx

allScriptInputsCount:: ScriptContext ->Integer
allScriptInputsCount ctx@(ScriptContext info purpose)=
    foldl (\c txOutTx-> c + countTxOut txOutTx) 0 (txInfoInputs  info)
  where
  countTxOut (TxInInfo _ (TxOut addr _ _)) = if isJust (toValidatorHash addr) then 1 else 0


----------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------

{-# INLINABLE marketHundredPercent #-}
marketHundredPercent :: Integer
marketHundredPercent=100_000_000

newtype Price = Price (CurrencySymbol ,TokenName ,Integer) deriving(Show,Generic,ToJSON,FromJSON)

{-# INLINABLE valueOfPrice#-}
valueOfPrice :: Price ->  Value
valueOfPrice (Price (c,t,v)) = singleton c t v


data Market = Market
    {   mOperator           :: !PubKeyHash
    ,   mPrimarySaleFee     :: !Integer
    ,   mSecondarySaleFee   :: !Integer
    ,   mAuctionFee         :: !Integer
    } deriving (Show,Generic, FromJSON, ToJSON)

data MarketRedeemer =  ClaimBid| Bid | Buy | Withdraw
    deriving (Generic,FromJSON,ToJSON,Show,Prelude.Eq)


data SellType = Primary | Secondary  deriving (Show, Prelude.Eq,Generic,ToJSON,FromJSON,ToSchema)

data DirectSale=DirectSale{
    dsParties::  [(PubKeyHash,Integer)], -- ^ The values that should be paid to the parties in a sale
    dsAsset ::  AssetClass, -- ^ the assetclass for cost
    dsType::  !SellType
} deriving(Show,Generic,ToJSON,FromJSON)

dsSellerShare:: DirectSale->Integer
dsSellerShare DirectSale{dsParties} =sum $ map snd dsParties 

dsCost :: Market -> DirectSale -> Integer
dsCost Market{mPrimarySaleFee,mSecondarySaleFee} ds= (dsSellerShare ds * marketHundredPercent)`divide` (marketHundredPercent-fee)
  where 
    fee= case dsType ds of 
      Primary-> mPrimarySaleFee
      Secondary-> mSecondarySaleFee

{-# INLINABLE dsMarketShare #-}
dsMarketShare :: Market -> DirectSale -> Integer
dsMarketShare market ds=dsCost market ds - dsSellerShare ds

-- Previou's owner's winning after a auction is complete
{-# INLINABLE aSellerShareValue #-}
aSellerShareValue :: Market -> Auction -> Value-> Value
aSellerShareValue m@Market{mAuctionFee} a@Auction{aAssetClass,aValue} fValue =
  fValue - aValue-aMarketShareValue m a fValue -aPartiesShareValue m a fValue

aPartiesSharePayment:: Market ->Auction->Value->Payment
aPartiesSharePayment Market{mAuctionFee} Auction{aAssetClass,aValue,aParties} fValue=foldMap partyPayment aParties
  where 
    partyPayment (pkh,share) = payment pkh $ assetClassValue aAssetClass $ (share*totalSellerShare) `divide` marketHundredPercent
    totalSellerShare= ((marketHundredPercent-mAuctionFee) * finalValue) `divide` marketHundredPercent
    finalValue = assetClassValueOf fValue aAssetClass


aPartiesShareValue:: Market -> Auction -> Value -> Value
aPartiesShareValue  Market{mAuctionFee} Auction{aAssetClass,aValue,aParties} fValue=assetClassValue aAssetClass v
  where 
    v= sum $  map (\(pkh,share)-> (share*totalSellerShare) `divide` marketHundredPercent) aParties
    totalSellerShare= (marketHundredPercent-mAuctionFee) * finalValue
    finalValue = assetClassValueOf fValue aAssetClass

-- Operator's share for auction,
-- if the split is fractional, market receives the extra.
-- For example if market  fee is 3.22, operator will receive 4 Ada.
{-# INLINABLE aMarketShareValue #-}
aMarketShareValue :: Market -> Auction -> Value-> Value
aMarketShareValue Market{mAuctionFee} Auction{aAssetClass} fValue = assetClassValue aAssetClass v
    where
      v=finalAssetValue - (((marketHundredPercent - mAuctionFee) * finalAssetValue) `divide` marketHundredPercent )
      finalAssetValue= assetClassValueOf fValue aAssetClass


data Auction = Auction{
    aOwner  :: !PubKeyHash, -- pkh Who created the auction.
    aParties:: [(PubKeyHash,Integer)], -- other parties that must be paid. the integer value is Percentage
    aBidder:: !PubKeyHash, -- Current Bidder
    aAssetClass:: !AssetClass, -- The Bidding currency for auction.
    aMinBid :: !Integer, -- starting Bid
    aMinIncrement :: !Integer, -- min increment  from previous auction per bid
    aDuration:: !POSIXTimeRange, -- Auction duration
    aValue:: Value  -- The value that's placed on Auction. this is what winner gets.
} deriving (Generic, Show,ToJSON,FromJSON,Prelude.Eq)
PlutusTx.unstableMakeIsData ''Auction

aClaimInterval :: Auction-> Interval POSIXTime
aClaimInterval Auction{aDuration}= Interval (toLower $ ivTo aDuration) (UpperBound PosInf False)
  where
    toLower (UpperBound  a _)=LowerBound a True

{-# INLINABLE auctionAssetValue #-}
auctionAssetValue :: Auction -> Integer -> Value
auctionAssetValue Auction{aAssetClass=AssetClass (c, t)} = singleton c t
{-# INLINABLE getAuctionAssetValue #-}
getAuctionAssetValue:: Auction -> Value->Value
getAuctionAssetValue a v =auctionAssetValue a $ auctionAssetValueOf a v 

{-# INLINABLE auctionAssetValueOf #-}
auctionAssetValueOf :: Auction -> Value -> Integer
auctionAssetValueOf Auction{aAssetClass} value = assetClassValueOf value aAssetClass


{-# INLINABLE  validateBid #-}
validateBid ::  Auction -> ScriptContext -> Bool
validateBid auction ctx@ScriptContext  {scriptContextTxInfo=info}=
  case txOutDatum  ctx newTxOut of
    Just nAuction@Auction{} ->
            traceIfFalse "Unacceptible modification to output datum" (validOutputDatum nAuction)
        &&  traceIfFalse "Only one bid per transaction" (allScriptInputsCount  ctx ==1 )
        &&  traceIfFalse "This auction looks like a scam" validInputDatum
        &&  traceIfFalse "Insufficient payment to market contract" isMarketScriptPayed
        &&  traceIfFalse "Insufficient payment to previous bidder" isExBidderPaid
        &&  traceIfFalse "Not during the auction period" duringTheValidity
    _       -> trace "Output Datum can't be parsed to Auction" False
  where
    duringTheValidity  =   aDuration auction `contains` txInfoValidRange info
    validOutputDatum  nAuction  =  aMinIncrement auction == aMinIncrement nAuction &&
                                      aAssetClass auction == aAssetClass nAuction &&
                                      aDuration auction == aDuration nAuction &&
                                      aOwner auction== aOwner nAuction &&
                                      aBidder nAuction /= aOwner auction

    -- without this check, auction creator might say that
    -- they are placing asset on auction datum without locking them.
    validInputDatum = ownInputValue ctx `geq` aValue auction
    minNewBid = ownInputValue ctx <>
        auctionAssetValue auction (
            if  lastAuctionAssetValue == 0
            then  aMinBid auction
            else  aMinIncrement auction)
    isExBidderPaid=
        if lastAuctionAssetValue == 0
        then True
        else assetClassValueOf  (valuePaidTo info (aBidder auction))  (aAssetClass auction) >= lastAuctionAssetValue

    lastAuctionAssetValue= assetClassValueOf  (ownInputValue ctx ) (aAssetClass auction)

    isMarketScriptPayed = ownOutputValue ctx `geq` minNewBid

    newTxOut=case getContinuingOutputs ctx of
       [txOut] -> txOut
       _       -> traceError "MultipleOutputs"


{-# INLINABLE  validateWithdraw #-}
validateWithdraw market datum ctx=
          isDirectSale
      ||  isAuction
      || traceIfFalse  "Only Operator can withdraw utxos with invalid datum" (txSignedBy info $ mOperator market)
  where
      isAuction = case fromData datum of
          (Just auction)      ->  traceIfFalse "Missing owner signature" (txSignedBy info (aOwner auction)) &&
                                  traceIfFalse "Cannot withdraw auction with bids" (aBidder auction==aOwner auction) &&
                                  traceIfFalse "Auction is Still active"  (auctionNotActive auction)
          _ -> False
      isDirectSale= case fromData  datum of
          (Just (DirectSale dsParties _ _ ) )   -> traceIfFalse "Missing seller signature" (txSignedBy info $ fst $ head dsParties)
          _                   -> False
      info=scriptContextTxInfo ctx
      auctionNotActive auction = not $ aDuration auction `contains` txInfoValidRange info


{-# INLINABLE validateClaimAuction  #-}
validateClaimAuction :: Market  -> ScriptContext -> Bool
validateClaimAuction  market@Market{mAuctionFee,mOperator} ctx@ScriptContext{scriptContextTxInfo=info} =
          allowSingleScript ctx
      &&  traceIfFalse  "Auction not Expired" allAuctionsExpired
      &&  traceIfFalse "Market fee not paid" isOperatorPaid
      &&  traceIfFalse "Bidder not paid"     areWinnersPaid
      && traceIfFalse  "Sellers not paid"      areSellersPaid
      where
        -- auction validity
        allAuctionsExpired =  all isAuctionExpired auctionsWithTxOut
        isAuctionExpired (txOut,auction) = (ivTo  $ aDuration auction) < (ivTo $ txInfoValidRange info)

        -- Check that each of the parties are paid
        areWinnersPaid  = validatePayment (\pkh v->valuePaidTo info pkh `geq` v)  totalWinnerPayment
        areSellersPaid  = validatePayment (\pkh v -> valuePaidTo info pkh  `geq` v)  totalSellerPayment
        isOperatorPaid  = valuePaidTo info mOperator `geq`  totalOperatorFee

        -- Total payments arising from the utxos
        totalSellerPayment= foldMap  sellerPayment auctionsWithTxOut
        totalWinnerPayment= foldMap  aWinnerPayment auctionsWithTxOut
        totalOperatorFee  = foldMap  operatorFee auctionsWithTxOut

        -- payment share for each party in a auction txOut
        sellerPayment   (txOut,auction) = (payment  (aOwner auction) $ aSellerShareValue market auction $ txOutValue txOut)
                                          <> aPartiesSharePayment market auction (getAuctionAssetValue auction $ txOutValue txOut)
        operatorFee     (txOut,auction) = aMarketShareValue market auction $ txOutValue txOut
        aWinnerPayment  (txOut,auction) = payment (aBidder auction) $ aValue auction

        auctionsWithTxOut:: [(TxOut,Auction)]
        auctionsWithTxOut=ownInputsWithDatum  ctx
        




{-# INLINABLE validateBuy #-}
validateBuy:: Market -> ScriptContext ->Bool
validateBuy market@Market{mOperator,mPrimarySaleFee,mSecondarySaleFee} ctx=
       allowSingleScript ctx
    && traceIfFalse "Insufficient payment" areSellersPaid
    && traceIfFalse "Insufficient fees" isMarketFeePaid
    where
        info=scriptContextTxInfo ctx

        isMarketFeePaid = valuePaidTo info mOperator `geq` totalMarketFee
        areSellersPaid  = validatePayment (\pkh v-> valuePaidTo info pkh `geq` v) totalSellerPayment

        totalSellerPayment  = foldMap  sellerSharePayment salesWithTxOut
        totalMarketFee      = foldMap  marketFeeValue salesWithTxOut

        sellerSharePayment (txOut,dsale) = foldMap (\(pkh,v)-> payment pkh $ assetClassValue (dsAsset dsale) v) (dsParties dsale) 
        marketFeeValue    (txOut,dsale)  = assetClassValue (dsAsset dsale ) $ dsMarketShare market dsale

        salesWithTxOut:: [(TxOut,DirectSale)]
        salesWithTxOut = ownInputsWithDatum ctx

{-# INLINABLE mkMarket #-}
mkMarket :: Market ->  Data -> MarketRedeemer -> ScriptContext  -> Bool
mkMarket market d action ctx =
    case  action of
        Buy       -> validateBuy market ctx
        Withdraw  -> validateWithdraw market d ctx
        Bid       -> case fromData d of
                    Just auction -> validateBid auction ctx
                    _            -> trace "Invalid Auction datum" False
        ClaimBid  -> validateClaimAuction market ctx


data MarketScriptType
instance Scripts.ValidatorTypes MarketScriptType where
    type instance RedeemerType MarketScriptType = MarketRedeemer
    type instance DatumType MarketScriptType = PubKeyHash


-- marketValidator :: Market -> Validator
-- marketValidator market = Ledger.mkValidatorScript $
--     $$(PlutusTx.compile [|| validatorParam ||])
--         `PlutusTx.applyCode`
--             PlutusTx.liftCode market
--     where validatorParam m = Scripts.wrapValidator (mkMarket m)


marketValidator :: Market -> Validator
marketValidator market= mkValidatorScript $$(PlutusTx.compile [||a ||])
    where
        a _ _ _=()

marketAddress :: Market -> Ledger.Address
marketAddress = scriptAddress . marketValidator

PlutusTx.unstableMakeIsData ''MarketRedeemer
PlutusTx.unstableMakeIsData ''SellType
PlutusTx.unstableMakeIsData ''Price
PlutusTx.unstableMakeIsData ''DirectSale

PlutusTx.makeLift ''Market
