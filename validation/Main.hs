{-# LANGUAGE BangPatterns, RecordWildCards, OverloadedLists, ViewPatterns #-}
module Main where

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Vector (Vector)
import qualified Data.Vector as V
import Data.List
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.Csv
import Control.Monad
import Control.Monad.Loops
import Data.Monoid
import Data.Maybe
import Sequence
import Data.Function
import System.Environment
import System.IO
import System.IO.Temp

import Plot
import SNP
import GeneralizedSNP
import EmissionPermutation
import EmissionIO
import Utils
import MinION
import SubsampleFile
import qualified SHMM as SHMM
import Data.Hashable

import Sequence.Matrix.ProbSeqMatrixUtils

import Math.LinearAlgebra.Sparse.Matrix hiding (trans)

setupSiteAnalysis :: String -> String -> [String] -> FilePath
                  -> IO (FilePath, MatSeq (StateTree GenSNPState), Int, Int, Int, Emissions, [Site NT])
setupSiteAnalysis regionFile emissionsFile siteLines outputFile = do
  (_, emissionsStart, emissionsEnd) <- readRegionFile regionFile
  numEvents <- countFileLines emissionsFile
  let sites = map parseSite siteLines
  let genMS = genMatSeq
  (Right emissions) <- readEmissions emissionsFile
  return (outputFile, genMS, numEvents, emissionsStart, emissionsEnd, emissions, sites)

setupSiteAnalysisArgs :: [String]
                      -> IO (FilePath, MatSeq (StateTree GenSNPState), Int, Int, Int, Emissions, [Site NT])
setupSiteAnalysisArgs args = do
  (regionFile, emissionsFile, siteLines, outputFile) <- case args of
    [regionFile, emissionsFile, sitesFile, outputFile] -> do
      siteLines <- lines <$> readFile sitesFile
      hPutStrLn stderr $ "Found " ++ show (length siteLines) ++ " sites"
      return (regionFile, emissionsFile, siteLines, outputFile)
    otherwise -> do
      hPutStrLn stderr "Arguments invalid, using test arguments"
      --return ("test_data/region.csv", "test_data/minion_post.csv", testLines, "test_data/snp-calling-test-output.csv")
      return ( "test_data/region.csv"
             , "test_data/minion_post.csv"
             , testLines
             , "test_data/snp-calling-test-output.csv")
  setupSiteAnalysis regionFile emissionsFile siteLines outputFile

writePosts :: (FilePath, MatSeq (StateTree GenSNPState), Int, Int, Int, Emissions, [Site NT])
           -> IO ()
writePosts (outputFile, genMS, numEvents, emissionsStart, emissionsEnd, emissions, sites) = do
  forM_ sites $ \site -> do
    print $ siteEmissionsBounds softFlank numEvents emissionsStart emissionsEnd site
    let locusStr = show (pos site)
        baseFile = "post_deamer_" ++ locusStr
        csvFile = baseFile ++ ".csv"
        pngFile = baseFile ++ ".png"
        f = id -- (/ log 1000000) . log . (+ 1) . (1000000 *)
        emissions' = siteEmissions softFlank numEvents emissionsStart emissionsEnd emissions site
    writeSNPPost genMS numEvents emissionsStart emissionsEnd emissions (head sites) csvFile
    plotLinesFromFile csvFile f pngFile ("Lg Probability of SNP at locus " ++ locusStr) "locus" "probability" (0, 1)
    hPutStrLn stderr $ "deamer " ++ show (pos site) ++ ".[csv,png]"
  hPutStrLn stderr $ "done writing post"

main = do
  env@(outputFile, genMS, numEvents, emissionsStart, emissionsEnd, emissions, sites) <-
    getArgs >>= setupSiteAnalysisArgs

  res <- callSNPs genMS numEvents emissionsStart emissionsEnd emissions sites
  print res

  --writePosts env

  {-

  probAlts <- (concat <$>) . forM sites $ \site -> do
    hPutStrLn stderr $ "running site " ++ show (pos site)
    probAlt <- callSNP genMS numEvents emissionsStart emissionsEnd emissions site
    hPutStrLn stderr $ "found p(alt) " ++ show probAlt
    return probAlt

  h <- openFile outputFile WriteMode
  forM (zip probAlts sites) $ \(p, site) ->
    hPutStrLn h $ show (pos site) ++ "," ++ show (snd $ alleles site !! 1) ++ "," ++ show p
  hClose h
-}
  -- running out of memory!
  -- calls <- forM sites $ \site -> do
    --hPutStrLn stderr "attempting site"
    --p <- callSNP emissionsFile site
    --let res = show (pos site) ++ "," ++ show (maf site) ++ "," ++ show p
    --hPutStrLn h res

  --writeFile outputFile $ unlines calls

  return ()

readRegionFile :: FilePath -> IO (String, Int, Int)
readRegionFile regionFile = do
  (Right [triple]) <- decode NoHeader <$> BS.readFile regionFile
  return triple

probOfAlt :: [Prob] -> Prob
probOfAlt [refP, altP] = (altP / (refP + altP))

{- CHECK THE INDICES! COULD BE OFF BY 1! -}

softFlank = 50

siteEmissions :: Int -> Int -> Int -> Int -> Emissions -> Site a -> Emissions
siteEmissions softFlank numEvents emissionsStart emissionsEnd emissions site = V.slice start length emissions
  where (start, length) = siteEmissionsBounds softFlank numEvents emissionsStart emissionsEnd site

siteEmissionsBounds :: Int -> Int -> Int -> Int -> Site a -> (Int, Int)
siteEmissionsBounds softFlank numEvents emissionsStart emissionsEnd site =
  (center - softFlank, 2 * softFlank + 1)
  where proportion = (fromIntegral $ pos site - emissionsStart) / (fromIntegral $ emissionsEnd - emissionsStart)
        center = round (fromIntegral numEvents * proportion) - softFlank


writeSNPPost :: MatSeq (StateTree GenSNPState) -> Int -> Int -> Int -> Emissions -> Site NT -> FilePath -> IO ()
writeSNPPost genMS numEvents emissionsStart emissionsEnd emissions site outFile = do
  -- let (matSeq, [[refIxs, altIxs]]) = specifyGenMatSeqNT genMS site
  let (matSeq, [[refIxs, altIxs]]) = snpsNTMatSeq emissionsStart emissionsEnd [site]  -- snpsNTMatSeq sites

  post <- runHMM minionIndexMap emissions matSeq

  let refVec = V.map (\row -> sum $ V.map (row V.!) refIxs) post
      altVec = V.map (\row -> sum $ V.map (row V.!) altIxs) post
      refLine = ("ref," ++ ) . intercalate "," . map show . V.toList $ refVec
      altLine = ("alt," ++ ) . intercalate "," . map show . V.toList $ altVec
      content = unlines [refLine, altLine]

  putStrLn $ "ref loci " ++ progressString emissionsStart (pos site) emissionsEnd
  putStrLn $ "ref ixs " ++ progressString 0 (V.maxIndex refVec) (V.length refVec)
  putStrLn $ "alt ixs " ++ progressString 0 (V.maxIndex altVec) (V.length refVec)
  putStrLn $ "p(alt) " ++ show (sum altVec / (sum altVec + sum refVec))

  writeFile outFile content

progressString :: Int -> Int -> Int -> String
progressString start pnt end =
    show start ++
    "/(" ++ show pnt ++
    ", " ++ show (100 * fromIntegral (pnt - start) / fromIntegral (end - start)) ++
    "%)/" ++ show end



testCallSNP :: MatSeq (StateTree GenSNPState) -> Int -> Int -> Int -> Emissions -> Site NT -> IO [Prob]
testCallSNP genMS numEvents emissionsStart emissionsEnd emissions site = do
  let (matSeq, ixs) = specifyGenMatSeqNT genMS site  -- snpsNTMatSeq sites

  hPutStr stderr $ "evaluating genMS: "
  hPutStrLn stderr $ show (trans genMS # (100, 100))
  hPutStr stderr $ "evaluating siteMS: "
  hPutStrLn stderr $ show (trans matSeq # (100, 100))

  hPutStrLn stderr $ "subsampling emissions file with region size " ++ show (2 * softFlank + 1)
  --subsampledEmissionsFile <- emptySystemTempFile emissionsFile
  --putStrLn $ "using temporary subsampled emissions file: " ++ subsampledEmissionsFile

  let subEmissions = siteEmissions softFlank numEvents emissionsStart emissionsEnd emissions site

  ps <- iterateUntilDiffM $ do
    ps <- runHMMSum' ixs minionIndexMap subEmissions matSeq
    hPutStrLn stderr $ "results: " ++ intercalate "," (map show ps)
    return ps

  return $ map probOfAlt ps

iterateUntilDiffM :: (Monad m, Eq a) => m a -> m a
iterateUntilDiffM action = do
  comp <- action
  iterateWhile (/= comp) action

callSNPs :: MatSeq (StateTree GenSNPState) -> Int -> Int -> Int -> Emissions -> [Site NT] -> IO [Prob]
callSNPs genMS numEvents emissionsStart emissionsEnd emissions sites = do
  --let (matSeq, ixs) = specifyGenMatSeqNT genMS site  -- snpsNTMatSeq sites
  let (matSeq, ixs) = snpsNTMatSeq emissionsStart emissionsEnd sites  -- snpsNTMatSeq sites

  hPutStr stderr $ "evaluating siteMS: "
  hPutStrLn stderr $ show (trans matSeq # (100, 100))

  hPutStrLn stderr $ "subsampling emissions file with region size " ++ show (2 * softFlank + 1)
  --subsampledEmissionsFile <- emptySystemTempFile emissionsFile
  --putStrLn $ "using temporary subsampled emissions file: " ++ subsampledEmissionsFile

  --let subEmissions = siteEmissions softFlank numEvents emissionsStart emissionsEnd emissions site

  ps <- runHMMSum' ixs minionIndexMap emissions matSeq

  hPutStrLn stderr $ "results: " ++ intercalate "," (map show ps)

  return $ map probOfAlt ps


callSNP :: MatSeq (StateTree GenSNPState) -> Int -> Int -> Int -> Emissions -> Site NT -> IO [Prob]
callSNP genMS numEvents emissionsStart emissionsEnd emissions site = do
  --let (matSeq, ixs) = specifyGenMatSeqNT genMS site  -- snpsNTMatSeq sites
  let (matSeq, ixs) = snpsNTMatSeq emissionsStart emissionsEnd [site]  -- snpsNTMatSeq sites

  hPutStr stderr $ "evaluating genMS: "
  hPutStrLn stderr $ show (trans genMS # (100, 100))
  hPutStr stderr $ "evaluating siteMS: "
  hPutStrLn stderr $ show (trans matSeq # (100, 100))

  hPutStrLn stderr $ "subsampling emissions file with region size " ++ show (2 * softFlank + 1)
  --subsampledEmissionsFile <- emptySystemTempFile emissionsFile
  --putStrLn $ "using temporary subsampled emissions file: " ++ subsampledEmissionsFile

  let subEmissions = siteEmissions softFlank numEvents emissionsStart emissionsEnd emissions site

  ps <- runHMMSum' ixs minionIndexMap emissions matSeq

  hPutStrLn stderr $ "results: " ++ intercalate "," (map show ps)

  return $ map probOfAlt ps

instance Hashable a => Hashable (Vector a) where
  hashWithSalt = hashUsing V.toList

runHMMSum' :: [[Vector Int]]
           -> Map String Int
           -> Emissions
           -> MatSeq String
           -> IO [[Prob]]
runHMMSum' ixs indexMap emissions priorSeq = do
  let permutation = buildEmissionPerm indexMap priorSeq
      triples = matSeqTriples priorSeq
      ns = (nStates (trans priorSeq))
  sums <- SHMM.shmmSummed ns triples emissions permutation
  return $ map (map (sum . V.map (sums V.!))) ixs

runHMMSum :: [[Vector Int]]
          -> Map String Int
          -> Emissions
          -> MatSeq String
          -> IO [[Prob]]
runHMMSum ixs indexMap emissions priorSeq = mapIxs <$> runHMM indexMap emissions priorSeq
  where mapIxs post = map (map (\arr -> stateProbs arr post)) ixs

runHMM :: Map String Int
       -> Emissions
       -> MatSeq String
       -> IO Emissions
runHMM indexMap emissions priorSeq = SHMM.shmmFull (nStates (trans priorSeq)) triples emissions permutation
  where permutation = buildEmissionPerm indexMap priorSeq
        triples = matSeqTriples priorSeq

matSeqTriples :: MatSeq a
              -> [(Int, Int, Double)]
matSeqTriples = map (\((r, c), p) -> (r - 1, c - 1, p)) . tail . toAssocList . cleanTrans . trans

cleanTrans :: Trans -> Trans
cleanTrans = addStartColumn . collapseEnds

{-
callSNPs :: FilePath -> [Site NT] -> IO [Prob]
callSNPs emissionsFile sites = do
  let (matSeq, ixs) = specifyGenMatSeqNT (head sites)  -- snpsNTMatSeq sites

  putStrLn $ "done building " ++ show (V.length (stateLabels matSeq))
  post <- SHMM.runHMM minionIndexMap emissionsFile matSeq
  let ps = map (map (\arr -> stateProbs arr post)) ixs
  putStrLn $ "results: " ++ intercalate "," (map show ps)

  return $ map probOfAlt ps
-}

parseSite :: String -> Site NT
parseSite row = Site {
    alleles = [(ref, 1-maf), (alt, maf)]
  , pos = pos
  , leftFlank = leftFlank
  , rightFlank = rightFlank
  }
  where
    [read -> pos, [ref], [alt], (read::String->Double) -> maf, leftFlank, [ref'], rightFlank] = words row

{-
callSNP :: FilePath
        -> Site NT
        -> IO Prob
callSNP emissionsFile site = do
  let (ms, refIxs, altIxs) = snpMatSeq site
  --write this as a configuration file
  --print =<< sampleSeq vecDist ms
  --writeEmissionPerm minionIndexMap "emission_perm.csv" ms
  --writeSTFile ms "test_ex.st"
  post <- SHMM.runHMM minionIndexMap emissionsFile ms
  let refP = stateProbs refIxs post
      altP = stateProbs altIxs post
  return (altP / (refP + altP))
-}

stateProbs :: Vector Int -> Emissions -> Prob
stateProbs ixs emissions = sum . V.map (\row -> sum . V.map (row V.!) $ ixs) $ emissions

--main = compareSmall

  {-
compareMicrosatellites :: IO ()
compareMicrosatellites = do
  let satellite :: ProbSeq String
      satellite = series . map (\c -> state [c]) $ "ATTTA"
      genSeq = buildMatSeq . minion $ repeatSequence 15 satellite
      priorSeq = buildMatSeq . minion $ andThen
                    (repeatSequence 10 satellite)
                    (uniformDistRepeat 20 satellite)
      getRepeat :: ((Prob, (s, StateTag)) -> Maybe Int)
      getRepeat (_, (_, StateTag 1 [StateTag n _])) = Just n
      getRepeat _ = Nothing
  print =<< sampleSeq vecDist priorSeq
  print $ V.head $ stateLabels priorSeq

  compareHMM genSeq priorSeq getRepeat

compareSmall :: IO ()
compareSmall = do
  let genSeq = buildMatSeq $ repeatSequence 15 periodSeq
      priorSeq = buildMatSeq $ andThen
                    (repeatSequence 0 periodSeq)
        (uniformDistRepeat 20 periodSeq)
      f = getRepeat
  compareHMM genSeq priorSeq f

getRepeat :: ((Prob, (s, StateTag)) -> Maybe Int)
getRepeat (_, (_, StateTag 1 [StateTag n _])) = Just n
getRepeat _ = Nothing

compareHMM :: (Show s, Eq s)
           => MatSeq s
           -> MatSeq s
           -> ((Prob, (s, StateTag)) -> Maybe Int)
           -> IO ()
compareHMM genSeq priorSeq f = do
  (V.unzip -> (sample, sampleIxs), posterior, viterbi, forward, backward) <- runHMM genSeq priorSeq obsProb

  putStrLn $ "state labels:" ++ show sample
  putStrLn $ "state generating index:" ++ show sampleIxs

  putStrLn $ "truth: " ++ show (fromMaybe 0 $ f (undefined, stateLabels priorSeq V.! V.last sampleIxs))
  putStrLn $ "viterbi: " ++ show (fromMaybe 0 $ f (undefined, stateLabels priorSeq V.! V.last viterbi))
  let tags = pathProbs (stateLabels priorSeq) posterior
      post_dist = (distOver f $ V.last tags)
      max_post = fst $ maximumBy (compare `on` snd) post_dist
  putStrLn $ "max posterior: " ++ show max_post
  putStrLn "posterior dist: "
  mapM_ (\(ix, p) -> putStrLn $ show ix ++ ": " ++ show (fromRational p)) (distOver f $ V.last tags)
  let tags = pathProbs (stateLabels priorSeq) forward
      post_dist = (distOver f $ V.last tags)
      max_post = fst $ maximumBy (compare `on` snd) post_dist
  --putStrLn $ "max forward: " ++ show max_post
  --putStrLn "forward dist: "
  --mapM_ (\(ix, p) -> putStrLn $ show ix ++ ": " ++ show (fromRational p)) (distOver f $ V.last tags)
  let tags = pathProbs (stateLabels priorSeq) backward
      post_dist = (distOver f $ V.last tags)
      max_post = fst $ maximumBy (compare `on` snd) post_dist
  --putStrLn $ "max backward: " ++ show max_post
  --putStrLn "backward dist: "
  --mapM_ (\(ix, p) -> putStrLn $ show ix ++ ": " ++ show (fromRational p)) (distOver f $ V.last tags)
  --print priorSeq

  return ()
-}

obsProb :: (Eq s) => MatSeq s -> s -> IO (Vector Prob)
obsProb seq i = return . normalize . V.map (\(i', _) -> if i == i' then 1.0 else 0.0) . stateLabels $ seq

sampleCycleMatIxs :: IO (Vector Int)
sampleCycleMatIxs = fst <$> sampleSeqIxs vecDist cycleMatSeq

sampleCycleMatIxs' :: IO (Vector Int)
sampleCycleMatIxs' = fst <$> sampleSeqIxs vecDist cycleMatSeq'

sampleCycleMat :: IO (Vector Int)
sampleCycleMat = fst <$> sampleSeq vecDist cycleMatSeq

cycleMatSeq :: MatSeq Int
cycleMatSeq = buildMatSeq cycleSeq

cycleMatSeq' :: MatSeq Int
cycleMatSeq' = buildMatSeq cycleSeq'

cycleSeq' :: ProbSeq Int
cycleSeq' = repeatSequence n periodSeq

n = 15

cycleSeq :: ProbSeq Int
cycleSeq = andThen
  (repeatSequence nStart periodSeq)
  (uniformDistRepeat nEnd periodSeq)
  where nStart = 0
        nEnd = 20

periodSeq :: ProbSeq Int
periodSeq = series' . map (\v -> andThen (state v) skipDSeq) $
  [ 2, 1 ]

skipD :: [Prob]
skipD = [0.5, 1 - head skipD]

skipDSeq :: ProbSeq a
skipDSeq = finiteDistRepeat skipD $ skip 1

  -- runs out of memory between 8 and 16
  -- "62525746 G C 0.002396 CAGGAGCACC G GCCGCAGAGG"
testLines :: [String]
testLines = [
    "62525667 T C 0.3954 CCTTGGATGC T ACTGGGTTTG"
  , "62525746 G C 0.002396 CAGGAGCACC G GCCGCAGAGG"
  , "62525767 T A 0.0009984 TCTGGGAGCT T CTAGGATGGG"
  , "62525777 G C 0.09844 TCTAGGATGG G AAGTGGCCCA"
  , "62525782 G A 0.001198 GATGGGAAGT G GCCCAGGCAG"
  , "62525813 A G 0.0003994 GCAGGCCGTC A GTGAGTGGCG"
  , "62525990 G C 0.007788 TGGACAGGAA G GAAGGAAGGA"
  , "62526024 T G 0.4101 CGCTCCAGGG T TGAGCAAATG"
  , "62526065 G A 0.03035 CCGGGTGGGG G CGGGGGCGAC"
  , "62526134 T G 0.003994 ACGATTACGT T TTCTCAGTCT"
  , "62526155 G T 0.003994 TACTTAAAGC G CTGAGTAAAC"
  , "62526212 C A 0.005192 CTGCGCGGTT C CCCGCAGCAC"
  , "62526224 T C 0.03195 CCGCAGCACA T GGCGTGTCCA"
  , "62526334 C T 0.01418 CAGGGCGCCT C GGCCCCGGGC"
  , "62526352 C G 0.0003994 GGCTGTCACT C GGGACTCCGC"
  , "62526369 A G 0.000599 CCGCCCCTTC A TGGACGGAGC"
  --, "62526373 A G 0.01078 CCCTTCATGG A CGGAGCCTCC"
  --, "62526500 T T 0.00599 CGTGCTCGTC T CCGCTGCCGC"
  --, "62526500 T T 0.00599 CGTGCTCGTC T CCGCTGCCGC"
  --, "62526547 T T 0.08926 CCGCGCCCTC T GCCGCCGCCG"
  --, "62526547 T T 0.08926 CCGCGCCCTC T GCCGCCGCCG"
  --, "62526696 G A 0.04034 CTGCGGGTCG G GCGGGCGGAT"
  --, "62526719 G A 0.08187 GCCCACGTCA G GCCCGGGCAG"
  --, "62526801 G C 0.09784 CCCCCGGGCC G GGGCTGCGCG"
  --, "62526815 G T 0.001398 CTGCGCGGGC G CTCGGGGCCG"
  --, "62526818 C T 0.0007987 CGCGGGCGCT C GGGGCCGGAG"
  --, "62526898 G A 0.002796 TGCGGGAGCC G GGCCGGGCCG"
  --, "62527012 C T 0.01018 GCGGCCGCCC C CAACCCCCCG"
  --, "62527231 C T 0.02157 TTTATAAAAA C ATTTGAAGCC"
  --, "62527305 G A 0.09006 CTAACTTGTT G GTGTTAAGTG"
  --, "62527322 T A 0.002596 AGTGTCTGGA T TAAAGACTCT"
  --, "62527414 A C 0.000599 TTTCAGCTTT A TTTTTGTTTT"
  --, "62527427 G A 0.001997 TTTGTTTTCC G GCTTAGGCTT"
  --, "62527467 C T 0.002396 TGGTTAGACA C GTCTGCCCTT"
  ]
