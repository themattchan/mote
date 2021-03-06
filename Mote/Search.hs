{-# LANGUAGE LambdaCase, NamedFieldPuns, RecordWildCards, TupleSections #-}

module Mote.Search
  ( transesInScope
  , WrappedType(..)
  , SyntacticFunc
  -- DEBUG
  , search
  , showTrans
  , traversables
  , monads
  , applicatives
  ) where

import           Mote.GhcUtil        (discardConstraints, splitPredTys)
import           Mote.ReadType
import           Mote.Refine         (tcRnExprTc)
import           Mote.Types
import           Mote.Util
import           Search.Graph
import           Search.Types

import           Control.Applicative
import           Control.Arrow       (first)
import           Control.Monad.Error
import           Data.Hashable
import qualified Data.List           as List
import           Data.Maybe
import qualified Data.Set            as Set

import           GHC
import           InstEnv             (ClsInst (..))
import           Name
import           Outputable
import qualified PrelNames
import           RdrName
import           Type                (dropForAlls, splitFunTys)
import           TypeRep
import           UniqSet             (elementOfUniqSet)
import           Unique              (getKey, getUnique)

{-
search stRef = do
  FileData {typecheckedModule} <- getFileDataErr stRef
  ahi@(AugmentedHoleInfo {holeInfo}) <- getCurrentHoleErr stRef 
  suggs <- getAndMemoizeSuggestions stRef ahi
  (sug, startTy) <- headErr suggs
  let goalTy = holeType holeInfo
  return $ go _ startTy goalTy
  where
  go transes startTy goalTy  =
    let (startFs, _) = extractFunctors startTy
        (goalFs, _)  = extractFunctors goalTy
    in
    programsOfLengthAtMost transes 6 startFs goalFs
-}

-- Write a type t as (A1 * ... * An)F where
-- each Ai and F are functors over a variable x

-- Checks if the type can be thought of as being of the form
-- forall a. F a -> G a
-- perhaps after partially applying.
-- (Of course F and G could be constant functors...but we don't
-- consider that case now. Maybe later, I guess there's no reason
-- not to.)
-- So, we are looking for types of the form
-- forall a. _ -> ... -> _ -> F a -> _ -> ... -> G a
-- It's really not unique since we can view 
-- forall a. F1 a -> F2 a -> G a as
-- F1 -> G
-- F2 -> G
-- (F1 * F2) -> G
--
-- either :: (a -> c) -> (b -> c) -> Either a b -> c
--  (^a * ^b) -> 1        (partially apply the Either argument)
--  (^a * ^b) -> ^(a + b) (don't partially apply the either argument
--

-- TODO: SyntacticFuncs should be bundled with the variables that they're
-- universally quantified over
type SyntacticFunc = (TyCon, [WrappedType])
data TransInterpretation = TransInterpretation
  { numArguments            :: Int
  , functorArgumentPosition :: Int
  , name                    :: Name
  , from                    :: [SyntacticFunc]
  , to                      :: [SyntacticFunc]
  }

showTrans :: Trans SyntacticFunc -> M String
showTrans (Trans {from, to, name}) = do
  from' <- lift $ mapM showPprM from
  to' <- lift $ mapM showPprM to
  return (show $ Trans {from=from', to=to', name})

data CoarseType
  = SomeVar
  | Type WrappedType
  deriving (Eq, Ord)

-- Heuristically ignore distinctions between all TyVars
-- since comparing types gets complicated with TyVars
type CoarseFunc = (TyCon, [CoarseType])

squint :: SyntacticFunc -> CoarseFunc
squint (tc, ts) = (tc, map squintTy ts) where
  squintTy (WrappedType t) = case t of
    TyVarTy _v     -> SomeVar
    _              -> Type (WrappedType t)

-- Filtering occurs here
transes :: Set.Set CoarseFunc -> (Name, Type) -> [Trans SyntacticFunc]
transes funcs b = mapMaybe toTrans (transInterpretations b)
  where
  toTrans :: TransInterpretation -> Maybe (Trans SyntacticFunc)
  toTrans (TransInterpretation {..}) =
    if any (\f -> not $ Set.member (squint f) funcs) from ||
       any (\f -> not $ Set.member (squint f) funcs) to
    then Nothing
    else if from == to
    then Nothing
    else if numArguments > 3 then Nothing
    else Just (Trans {from, to, name=AnnotatedTerm name' (numArguments - 1)})
    where
    ident = occNameString $ occName name
    name' =
      if numArguments == 1 
      then Simple ident 
      else if functorArgumentPosition == numArguments - 1
      then Compound (ident ++ " " ++ underscores (numArguments - 1))
      else Simple ("(\\x -> " ++ ident ++ " " ++ underscores functorArgumentPosition ++ " x " ++ underscores (numArguments - functorArgumentPosition - 1) ++ ")")

    underscores n = unwords $ replicate n "_"

traversables :: GhcMonad m => m [SyntacticFunc]
traversables = instancesOneParamFunctorClass PrelNames.traversableClassName

monads :: GhcMonad m => m [SyntacticFunc]
monads = instancesOneParamFunctorClass PrelNames.monadClassName

applicatives :: GhcMonad m => m [SyntacticFunc]
applicatives = instancesOneParamFunctorClass PrelNames.applicativeClassName

functors :: GhcMonad m => m [SyntacticFunc]
functors = instancesOneParamFunctorClass PrelNames.functorClassName

instancesOneParamFunctorClass name =
  getInfo False name >>| \case
    Just (_,_,insts,_) -> mapMaybe (extractUnapplied . head . is_tys) insts
    Nothing            -> []

extractUnapplied :: Type -> Maybe SyntacticFunc
extractUnapplied t = case t of
  TyConApp tc kots -> Just (tc, map WrappedType kots)
  -- TODO: In the future, this should extract applications of type
  -- variables
  _                -> Nothing

-- TODO: This type is only for debug purposes
data WrappedTyCon = WrappedTyCon TyCon String
instance Eq WrappedTyCon where
  WrappedTyCon tc _ == WrappedTyCon tc' _ = tc == tc'
instance Ord WrappedTyCon where
  compare (WrappedTyCon x _) (WrappedTyCon y _) = compare x y
instance Hashable WrappedTyCon where
  hashWithSalt s (WrappedTyCon tc _) = s `hashWithSalt` getKey (getUnique tc)
instance Show WrappedTyCon where
  show (WrappedTyCon _ s) = show s

-- search :: [String] -> [String] -> Int ->  M [NaturalGraph (Int, Int)]
search src trg n = do
  let renderSyntacticFunc (tc, args) = (getKey (getUnique tc), hash args)
--  let showSyntacticFunc = showSDoc fs . ppr
--  let renderSyntacticFunc sf@(tc, args) = WrappedTyCon tc (showSyntacticFunc sf)
  from    <- fmap catMaybes $ mapM (fmap (fmap renderSyntacticFunc . extractUnapplied . dropForAlls) . readType) src
  to      <- fmap catMaybes $ mapM (fmap (fmap renderSyntacticFunc . extractUnapplied . dropForAlls) . readType) trg
  transes <- fmap (fmap (fmap renderSyntacticFunc)) transesInScope
  return $ graphsOfSizeAtMost transes n from to

transesInScope :: M [Trans SyntacticFunc]
transesInScope = do
  namedTys <- fmap catMaybes . mapM typeName =<< lift getNamesInScope
  ts <- lift traversables
  as <- lift applicatives
  ms <- lift monads
  funcSet <- lift $ fmap (Set.fromList . map squint) functors
  let joins     = map (\m -> Trans { from = [m,m], to = [m], name = AnnotatedTerm (Simple "join") 0 }) ms
      traverses = liftA2 (\t f -> Trans { from = [t,f], to = [f,t], name = AnnotatedTerm (Simple "sequenceA") 0 }) ts as
  return $
    concatMap (transes funcSet) namedTys ++ traverses ++ joins
  where
  typeName n = do
    hsc_env <- lift getSession
    (_errs, mayTy) <- liftIO $
      runTcInteractive hsc_env . discardConstraints . tcRnExprTc . noLoc . HsVar . Exact $ n
    return $ fmap (n,) mayTy

-- TODO: Turn SyntacticFunc into SyntacticFuncScheme
-- so runErrorT can work
extractFunctors :: Type -> ([SyntacticFunc], WrappedType)
extractFunctors t = case t of
  TyVarTy _v       -> ([], WrappedType t)
  FunTy _ _        -> ([], WrappedType t)
  ForAllTy _v t    -> extractFunctors t
  LitTy _          -> ([], WrappedType t)
  AppTy t _t'      -> ([], WrappedType t) -- TODO
  TyConApp tc kots -> case splitLast kots of
    Nothing          -> ([], WrappedType t)
    Just (args, arg) -> first ((tc, map WrappedType args) :) (extractFunctors arg)
  where
  splitLast' :: [a] -> ([a], a)
  splitLast' [x]    = ([], x)
  splitLast' (x:xs) = first (x:) (splitLast' xs)
  splitLast' _      = error "Mote.Search.splitLast': Impossible"

  splitLast :: [a] -> Maybe ([a], a)
  splitLast [] = Nothing
  splitLast xs = Just (splitLast' xs)

-- TODO: This is, of course, a first approximation since
-- we assume all TyCons other than (->) are covariant in all
-- arguments.
occursStrictlyPositively :: TyVar -> Type -> Bool
occursStrictlyPositively v = not . bad where
  bad t = case t of
    AppTy t' t''      -> bad t' || bad t''
    TyConApp _tc kots -> any bad kots
    FunTy t' t''      -> occurs t' || bad t''
    ForAllTy _ t'     -> bad t'
    LitTy _tl         -> False
    TyVarTy _v        -> False

  occurs t = case t of
    AppTy t' t''      -> occurs t' || occurs t''
    TyConApp _tc kots -> any occurs kots
    FunTy t' t''      -> occurs t' || occurs t''
    ForAllTy _v t'    -> occurs t'
    LitTy _tl         -> False
    TyVarTy v'        -> v' == v

transInterpretations :: (Name, Type) -> [TransInterpretation]
transInterpretations (n, t0) =
  case targInner of
    WrappedType (TyVarTy polyVar) ->
      if polyVar `elementOfUniqSet` forbiddenVars
      then []
      else if any (not . occursStrictlyPositively polyVar) args
      then []
      else catMaybes $ zipWith interp [0..] args
      where
      interp :: Int -> Type -> Maybe TransInterpretation
      interp i argty =
        if inner == targInner
        then Just trans
        else Nothing
        where
        (sfs, inner) = extractFunctors argty
        trans        = TransInterpretation
          { numArguments            = numArguments
          , functorArgumentPosition = i
          , name                    = n
          , from                    = sfs
          , to                      = sfsTarg
          }

    _ -> []
  where
  (_polyVars, t1)      = splitForAllTys t0
  (predTys, t)         = splitPredTys t1
  forbiddenVars        = tyVarsOfTypes predTys
  (args, targ)         = splitFunTys t
  (sfsTarg, targInner) = extractFunctors targ
  numArguments         = length args

newtype WrappedType = WrappedType Type
instance Eq WrappedType where
  (==) (WrappedType t) (WrappedType t') = eqTy t t'

instance Ord WrappedType where
  compare (WrappedType t) (WrappedType t') = compareTy t t'

instance Outputable WrappedType where
  ppr (WrappedType t) = ppr t
  pprPrec r (WrappedType t) = pprPrec r t

-- Hacky syntactic equality for Type so that it can be used as the functor
-- parameter in all the Search types
eqTy :: Type -> Type -> Bool
eqTy x y = case (x, y) of
  (AppTy t1 t2, AppTy t1' t2')           -> eqTy t1 t1' && eqTy t2 t2'
  (TyConApp tc kots, TyConApp tc' kots') -> tc == tc' && and (zipWith eqTy kots kots')
  (FunTy t1 t2, FunTy t1' t2')           -> eqTy t1 t1' && eqTy t2 t2'
  (ForAllTy v t, ForAllTy v' t')         -> v == v' && eqTy t t'
  (LitTy tl, LitTy tl')                  -> tl == tl'
  (TyVarTy v, TyVarTy v')                -> v == v'
  _                                      -> False

instance Hashable WrappedType where
  hashWithSalt s (WrappedType t) = hashTypeWithSalt s t

hashTypeWithSalt :: Int -> Type -> Int
hashTypeWithSalt s t = case t of
  TyVarTy v        -> s `hashWithSalt` (0::Int) `hashWithSalt` getKey (getUnique v)
  AppTy t t'       -> s `hashWithSalt` ((1::Int) `hashTypeWithSalt` t) `hashTypeWithSalt` t'
  TyConApp tc kots -> List.foldl' hashTypeWithSalt (s `hashWithSalt` (2::Int) `hashWithSalt` getKey (getUnique tc)) kots
  FunTy t t'       -> s `hashWithSalt` (3::Int) `hashTypeWithSalt` t `hashTypeWithSalt` t'
  ForAllTy v t     -> s `hashWithSalt` ((4::Int) `hashWithSalt` getKey (getUnique v)) `hashTypeWithSalt` t
  LitTy tl         -> s `hashWithSalt` (5::Int) `hashTyLitWithSalt` tl

hashTyLitWithSalt s tl = case tl of
  NumTyLit n  -> s `hashWithSalt` n
  StrTyLit fs -> s `hashWithSalt` getKey (getUnique fs)

compareTy :: Type -> Type -> Ordering
compareTy = \x y -> case compare (conOrd x) (conOrd y) of
  EQ ->
    case (x, y) of
      (AppTy t1 t2, AppTy t1' t2') ->
        lex [compareTy t1 t1', compareTy t2 t2']

      (TyConApp tc kots, TyConApp tc' kots') ->
        lex (compare tc tc' : zipWith compareTy kots kots')

      (FunTy t1 t2, FunTy t1' t2') ->
        lex [compareTy t1 t1', compareTy t2 t2']

      (ForAllTy v t, ForAllTy v' t') ->
        lex [compare v v', compareTy t t']

      (LitTy tl, LitTy tl') -> compare tl tl'

      (TyVarTy v, TyVarTy v') -> compare v v'

      _ -> error "Mote.Search.compareTy: Impossible"

  o -> o
  where
  conOrd :: Type -> Int
  conOrd x = case x of
    TyVarTy {}  -> 0
    AppTy {}    -> 1
    TyConApp {} -> 2
    FunTy {}    -> 3
    ForAllTy {} -> 4
    LitTy {}    -> 5

  lex :: [Ordering] -> Ordering
  lex = (\case { [] -> EQ; (o:_) -> o } ) . dropWhile (== EQ)
{-
TyConApp IO
  [TyConApp Free
    [ TyConApp "[]" []
    , TyConApp Maybe [TyConApp Int]
    ]
  ]
-}
