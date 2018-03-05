{-# LANGUAGE Rank2Types, FlexibleContexts, GeneralizedNewtypeDeriving #-}

module Neil.Builder(
    dumb,
    dumbOnce,
    make,
    Shake, shake,
    ) where

import Neil.Build
import Neil.Compute
import Control.Monad.Extra
import Data.Default
import Data.Maybe
import Data.Typeable
import qualified Data.Set as Set
import qualified Data.Map as Map

---------------------------------------------------------------------
-- UTILITIES

newtype Once k = Once (Set.Set k)
    deriving Default

-- | Build a rule at most once in a single execution
once :: (Show k, Ord k, Typeable k) => k -> M k v i v -> M k v i v
once k build = do
    Once done <- getTemp
    if k `Set.member` done then
        getStore k
    else do
        r <- build
        updateTemp $ \(Once set) -> Once $ Set.insert k set
        return r


-- | Figure out when files change, like a modtime
newtype StoreTime k v = StoreTime {fromStoreTime :: Map.Map k v}
    deriving Default

data Time = LastBuild | AfterLastBuild deriving (Eq,Ord)

getStoreTimeMaybe :: (Ord k, Eq v) => k -> M k v (StoreTime k v) (Maybe Time)
getStoreTimeMaybe k = do
    old <- Map.lookup k . fromStoreTime <$> getInfo
    new <- getStoreMaybe k
    return $ if isNothing new then Nothing else Just $ if old == new then LastBuild else AfterLastBuild

getStoreTime :: (Show k, Ord k, Eq v) => k -> M k v (StoreTime k v) Time
getStoreTime k = fromMaybe (error $ "no store time available for " ++ show k) <$> getStoreTimeMaybe k


-- | Take the transitive closure of a function
transitiveClosure :: Ord k => (k -> [k]) -> [k] -> [k]
transitiveClosure deps = f Set.empty
    where
        f seen [] = Set.toList seen
        f seen (t:odo)
            | t `Set.member` seen = f seen odo
            | otherwise = f (Set.insert t seen) (deps t ++ odo)


-- | Topologically sort a list using the given dependency order
topSort :: Ord k => (k -> [k]) -> [k] -> [k]
topSort deps ks = f $ Map.fromList [(k, deps k) | k <- ks]
    where
        f mp
            | Map.null mp = []
            | Map.null leaf = error "cycles!"
            | otherwise = Map.keys leaf ++ f (Map.map (filter (`Map.notMember` leaf)) rest)
            where (leaf, rest) = Map.partition null mp


---------------------------------------------------------------------
-- BUILD SYSTEMS


-- | Dumbest build system possible, always compute everything from scratch multiple times
dumb :: Build Monad k v ()
dumb compute = runM . mapM_ f
    where f k = maybe (getStore k) (putStore k) =<< compute f k

-- | Refinement of dumb, compute everything but at most once per execution
dumbOnce :: Build Monad k v ()
dumbOnce compute = runM . mapM_ f
    where f k = once k $ maybe (getStore k) (putStore k) =<< compute f k


-- | The simplified Make approach where we build a dependency graph and topological sort it
make :: Eq v => Build Applicative k v (StoreTime k v)
make compute ks = runM $ do
    let depends = getDependencies compute
    forM_ (topSort depends $ transitiveClosure depends ks) $ \k -> do
        kt <- getStoreTimeMaybe k
        ds <- mapM getStoreTime $ depends k
        case kt of
            Just xt | all (<= xt) ds -> return ()
            _ -> maybe (return ()) (void . putStore k) =<< compute getStore k
    putInfo . StoreTime =<< getStoreMap


-- During the last execution, these were the traces I saw
type Shake k v = Map.Map k (Hash v, [(k, Hash v)])

-- | The simplified Shake approach of recording previous traces
shake :: Hashable v => Build Monad k v (Shake k v)
shake compute = runM . mapM_ f
    where
        f k = once k $ do
            info <- getInfo
            valid <- case Map.lookup k info of
                Nothing -> return False
                Just (me, deps) ->
                    (maybe False ((==) me . getHash) <$> getStoreMaybe k) &&^
                    allM (\(d,h) -> (== h) . getHash <$> f d) deps
            if valid then
                getStore k
            else do
                (ds, v) <- trackDependencies compute f k
                v <- maybe (getStore k) (putStore k) v
                dsh <- mapM (fmap getHash . getStore) ds
                updateInfo $ Map.insert k (getHash v, zip ds dsh)
                return v