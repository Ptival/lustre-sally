{-# Language OverloadedStrings, PatternSynonyms #-}
-- | Translate Core Lustre to a transtion system.
-- In this translation there are no explicit `nil` values, instead
-- such values are modelled as arbitrary unconstrained values of
-- the appropriate type.
module Lustre (transNode, transProp, importTrace, LTrace) where

import qualified Data.Text as Text
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Maybe(mapMaybe)
import           Data.Char(isAscii,isAlpha,isDigit)

import qualified TransitionSystem as TS


import Language.Lustre.AST(PropName)
import Language.Lustre.Core
import qualified Language.Lustre.Semantics.Core as L
import Language.Lustre.Pretty(showPP)
import LSPanic

transNode :: Node -> (TS.TransSystem, [(PropName,TS.Expr)])
transNode n = (ts, map mkProp (nShows n))
  where
  mkProp (x,p) = (x, transProp TS.InCurState p)

  env = nodeEnv n

  ts = TS.TransSystem
         { TS.tsVars    = Map.unions (inVars : otherVars :map declareEqn (nEqns n))
         , TS.tsInputs  = inVars
         , TS.tsInit    = initNode n
         , TS.tsTrans   = stepNode env n
         }

  inVars    = Map.unions (map declareVar (nInputs n))
  otherVars = declareVarInitializing


type Env = Map Ident CType
type Val = TS.Expr
type TVal = (Val,Type)

-- | Literals are not nil.
valLit :: Literal -> Val
valLit lit = case lit of
               Int n  -> TS.Int n
               Bool b -> TS.Bool b
               Real r -> TS.Real r

-- | The logical variable for the ordinary value.
valName :: Ident -> TS.Name
valName (Ident x)
  | Text.all simp x = TS.Name x
  | otherwise       = TS.Name ("|" <> x <> "|")
  where simp a = isAscii a && (isAlpha a || isDigit a)

-- | For variables defined by @a -> b@, keeps track if we are in the @a@
-- (value @true@) or in the @b@ part (value @false@).
initName :: Ident -> TS.Name
initName (Ident x) = TS.Name ("|" <> x <> "-init|")

-- | Translate an atom, by using the given name-space for variables.
valAtom :: Env -> TS.VarNameSpace -> Atom -> Val
valAtom env ns atom =
  case atom of
    Lit l     -> valLit l
    Var a     -> ns TS.::: valName a
    Prim f as -> primFun f (map evT as)
      where evT a = (valAtom env ns a, typeOfCType (typeOf env a))

-- | A boolean variable which is true in the very first state,
-- beofre we've received any inputs, and false after-wards..
-- We use it to avoid checking queries in the very first state
varInitializing :: TS.Name
varInitializing = TS.Name "|gal-initializing|"



{- Note: Handling Inputs
   =====================

In Sally, inputs live in a separate name space, and are an input to
the transition relation.  So to translate something like @pre x@ where
@x@ is an input, we need a new local variable that will store the old
value for @x@.  To make things uniform, we introduce one local variable
per input: in this way, accessing variables is always done the same way
(@pre x@ is @current.x@ and @x@ is @next.x@).
-}


--------------------------------------------------------------------------------
-- Syntactic sugar for making TS expressions.

true, false :: TS.Expr
true  = TS.Bool True
false = TS.Bool False

-- | And tigether multiple boolean expressions.
ands :: [TS.Expr] -> TS.Expr
ands as =
  case as of
    [] -> true
    _  -> foldr1 (TS.:&&:) as



-- | Equations asserting that a varible from some namespace has the given value.
setVals :: TS.VarNameSpace -> Ident -> Val -> TS.Expr
setVals ns x v = ns TS.::: (valName x) TS.:==: v

-- | Properties get translated into queries.
-- We are not interested in validating the initial state, which is
-- full of indetermined values.
transProp :: TS.VarNameSpace -> Ident -> TS.Expr
transProp ns i = (ns TS.::: varInitializing) TS.:||: transBool ns i

-- | Properties get translated into queries. @nil@ is treated as @False@.
-- We are not interested in validating the initial state, which is
-- full of @nil@.
transBool :: TS.VarNameSpace -> Ident -> TS.Expr
transBool ns i = ns TS.::: valName i



--------------------------------------------------------------------------------



--------------------------------------------------------------------------------
-- Declaring variables
transType :: Type -> TS.Type
transType ty =
  case ty of
    TInt  -> TS.TInteger
    TBool -> TS.TBool
    TReal -> TS.TReal

-- | Declare all parts of a variable.
-- See "NOTE: Translating Variables"
declareVar :: Binder -> Map TS.Name TS.Type
declareVar (x ::: t `On` _) = Map.singleton (valName x) (transType t)

-- | Local variables.
declareEqn :: Eqn -> Map TS.Name TS.Type
declareEqn (x@(v ::: _) := e) = case e of
                        _ :-> _ -> Map.insert (initName v) TS.TBool mp
                        _ -> mp
  where mp = declareVar x


-- | Keep track if we are in the initial state.
declareVarInitializing :: Map TS.Name TS.Type
declareVarInitializing = Map.singleton varInitializing TS.TBool
--------------------------------------------------------------------------------



-- | Initial state for a node. All variable start off as indeterminate.
initNode :: Node -> TS.Expr
initNode n = ands (setInit : mapMaybe initS (nEqns n))
  where
  initS ((v ::: _) := e) =
    case e of
      _ :-> _ -> Just ((TS.InCurState TS.::: initName v) TS.:==: true)
      _ -> Nothing

  setInit = TS.InCurState TS.::: varInitializing TS.:==: true

stepNode :: Env -> Node -> TS.Expr
stepNode env n =
  ands $ ((TS.InNextState TS.::: varInitializing) TS.:==: false) :
         map (stepInput env) (nInputs n) ++
         map (transBool TS.InNextState . snd) (nAssuming n) ++
         map (stepEqn env) (nEqns n)

-- XXX: clocks?
stepInput :: Env -> Binder -> TS.Expr
stepInput env (x ::: _) = setVals TS.InNextState x a
  where a = valAtom env TS.FromInput (Var x)

stepEqn :: Env -> Eqn -> TS.Expr
stepEqn env (x ::: _ `On` c := expr) =
  case expr of
    Atom a      -> new a
    Current a   -> new a
    Pre a       -> guarded (old a)
    a `When` _  -> guarded (new a)

    a :-> b     ->
      case clockOn of
        Nothing -> clockYes
        Just g ->
          TS.ITE g
            clockYes
            (old (Var x) TS.:&&: ivar TS.InNextState TS.:==: ivar TS.InCurState)
      where
      ivar n = n TS.::: initName x
      clockYes = (TS.ITE (ivar TS.InCurState) (new a) (new b)
                    TS.:&&: ivar TS.InNextState TS.:==: false)

    Merge a ifT ifF -> guarded (TS.ITE a' (new ifT) (new ifF))
      where a' = atom a


  where
  atom    = valAtom env TS.InNextState
  old     = letVars . valAtom env TS.InCurState
  new     = letVars . atom
  letVars = setVals TS.InNextState x

  guarded e = case clockOn of
                Nothing -> e
                Just g  -> TS.ITE g e (old (Var x))

  clockOn = case c of
              Lit (Bool True) -> Nothing -- base clocks
              _ -> Just (atom c)



-- | Translation of primitive functions.
primFun :: Op -> [TVal] -> Val
primFun op as =
  case (op,as) of
    (Neg, [(a,_)])    -> TS.Neg a
    (Not, [(a,_)])    -> TS.Not a

    (And, _)          -> bool2 (TS.:&&:)
    (Or,  _)          -> bool2 (TS.:||:)
    (Xor, _)          -> bool2 (TS.:/=:)
    (Implies, _)      -> bool2 (TS.:=>:)

    (Add, [(a,_),(b,_)])      -> a TS.:+: b
    (Sub, [(a,_),(b,_)])      -> a TS.:-: b
    (Mul, [(a,_),(b,_)])      -> a TS.:*: b
    (Mod, [(a,_),(b,_)])      -> TS.Mod a b
    (Div, [(a,ta),(b,tb)])    ->
      case (ta, tb) of
        (TInt,TInt)           -> TS.Div a b
        (TReal,TReal)         -> a TS.:/: b
        _ -> panic "primFun(Div)" ["Don't know how to divide"
                                  , showPP ta, showPP tb ]

    (Eq,  _)          -> rel (TS.:==:)
    (Neq, _)          -> rel (TS.:/=:)
    (Lt,  _)          -> rel (TS.:<:)
    (Leq, _)          -> rel (TS.:<=:)
    (Gt,  _)          -> rel (TS.:>:)
    (Geq, _)          -> rel (TS.:>=:)

    (IntCast, [(a,_)]) -> TS.ToInt a
    (RealCast, [(a,_)])-> TS.ToReal a

    (AtMostOne, _)    -> mkAtMostOne
    (Nor, _)          -> case as of
                           []  -> true
                           _   -> TS.Not (foldr1 (TS.:||:) (map fst as))

    (ITE, [(a,_),(b,_),(c,_)])    -> TS.ITE a b c

    _ -> error ("XXX: " ++ show op)

  where
  bool2 f = case as of
              [(a,_),(b,_)] -> f a b
              _ -> panic "primFun" ["Invalid bool2"]

  rel f = case as of
            [(a,_),(b,_)] -> f a b
            _ -> panic "primFun" ["Invalid rel"]

  mkAtMostOne = case as of
                  [] -> true
                  _  -> atMostOneVal as

  norVal xs = case xs of
                [] -> true
                _  -> TS.Not (foldr1 (TS.:||:) (map fst xs))

  atMostOneVal vs =
    case vs of
      []     -> true
      [_]    -> true
      [(a,_),(b,_)]  -> a TS.:=>: TS.Not b
      (a,_) : bs -> TS.ITE a (norVal bs) (atMostOneVal bs)



--------------------------------------------------------------------------------
-- Importing of Traces


type ImportError = String

-- | Fail to import something
importError :: [String] -> Either ImportError a
importError = Left . unlines

-- | Import a Lustre identifier from the given assignment computed by Sally.
-- See "Translating Variables" for details of what's going on here.
importVar :: TS.VarVals -> Ident -> Either ImportError L.Value
importVar st i =
  case Map.lookup vaName st of
    Just v -> pure $ case v of
                       TS.VInt x  -> L.VInt x
                       TS.VBool x -> L.VBool x
                       TS.VReal x -> L.VReal x
    Nothing -> missing vaName
  where
  vaName = valName i

  missing x = importError [ "[bug] Missing assignment"
                          , "*** Variable: " ++ show x
                          ]

-- | Import a bunch of core Lustre identifiers from a state.
importVars :: Set Ident -> TS.VarVals -> Either ImportError (Map Ident L.Value)
importVars vars st =
  do let is = Set.toList vars
     steps <- mapM (importVar st) is
     pure (Map.fromList (zip is steps))


importState :: Node -> TS.VarVals -> Either ImportError (Map Ident L.Value)
importState n = importVars $ Set.fromList
                           $ [ x | x ::: _ <- nInputs n ] ++
                             {- Inputs are shadowed in the state -}
                             [ x | x ::: _ := _ <- nEqns n ]

importInputs :: Node -> TS.VarVals -> Either ImportError (Map Ident L.Value)
importInputs n = importVars $ Set.fromList [ x | x ::: _ <- nInputs n ]

type LTrace = TS.Trace {-state-} (Map Ident L.Value)
                       {-inputs-}(Map Ident L.Value)

importTrace :: Node -> TS.TSTrace -> Either ImportError LTrace
importTrace n tr =
  case tr of
    TS.Trace { TS.traceStart = start, TS.traceSteps = steps } ->
      do start1 <- importState n start
         steps1 <- mapM impStep steps
         pure TS.Trace { TS.traceStart = start1, TS.traceSteps = steps1 }
  where
  impStep (i,s) =
    do i1 <- importInputs n i
       s1 <- importState n s
       return (i1,s1)




