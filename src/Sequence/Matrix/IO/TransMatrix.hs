{-# LANGUAGE OverloadedStrings #-}
module Sequence.Matrix.IO.TransMatrix where

import qualified Data.Vector as V
import Data.Vector (Vector)

import Sequence.Matrix.Types
import qualified Math.LinearAlgebra.Sparse as M

import Data.Monoid ((<>))
import Data.List
import Data.Text (Text, pack)
import Data.Attoparsec.Text
import Data.Ratio ((%))

showTrans :: Trans
          -> [Text]
showTrans = map showTriple . M.toAssocList
  where showTriple ((r, c), v) = mconcat . intersperse " " $ [
            pack (show r)
          , pack (show c)
          , "(" <> pack (show v) <> ")"
          ]

parseTrans :: Parser (Trans)
parseTrans = M.fromAssocList <$> (parseTransTriple `sepBy` endOfLine)

parseTransTriple :: Parser ((Int, Int), Prob)
parseTransTriple = do
  row <- decimal
  _ <- char ' '
  col <- decimal
  _ <- char ' '
  val <- parseProb
  return ((row, col), val)

parseProb :: Parser Prob
parseProb = choice [
    do _ <- char '('
       num <- decimal
       _ <- string " % "
       den <- decimal
       _ <- char ')'
       return $ num % den
  , rational
  ]
