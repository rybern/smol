{-# LANGUAGE DeriveFunctor, TupleSections #-}
module Sequence.Tags where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Vector (Vector)
import qualified Data.Vector as V
import Control.Monad.State hiding (state)
import Control.Monad.Reader
import Sequence.Types
import Sequence.Constructors
import Sequence.Matrix

import Sequence.Tags.Utils
import Inference

type TagIxs = IntMap (Vector IntSet)
data Posterior = Posterior { unposterior :: IntMap Prob }
  deriving Show

{-
 restrict keys appears to be broken

let s = (IntSet.fromList [2..4])
let m = IntMap.fromList $ zip [0..5] [1..6]
IntMap.restrictKeys m s
IntMap.filterWithKey (\k _ -> k `IntSet.member` s) m
-}

subsetIxs :: IntSet -> Posterior -> Posterior
subsetIxs ixs (Posterior ems) = Posterior $ IntMap.restrictKeys ems ixs

unionPosts :: [Posterior] -> Posterior
unionPosts = Posterior . IntMap.unions . fmap unposterior

tagDist :: (Ord t) => Tag t -> Query (Map t (Posterior))
tagDist (Tag { tagId = tagId, values = values }) = do
  (post, ixs) <- ask
  let ixsVec = case IntMap.lookup tagId ixs of
        Nothing -> error "Using a tag that isn't in MatSeq"
        Just (ixsVec) -> ixsVec
      postMap = Map.fromList . V.toList . V.zip values . V.map (flip subsetIxs post) $ ixsVec
  return postMap

type Query = Reader (Posterior, TagIxs)

buildQuery :: (Ord d, Show d) => InferenceEngine (Vector Prob) -> ProbSeq d -> Query a -> Emissions d -> a
buildQuery fn ps q emis = runReader q (post, ixs)
  where ms = buildMatSeq ps
        ixs = tagIxs ms
        post = posterior fn emis ms

observe :: Emissions d -> State TagGen (Emissions d -> a) -> a
observe ems s = (runTagGen s) ems

partitionPost :: (Ord c) => Tag c -> (c -> Bool) -> Query (Posterior, Posterior)
partitionPost t pred = do
  dist <- tagDist t
  let (true, false) = Map.partitionWithKey (\k _ -> pred k) dist
      join = unionPosts . Map.elems
  return (join true, join false)

event1 :: (Ord c) => Tag c -> (c -> Bool) -> Query Prob
event1 t pred = do
  (truePost, falsePost) <- partitionPost t pred
  let add = sum . unposterior
      trueSum = add truePost
      falseSum = add falsePost
  return $ trueSum / (falseSum + trueSum)

condition1 :: (Ord c) => Tag c -> (c -> Bool) -> Query a -> Query a
condition1 t pred next = do
  (post, _) <- partitionPost t pred
  (_, ixs) <- ask
  local (const (post, ixs)) next

posterior :: (Ord s, Show s) => InferenceEngine (Vector Prob) -> Emissions s -> MatSeq s -> Posterior
posterior fn ems = Posterior . vecToIntMap . infer fn ems

vecToIntMap :: Vector a -> IntMap a
vecToIntMap = IntMap.fromList . V.toList . V.indexed

tagIxs :: MatSeq d -> TagIxs
tagIxs ms = IntMap.fromSet ixSet ids
  where mapVec = V.map tagSet $ stateLabels ms
        ids = V.foldl' (\s m -> s `IntSet.union` IntMap.keysSet m) IntSet.empty mapVec
        ixSet :: Int -> Vector IntSet
        ixSet tid = (\m -> V.generate
                      (succ . IntSet.findMax $ IntMap.keysSet m)
                      (\value -> IntMap.findWithDefault IntSet.empty value m))
                  . IntMap.fromListWith IntSet.union
                  . V.toList
                  . V.mapMaybe (\(ix, m) -> (,IntSet.singleton ix) <$> IntMap.lookup tid m)
                  . V.indexed
                  $ mapVec
