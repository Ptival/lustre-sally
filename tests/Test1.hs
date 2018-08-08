{-# Language OverloadedStrings #-}
module Main where

import qualified Data.Map as Map
import Data.Text(Text)
import System.Process
import System.Directory
import System.IO
import System.Exit
import Control.Exception(finally)
import Text.PrettyPrint.ANSI.Leijen (vcat)
import Text.Show.Pretty(pPrint)

import qualified TransitionSystem as TS
import Sally
import Lustre
import Language.Lustre.Core

main :: IO ()
main = runTest (sys1, [q1,q2])

runTest :: (Node,  [TS.Expr]) -> IO ()
runTest (nd,qs) =
  do let ts = transNode nd
         inp = foldr (\e es -> ppSExpr e $ showChar '\n' es) "\n"
             $ translateTS ts ++ map (translateQuery ts) qs
     putStrLn "=== Sally Input: =============="
     putStrLn inp
     putStrLn "==============================="
     let opts = [ "--engine=pdkind", "--show-trace", "--output-language=mcmt" ]
     res <- sally "sally" opts inp
     case readSallyResults ts res of
       Right r  ->
          case traverse (traverse (importTrace nd)) r of
            Left err -> bad ("Failed to import trace: " ++ err) res
            Right as -> mapM_ pPrint as
       Left err -> bad ("Failed to parse result: " ++ err) res
  where
  bad err res =
    do putStrLn err
       putStrLn res
       exitFailure




sys1 :: Node
sys1 =
  Node { nName = Name "Test1"
       , nInputs = []
       , nOutputs = [ Ident "x"]
       , nAsserts = []
       , nEqns =
           [ Ident "y" ::: TInt := Pre (Var (Ident "x"))
           , Ident "p" ::: TInt := Call (Name "+")
                                      [ Lit (Int 1), Var (Ident "y") ]
           , Ident "x" ::: TInt := Lit (Int 1) :-> Var (Ident "p")
           ]
       }

q1 :: TS.Expr
q1 = x TS.:==: TS.Int 1
  where
  x = TS.InCurState TS.::: TS.Name "x"

q2 :: TS.Expr
q2 = x TS.:==: TS.Int 2
  where
  x = TS.InCurState TS.::: TS.Name "x"





