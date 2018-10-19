{-# Language OverloadedStrings #-}
module Main(main) where

import System.Exit(exitFailure)
import Control.Monad(when,zipWithM_)
import Control.Exception(catch, SomeException(..), displayException)
import Data.Text(Text)
import qualified Data.Text as Text
import qualified Data.Map as Map
import SimpleGetOpt
import Text.PrettyPrint as P ((<>), (<+>),nest,colon,integer,($$),vcat)

import Language.Lustre.Parser
import Language.Lustre.AST
import Language.Lustre.Core(nShows)
import Language.Lustre.Pretty
import Language.Lustre.Transform.Desugar(desugarNode)
import Sally
import LustreNoNil

data Settings = Settings
  { file    :: FilePath
  , node    :: Text
  , engine  :: String
  }

options :: OptSpec Settings
options = OptSpec
  { progDefaults = Settings { file = "", node = "", engine = "bmc" }
  , progOptions =

      [ Option ['n'] ["node"]
          "Translate this node."
          $ ReqArg "IDENT" $ \a s ->
              if node s == ""
                then Right s { node = Text.pack a }
                else Left "Multiple nodes.  For the moment we support only one."

      , Option ['f'] ["file"]
        "Lustre file."
        $ ReqArg "FILE" $ \a s ->
          if file s == ""
              then Right s { file = a }
              else Left "Multiple files.  For now we support just one Lust file"

      , Option ['e'] ["engine"]
        "Which model-checking engine to use (see sally for options)."
        $ ReqArg "ENGINE" $ \a s -> Right s { engine = a }
      ]

  , progParamDocs = []
  , progParams    = \a _ -> Left ("Unexpected parameter: " ++ show a)
  }

main :: IO ()
main =
  do settings <- getOpts options
     when (file settings == "") $
       reportUsageError options ["No Lustre file was speicifed."]

     a <- parseProgramFromFileLatin1 (file settings)
     case a of
       ProgramDecls ds -> mainWork settings ds
       _ -> fail "XXX: We don't support modules/packages for the moment."

  `catch` \(SomeException e) ->
            do putStrLn ("[FAIL] " ++ displayException e)
               exitFailure

fakeIdent :: Text -> Ident
fakeIdent x = Ident { identText    = x
                    , identPragmas = []
                    , identRange   = fakeRange
                    }
  where
  fakePos   = SourcePos 0 0 0 ""
  fakeRange = SourceRange fakePos fakePos

mainWork :: Settings -> [TopDecl] -> IO ()
mainWork settings ds =
  do putStrLn "Core Lustre"
     putStrLn "==========="
     putStrLn ""
     let nm = if node settings == ""
                  then Nothing
                  else Just (Unqual (fakeIdent (node settings)))
         nd = desugarNode ds nm
     print (pp nd)
     putStrLn ""

     putStrLn "Sally Model"
     putStrLn "==========="
     putStrLn ""
     let (ts,qs) = transNode nd   -- transition system and queries
         inp = foldr (\e es -> ppSExpr e $ showChar '\n' es) "\n"
             $ translateTS ts ++ map (translateQuery ts) qs
     putStrLn inp
     putStrLn ""

     putStrLn "Invoking Sally"
     putStrLn "=============="
     putStrLn ""
     let opts = [ "--engine=" ++ engine settings
                , "--show-trace"
                , "--output-language=mcmt" ]
     putStrLn "Sally options:"
     print opts
     res <- sally "sally" opts inp
     case readSallyResults ts res of
       Right r  ->
          case traverse (traverse (importTrace nd)) r of
            Left err -> bad ("Failed to import trace: " ++ err) res
            Right as -> zipWithM_ printResult (nShows nd) as
       Left err -> bad ("Failed to parse result: " ++ err) res
  where
  bad err res =
    do putStrLn err
       putStrLn res
       exitFailure

  printResult q r =
    do putStr (showPP q ++ ": ")
       case r of
         Valid     -> putStrLn "valid"
         Unknown   -> putStrLn "unknown"
         Invalid t ->
           do putStrLn "invalid:"
              putStrLn "Initial state:"
              print (ppState (traceStart t))
              putStrLn "Inputs:"
              zipWithM_ printInputs [1..] (map fst (traceSteps t))

  ppState = ppIns

  printInputs n m = print ( ("Step" <+> integer n P.<> colon)
                            $$ nest 2 (ppIns m))

  ppIns = vcat . map ppIn . Map.toList
  ppIn (x,y) = pp x <+> "=" <+> pp y






