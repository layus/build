{-# LANGUAGE FlexibleContexts, ScopedTypeVariables #-}
module Build.Strategy (
    Strategy, alwaysRebuildStrategy,
    makeStrategy, Time, MakeInfo,
    approximationStrategy, DependencyApproximation, ApproximationInfo,
    vtStrategyA, vtStrategyM,
    ctStrategyA, ctStrategyM,
    dctStrategyA
    ) where

import Control.Monad.State
import Data.List
import Data.Semigroup

import Build.Store
import Build.Task
import Build.Task.Monad
import Build.Trace

import qualified Build.Task.Applicative as A

type Strategy c i k v = k -> v -> Task c k v -> Task (MonadState i) k v

alwaysRebuildStrategy :: Strategy Monad () k v
alwaysRebuildStrategy _key _value task = Task (run task)

------------------------------------- Make -------------------------------------
type Time = Integer -- A negative time value means a key was never built
type MakeInfo k = (k -> Time, Time)

makeStrategy :: Eq k => Strategy Applicative (MakeInfo k) k v
makeStrategy key value task = Task $ \fetch -> do
    (modTime, now) <- get
    let dirty = or [ modTime dep > modTime key | dep <- A.dependencies task ]
    if not (dirty || modTime key < 0)
    then return value
    else do
        let newModTime k = if k == key then now else modTime k
        put (newModTime, now + 1)
        run task fetch

--------------------------- Depencency approximation ---------------------------
data DependencyApproximation k = SubsetOf [k] | Unknown -- Add Exact [k]?

instance Ord k => Semigroup (DependencyApproximation k) where
    Unknown <> x = x
    x <> Unknown = x
    SubsetOf xs <> SubsetOf ys = SubsetOf (sort xs `intersect` sort ys)

instance Ord k => Monoid (DependencyApproximation k) where
    mempty  = Unknown
    mappend = (<>)

type ApproximationInfo k = (k -> Bool, k -> DependencyApproximation k)

approximationStrategy :: Ord k => Strategy Monad (ApproximationInfo k) k v
approximationStrategy key value task = Task $ \fetch -> do
    (isDirty, deps) <- get
    let dirty = isDirty key || case deps key of SubsetOf ks -> any isDirty ks
                                                Unknown     -> True
    if not dirty
        then return value
        else do
            put (\k -> k == key || isDirty k, deps)
            run task fetch

------------------------------- Verifying traces -------------------------------
vtStrategyA :: (Ord k, Hashable v) => Strategy Applicative (VT k v) k v
vtStrategyA key value task = Task $ \fetch -> do
    vt <- get
    dirty <- not <$> verifyVT key value (fmap hash . fetch) vt
    if not dirty
    then return value
    else do
        newValue <- run task fetch
        newVT <- recordVT key newValue (A.dependencies task) (fmap hash . fetch)
        modify (newVT <>)
        return newValue

vtStrategyM :: (Eq k, Hashable v) => Strategy Monad (VT k v) k v
vtStrategyM key value task = Task $ \fetch -> do
    vt <- get
    dirty <- not <$> verifyVT key value (fmap hash . fetch) vt
    if not dirty
    then return value
    else do
        (newValue, deps) <- trackM task fetch
        newVT <- recordVT key newValue deps (fmap hash . fetch)
        modify (newVT <>)
        return newValue

------------------------------ Constructive traces -----------------------------
ctStrategyM :: (Eq k, Hashable v) => Strategy Monad (CT k v) k v
ctStrategyM key value task = Task $ \fetch -> do
    ct <- get
    dirty <- not <$> verifyCT key value (fmap hash . fetch) ct
    if not dirty
    then return value
    else do
        maybeCachedValue <- constructCT key (fmap hash . fetch) ct
        case maybeCachedValue of
            Just cachedValue -> return cachedValue
            Nothing -> do
                (newValue, deps) <- trackM task fetch
                newCT <- recordCT key newValue deps (fmap hash . fetch)
                modify (newCT <>)
                return newValue

ctStrategyA :: (Ord k, Hashable v) => Strategy Applicative (CT k v) k v
ctStrategyA key value task = Task $ \fetch -> do
    ct <- get
    dirty <- not <$> verifyCT key value (fmap hash . fetch) ct
    if not dirty
    then return value
    else do
        maybeCachedValue <- constructCT key (fmap hash . fetch) ct
        case maybeCachedValue of
            Just cachedValue -> return cachedValue
            Nothing -> do
                newValue <- run task fetch
                newCT <- recordCT key newValue (A.dependencies task) (fmap hash . fetch)
                modify (newCT <>)
                return newValue

----------------------- Deterministic constructive traces ----------------------
dctStrategyA :: (Hashable k, Hashable v) => Strategy Applicative (DCT k v) k v
dctStrategyA key value task = Task $ \fetch -> do
    dct <- get
    dirty <- not <$> verifyDCT key (A.dependencies task) (fmap hash . fetch) dct
    if not dirty
    then return value
    else do
        maybeCachedValue <- constructDCT key (A.dependencies task) (fmap hash . fetch) dct
        case maybeCachedValue of
            Just cachedValue -> return cachedValue
            Nothing -> do
                newValue <- run task fetch
                newDCT <- recordDCT key newValue (A.dependencies task) (fmap hash . fetch)
                modify (newDCT <>)
                return newValue
