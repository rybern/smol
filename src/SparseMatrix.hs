{-# LANGUAGE OverloadedLists, ViewPatterns, GeneralizedNewtypeDeriving #-}
module SparseMatrix where

--import qualified Math.LinearAlgebra.Sparse as M
import qualified Data.Eigen.SparseMatrix as M
import qualified Data.Eigen.Internal as I
import Foreign.C.Types
import qualified Data.Vector.Storable as SV
import qualified Data.Vector as V
import Data.Vector (Vector)
import Data.Maybe
import Data.List
import qualified Data.Map as Map
import Data.Foldable (toList)

-- index from 1
-- fromAssocList uses max indices

type Index = Int

type SparseMatrix = M.SparseMatrixXd
-- row vector, shaped (1, n)
newtype SparseVector = SV M.SparseMatrixXd
  deriving (Show, Num)
type CTriplet = I.CTriplet CDouble

instance Monoid SparseVector where
  mempty = SV emptyMx
  mappend (SV a) (SV b) = SV $ hconcat [a, b]

unSV :: SparseVector -> SparseMatrix
unSV (SV m) = m

width :: SparseMatrix -> Int
width = M.cols

height :: SparseMatrix -> Int
height = M.rows

trans :: SparseMatrix -> SparseMatrix
trans = M.transpose

toAssocList :: SparseMatrix -> [((Index, Index), Double)]
toAssocList m = (((height m, width m), 0) :)
              . map (\(x, y, v) -> ((x + 1, y + 1), v))
              $ M.toList m

toAssocList' :: SparseMatrix -> [((Index, Index), Double)]
toAssocList' = map (\(x, y, v) -> ((x, y), v)) . M.toList

fromAssocList :: [((Index, Index), Double)] -> SparseMatrix
fromAssocList ps = fromAssocList' maxR maxC ps'
  where (maxR, maxC, ps') = foldl' takeTriple (0, 0, []) ps
        takeTriple (maxR, maxC, sofar) ((r, c), v) =
          (max maxR r, max maxC c, ((r - 1, c - 1), v):sofar)

fromAssocList' :: Int -> Int -> [((Index, Index), Double)] -> SparseMatrix
fromAssocList' width height = M.fromList width height . map (\((x, y), v) -> (x, y, v))

vecFromAssocList' :: Int -> [(Index, Double)] -> SparseVector
vecFromAssocList' width = SV . fromAssocList' 1 width . map (\(x, v) -> ((0, x), v))

vecFromAssocList :: [(Index, Double)] -> SparseVector
vecFromAssocList ps = SV $ fromAssocList' 1 maxC ps'
  where (maxC, ps') = foldl' takeTriple (0, []) ps
        takeTriple (maxC, sofar) (c, v) =
          (max maxC c, ((0, c - 1), v):sofar)

vecToAssocList :: SparseVector -> [(Index, Double)]
vecToAssocList = map (\((_, x), v) -> (x, v)) . toAssocList . unSV

sparseMx :: [[Double]] -> SparseMatrix
sparseMx = M.fromDenseList

mul :: SparseMatrix -> SparseMatrix -> SparseMatrix
mul a b = if aw == bh
          then a `M.mul` b
          else if bh < aw
               then a `M.mul` setSize (aw, bw) b
               else a `M.mul` b -- throws an error
  where (ah, aw) = dims a
        (bh, bw) = dims b

sumMx :: SparseMatrix -> Double
sumMx = realToFrac . SV.sum . M.values

sumV :: SparseVector -> Double
sumV = realToFrac . SV.sum . M.values . unSV

scale ::  Double -> SparseMatrix -> SparseMatrix
scale = M.scale

scaleV ::  Double -> SparseVector -> SparseVector
scaleV x = SV . scale x . unSV

allElems :: SparseVector -> Vector Double
allElems v = V.map (v !) $ [1..dim v]

(!) :: SparseVector -> Index -> Double
(!) (SV v) ix = v # (0, ix - 1)

(#) :: SparseMatrix -> (Index, Index) -> Double
(#) m (r, c) = m M.! (r - 1, c - 1)

dims :: SparseMatrix -> (Int, Int)
dims m = (height m, width m)

dim :: SparseVector -> Int
dim = width . unSV

isZeroMx :: SparseMatrix -> Bool
isZeroMx = (== 0) . M.nonZeros

isZeroVec :: SparseVector -> Bool
isZeroVec = isZeroMx . unSV

isNotZeroVec :: SparseVector -> Bool
isNotZeroVec = not . isZeroVec

zeroMx :: (Int, Int) -> SparseMatrix
zeroMx (height, width) = M.fromList height width []

emptyMx :: SparseMatrix
emptyMx = zeroMx (0, 0)

idMx :: Int -> SparseMatrix
idMx n = fromAssocList' n n [((i, i), 1) | i <- [0..n-1]]

singVec :: Double -> SparseVector
singVec x = SV $ fromAssocList' 1 1 [((0, 0), x)]

zeroVec :: Int -> SparseVector
zeroVec n = SV $ zeroMx (1, n)

row :: SparseMatrix -> Index -> SparseVector
row m ix = SV $ M.block (ix - 1) 0 1 (width m) m

col :: SparseMatrix -> Index -> SparseVector
col m ix = SV $ M.block 0 (ix - 1) (height m) 1 m

-- would it be better to iterate over the list form?
rows :: SparseMatrix -> Vector SparseVector
rows m = V.map (row m) $ [1..height m]

cols :: SparseMatrix -> Vector SparseVector
cols m = V.map (col m) $ [1..width m]

fromRows :: (Foldable f, Functor f) => f SparseVector -> SparseMatrix
fromRows = vconcat . fmap unSV . toList

fromCols :: (Foldable f, Functor f) => f SparseVector -> SparseMatrix
fromCols = hconcat . fmap unSV . toList

blockMx :: [[SparseMatrix]] -> SparseMatrix
blockMx [] = emptyMx
blockMx mxs = M.fromVector totalHeight totalWidth
            . vconcat'
            . zip rowIxs
            . map (hconcat' . zip colIxs . map M.toVector)
            $ mxs
  where heights = map (maximum . map height) $ mxs
        totalHeight = sum heights
        rowIxs = scanl (+) 0 heights
        widths = map width . head $ mxs
        totalWidth = sum widths
        colIxs = scanl (+) 0 widths

vconcat :: [SparseMatrix] -> SparseMatrix
vconcat [] = emptyMx
vconcat mxs = M.fromVector totalHeight totalWidth . vconcat' . zip colIxs . map M.toVector $ mxs
  where heights = map height mxs
        totalHeight = sum heights
        colIxs = scanl (+) 0 heights
        totalWidth = maximum . map width $ mxs

hconcat :: [SparseMatrix] -> SparseMatrix
hconcat [] = emptyMx
hconcat mxs = M.fromVector totalHeight totalWidth . hconcat' . zip rowIxs . map M.toVector $ mxs
  where widths = map width mxs
        totalWidth = sum widths
        rowIxs = scanl (+) 0 widths
        totalHeight = maximum . map height $ mxs

shiftTriplet :: (Int, Int) -> CTriplet -> CTriplet
shiftTriplet (a, b) (I.CTriplet x y v) = I.CTriplet (x + fromIntegral a) (y + fromIntegral b) v

shiftTriplets :: (Int, Int) -> SV.Vector CTriplet -> SV.Vector CTriplet
shiftTriplets by = SV.map (shiftTriplet by)

vconcat' :: (Foldable f) => f (Int, SV.Vector CTriplet) -> SV.Vector CTriplet
vconcat' = foldMap (\(rowIx, tris) -> shiftTriplets (rowIx, 0) tris)

hconcat' :: (Foldable f) => f (Int, SV.Vector CTriplet) -> SV.Vector CTriplet
hconcat' = foldMap (\(colIx, tris) -> shiftTriplets (0, colIx) tris)

shiftAndJoin :: (Int, Int) -> SparseMatrix -> SparseMatrix -> SparseMatrix
shiftAndJoin by@(x, y) m1 m2 = M.fromVector height' width'
                             . (M.toVector m2 SV.++)
                             . shiftTriplets by
                             $ M.toVector m1
  where height' = max (height m1 + x) (height m2)
        width' = max (width m1 + y) (width m2)

overwrite' :: ((Int, Int) -> Bool)
          -> [((Index, Index), Double)]
          -> SparseMatrix
          -> SparseMatrix
overwrite' p vals m = fromAssocList' (height m) (width m)
                   . (vals ++)
                   . filter (not . p . fst)
                   . toAssocList'
                   $ m

 -- unclear which is faster
replaceRow' :: SparseVector -> Index -> SparseMatrix -> SparseMatrix
replaceRow' v (pred -> r) = overwrite'
  ((== r) . fst)
  (map (\((_, c), v) -> ((r, c), v)) $ toAssocList' (unSV v))

replaceRow :: SparseVector -> Index -> SparseMatrix -> SparseMatrix
replaceRow (SV row) (pred -> r) m = vconcat . catMaybes $
  [ if r == 0 then Nothing else Just $
    M.block 0 0 r (width m) m
  , Just row
  , if r == height m - 1 then Nothing else Just $
    M.block (r+1) 0 (height m - r - 1) (width m) m]

testMat :: Int -> Int -> Double -> SparseMatrix
testMat height width start = sparseMx [ [start+fromIntegral width*row
                                          .. start+fromIntegral width*(row+1)-1]
                                      | row <- [0..fromIntegral height-1]]

mapOnRows :: (SparseVector -> SparseVector) -> SparseMatrix -> SparseMatrix
mapOnRows f = fromRows . V.map f . rows

unionVecsWith :: (Double -> Double -> Double) -> SparseVector -> SparseVector -> SparseVector
unionVecsWith f v1 v2 = vecFromAssocList' dim'
                      . Map.toList
                      $ Map.unionWith f (toMap v1) (toMap v2)
  where toMap = Map.fromList . vecToAssocList
        dim' = max (dim v1) (dim v2)

vecIns :: SparseVector -> (Index, Double) -> SparseVector
vecIns (SV v) (pred -> c, val) = SV $ overwrite' ((== c) . snd) [((0, c), val)] v

addRow :: SparseVector -> Index -> SparseMatrix -> SparseMatrix
addRow (SV row) (pred -> r) m = vconcat . catMaybes $
  [ if r == 0 then Nothing else Just $
    M.block 0 0 r (width m) m
  , Just row
  , if r == height m then Nothing else Just $
    M.block r 0 (height m - r) (width m) m]

addCol :: SparseVector -> Index -> SparseMatrix -> SparseMatrix
addCol (SV col) (pred -> c) m = hconcat . catMaybes $
  [ if c == 0 then Nothing else Just $
    M.block 0 0 (height m) c m
  , Just $ trans col
  , if c == width m then Nothing else Just $
    M.block 0 c (height m) (width m - c) m]

setSize :: (Int, Int) -> SparseMatrix -> SparseMatrix
setSize (h, w) = M.fromVector h w . M.toVector

setLength :: Int -> SparseVector -> SparseVector
setLength l = SV . setSize (1, l) . unSV

delRow :: Index -> SparseMatrix -> SparseMatrix
delRow (pred -> r) m = vconcat . catMaybes $
  [ if r == 0 then Nothing else Just $
    M.block 0 0 r (width m) m
  , if r == height m then Nothing else Just $
    M.block (r+1) 0 (height m - r - 1) (width m) m]

delCol :: Index -> SparseMatrix -> SparseMatrix
delCol (pred -> c) m = hconcat . catMaybes $
  [ if c == 0 then Nothing else Just $
    M.block 0 0 (height m) c m
  , if c == width m then Nothing else Just $
    M.block 0 (c+1) (height m) (width m - c - 1) m]

popRow :: Index -> SparseMatrix -> (SparseVector, SparseMatrix)
popRow r m = (row m r, delRow r m)

popCol :: Index -> SparseMatrix -> (SparseVector, SparseMatrix)
popCol c m = (col m c, delCol c m)

testA = testMat 3 4 1
testB = testMat 3 3 13
testC = testMat 1 4 22
testD = testMat 1 3 26

test1 = blockMx [ [testA, testB]
                , [testC, testD]]

test2 = replaceRow (SV $ sparseMx [[-1, -2, -3, -4, -5, -6, -7]]) 2 test1
test3 = replaceRow' (SV $ sparseMx [[-1, -2, -3, -4, -5, -6, -7]]) 2 test1
test4 = addRow (SV $ sparseMx [[-1, -2, -3, -4, -5, -6, -7]]) 2 test1
test5 = addCol (SV $ sparseMx [[-1, -2, -3, -4]]) 1 test1


{-
popRow :: (Num a) => Index -> SparseMatrix a -> (SparseVector a, SparseMatrix a)
popRow = M.popRow
-}