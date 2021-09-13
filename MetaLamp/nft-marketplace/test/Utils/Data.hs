module Utils.Data where

import           Ledger                  (Address, pubKeyHash)
import           Plutus.V1.Ledger.Crypto (PubKeyHash)
import           Wallet.Emulator.Types   (Wallet (..), walletPubKey)
import           Wallet.Emulator.Wallet  (Wallet, walletPubKey)

one :: (a -> Bool) -> [a] -> Bool
one f = foldr reducer False
    where
        reducer cur acc = if acc then not . f $ cur else f cur

walletPkh :: Wallet -> PubKeyHash
walletPkh = pubKeyHash . walletPubKey

checkOneDatum :: (d -> Bool) -> [d] -> Bool
checkOneDatum check [d] = check d
checkOneDatum _ _       = False
