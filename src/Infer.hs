{-# LANGUAGE LambdaCase, TemplateHaskell, DataKinds, FlexibleContexts #-}

module Infer (inferTopDefs) where

import Prelude hiding (span)
import Control.Lens ((<<+=), assign, makeLenses, over, use, view, views, mapped)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Bifunctor
import Data.Graph (SCC(..), stronglyConnComp)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)

import Misc
import SrcPos
import FreeVars
import Subst
import qualified Ast
import Ast (Id(..), IdCase(..), idstr, scmBody, isFunLike)
import TypeErr
import AnnotAst hiding (Id)


newtype ExpectedType = Expected Type
data FoundType = Found SrcPos Type

data Env = Env
    { _envDefs :: Map String Scheme
    -- | Maps a constructor to its variant index in the type definition it
    --   constructs, the signature/left-hand-side of the type definition, the
    --   types of its parameters, and the span (number of constructors) of the
    --   datatype
    , _envCtors :: Map String (VariantIx, (String, [TVar]), [Type], Span)
    }
makeLenses ''Env

data St = St
    { _tvCount :: Int
    , _substs :: Subst
    }
    deriving (Show)
makeLenses ''St

type Infer a = ReaderT Env (StateT St (Except TypeErr)) a


inferTopDefs
    :: Ctors
    -> [Ast.Extern]
    -> [Ast.Def]
    -> Except TypeErr (Externs, Defs, Subst)
inferTopDefs ctors externs defs = evalStateT
    (runReaderT inferTopDefs' initEnv)
    initSt
  where
    inferTopDefs' = augment envCtors ctors $ do
        externs' <- checkExterns externs
        let externs'' = fmap (Forall Set.empty) externs'
        defs' <- checkStartType defs
        defs'' <- augment envDefs externs'' (inferDefs defs')
        -- We run this separately from checkStartType to be able to run
        -- inferDefs first. Being able to check a module for type errors even if
        -- it won't compile in the end is useful.
        checkStartDefined defs''
        s <- use substs
        pure (externs', defs'', s)
    checkStartType = \case
        (x@(Id (WithPos _ "start")), (s, b)) : ds ->
            if s == Nothing || unpos (fromJust s) == startScheme
                then pure
                    ((x, (Just (WithPos dummyPos startScheme), b)) : ds)
                else throwError (WrongStartType (fromJust s))
        d : ds -> fmap (d :) (checkStartType ds)
        [] -> pure []
    checkStartDefined ds =
        when (not (Map.member "start" ds)) (throwError StartNotDefined)
    startScheme = Forall Set.empty startType
    initEnv = Env { _envDefs = Map.empty, _envCtors = Map.empty }
    initSt = St { _tvCount = 0, _substs = Map.empty }

-- TODO: Check that the types of the externs are valid more than just not
--       containing type vars. E.g., they may not refer to undefined types, duh.
checkExterns :: [Ast.Extern] -> Infer Externs
checkExterns = fmap Map.fromList . mapM checkExtern
  where
    checkExtern (Ast.Extern name t) = case Set.lookupMin (ftv t) of
        Just tv -> throwError (ExternNotMonomorphic name tv)
        Nothing -> pure (idstr name, t)

inferDefs :: [Ast.Def] -> Infer Defs
inferDefs defs = do
    let ordered = orderDefs defs
    inferDefsComponents ordered

-- For unification to work properly with mutually recursive functions,
-- we need to create a dependency graph of non-recursive /
-- directly-recursive functions and groups of mutual functions. We do
-- this by creating a directed acyclic graph (DAG) of strongly
-- connected components (SCC), where a node is a definition and an
-- edge is a reference to another definition. For each SCC, we infer
-- types for all the definitions / the single definition before
-- generalizing.
orderDefs :: [Ast.Def] -> [SCC Ast.Def]
orderDefs = stronglyConnComp . graph
    where graph = map (\d@(n, _) -> (d, n, Set.toList (freeVars d)))

inferDefsComponents :: [SCC Ast.Def] -> Infer Defs
inferDefsComponents = \case
    [] -> pure Map.empty
    (scc : sccs) -> do
        let (verts, isCyclic) = case scc of
                AcyclicSCC vert -> ([vert], False)
                CyclicSCC verts' -> (verts', True)
        let (idents, rhss) = unzip verts
        let (mayscms, bodies) = unzip rhss
        checkUserSchemes (catMaybes mayscms)
        let mayscms' = map (fmap unpos) mayscms
        let names = map idstr idents
        ts <- replicateM (length names) fresh
        let scms = map
                (\(mayscm, t) -> fromMaybe (Forall Set.empty t) mayscm)
                (zip mayscms' ts)
        forM_ (zip idents bodies) $ \(Id name, body) ->
            when (not (isFunLike body) && isCyclic)
                $ throwError (RecursiveVarDef name)
        bodies' <-
            withLocals (zip names scms)
            $ forM (zip bodies scms)
            $ \(body, Forall _ t1) -> do
                (t2, body') <- infer body
                unify (Expected t1) (Found (getPos body) t2)
                pure body'
        generalizeds <- mapM generalize ts
        let scms' = zipWith fromMaybe generalizeds mayscms'
        let annotDefs = Map.fromList (zip names (zip scms' bodies'))
        annotRest <- withLocals (zip names scms') (inferDefsComponents sccs)
        pure (Map.union annotRest annotDefs)

-- | Verify that user-provided type signature schemes are valid
checkUserSchemes :: [WithPos Scheme] -> Infer ()
checkUserSchemes scms = forM_ scms $ \(WithPos p s1@(Forall _ t)) ->
    generalize t
        >>= \s2 -> when (s1 /= s2) (throwError (InvalidUserTypeSig p s1 s2))

infer :: Ast.Expr -> Infer (Type, Expr)
infer (WithPos pos e) = fmap (second (WithPos pos)) $ case e of
    Ast.Lit l -> pure (litType l, Lit l)
    Ast.Var (Id (WithPos p "_")) -> throwError (FoundHole p)
    Ast.Var x@(Id x') -> fmap (\t -> (t, Var (TypedVar x' t))) (lookupEnv x)
    Ast.App f a -> do
        ta <- fresh
        tr <- fresh
        (tf', f') <- infer f
        unify (Expected (TFun ta tr)) (Found (getPos f) tf')
        (ta', a') <- infer a
        unify (Expected ta) (Found (getPos a) ta')
        pure (tr, App f' a' tr)
    Ast.If p c a -> do
        (tp, p') <- infer p
        (tc, c') <- infer c
        (ta, a') <- infer a
        unify (Expected (TPrim TBool)) (Found (getPos p) tp)
        unify (Expected tc) (Found (getPos a) ta)
        pure (tc, If p' c' a')
    Ast.Fun p b -> inferFunMatch (pure (p, b))
    Ast.Let defs b -> do
        annotDefs <- inferDefs defs
        let defsScms = fmap (\(scm, _) -> scm) annotDefs
        (bt, b') <- withLocals' defsScms (infer b)
        pure (bt, Let annotDefs b')
    Ast.TypeAscr x t -> do
        (tx, WithPos _ x') <- infer x
        unify (Expected t) (Found (getPos x) tx)
        pure (t, x')
    Ast.Match matchee cases -> do
        (tmatchee, matchee') <- infer matchee
        (tbody, cases') <- inferCases (Expected tmatchee) cases
        let f = WithPos pos (FunMatch cases' tmatchee tbody)
        pure (tbody, App f matchee' tbody)
    Ast.FunMatch cases -> inferFunMatch cases
    Ast.Ctor c -> inferExprConstructor c
    Ast.Box x -> fmap (\(tx, x') -> (TBox tx, Box x')) (infer x)
    Ast.Deref x -> do
        t <- fresh
        (tx, x') <- infer x
        unify (Expected (TBox t)) (Found (getPos x) tx)
        pure (t, Deref x')

inferFunMatch :: [(Ast.Pat, Ast.Expr)] -> Infer (Type, Expr')
inferFunMatch cases = do
    tpat <- fresh
    (tbody, cases') <- inferCases (Expected tpat) cases
    pure (TFun tpat tbody, FunMatch cases' tpat tbody)

-- | All the patterns must be of the same types, and all the bodies must be of
--   the same type.
inferCases
    :: ExpectedType -- Type of matchee. Expected type of pattern.
    -> [(Ast.Pat, Ast.Expr)]
    -> Infer (Type, Cases)
inferCases tmatchee cases = do
    (tpats, tbodies, cases') <- fmap unzip3 (mapM inferCase cases)
    forM_ tpats (unify tmatchee)
    tbody <- fresh
    forM_ tbodies (unify (Expected tbody))
    pure (tbody, cases')

inferCase :: (Ast.Pat, Ast.Expr) -> Infer (FoundType, FoundType, (Pat, Expr))
inferCase (p, b) = do
    (tp, p', pvs) <- inferPat p
    let pvs' = Map.mapKeys Ast.idstr pvs
    (tb, b') <- withLocals' pvs' (infer b)
    pure (Found (getPos p) tp, Found (getPos b) tb, (p', b'))

inferPat :: Ast.Pat -> Infer (Type, Pat, Map (Id 'Small) Scheme)
inferPat pat = fmap
    (\(t, p, ss) -> (t, WithPos (getPos pat) p, ss))
    (inferPat' pat)
  where
    inferPat' = \case
        Ast.PConstruction pos c ps -> inferPatConstruction pos c ps
        Ast.PInt _ n -> pure (TPrim TInt, intToPCon n 64, Map.empty)
        Ast.PBool _ b ->
            pure (TPrim TBool, intToPCon (fromEnum b) 1, Map.empty)
        Ast.PStr _ s ->
            let
                span' = ice "span of Con with VariantStr"
                p = PCon (Con (VariantStr s) span' []) []
            in pure (typeStr, p, Map.empty)
        Ast.PVar (Id (WithPos _ "_")) -> do
            tv <- fresh
            pure (tv, PWild, Map.empty)
        Ast.PVar x@(Id x') -> do
            tv <- fresh
            pure
                ( tv
                , PVar (TypedVar x' tv)
                , Map.singleton x (Forall Set.empty tv)
                )
        Ast.PBox _ p -> do
            (tp', p', vs) <- inferPat p
            pure (TBox tp', PBox p', vs)
    intToPCon n w = PCon
        (Con
            { variant = VariantIx (fromIntegral n)
            , span = 2 ^ (w :: Integer)
            , argTs = []
            }
        )
        []

inferPatConstruction
    :: SrcPos
    -> Id 'Big
    -> [Ast.Pat]
    -> Infer (Type, Pat', Map (Id 'Small) Scheme)
inferPatConstruction pos c cArgs = do
    (variantIx, tdefLhs, cParams, cSpan) <- lookupEnvConstructor c
    let arity = length cParams
    let nArgs = length cArgs
    unless (arity == nArgs) (throwError (CtorArityMismatch pos c arity nArgs))
    (tdefInst, cParams') <- instantiateConstructorOfTypeDef tdefLhs cParams
    let t = TConst tdefInst
    (cArgTs, cArgs', cArgsVars) <- fmap unzip3 (mapM inferPat cArgs)
    cArgsVars' <- nonconflictingPatVarDefs cArgsVars
    forM_ (zip3 cParams' cArgTs cArgs) $ \(cParamT, cArgT, cArg) ->
        unify (Expected cParamT) (Found (getPos cArg) cArgT)
    let con = Con
            { variant = VariantIx variantIx
            , span = cSpan
            , argTs = cArgTs
            }
    pure (t, PCon con cArgs', cArgsVars')

nonconflictingPatVarDefs
    :: [Map (Id 'Small) Scheme] -> Infer (Map (Id 'Small) Scheme)
nonconflictingPatVarDefs = flip foldM Map.empty $ \acc ks ->
    case listToMaybe (Map.keys (Map.intersection acc ks)) of
        Just (Id (WithPos pos v)) -> throwError (ConflictingPatVarDefs pos v)
        Nothing -> pure (Map.union acc ks)

inferExprConstructor :: Id 'Big -> Infer (Type, Expr')
inferExprConstructor c = do
    (variantIx, tdefLhs, cParams, cSpan) <- lookupEnvConstructor c
    (tdefInst, cParams') <- instantiateConstructorOfTypeDef tdefLhs cParams
    let t = foldr TFun (TConst tdefInst) cParams'
    pure (t, Ctor variantIx cSpan tdefInst cParams')

instantiateConstructorOfTypeDef
    :: (String, [TVar]) -> [Type] -> Infer (TConst, [Type])
instantiateConstructorOfTypeDef (tName, tParams) cParams = do
    tVars <- mapM (const fresh) tParams
    let cParams' = map (subst (Map.fromList (zip tParams tVars))) cParams
    pure ((tName, tVars), cParams')

lookupEnvConstructor
    :: Id 'Big -> Infer (VariantIx, (String, [TVar]), [Type], Span)
lookupEnvConstructor (Id (WithPos pos cx)) =
    views envCtors (Map.lookup cx)
        >>= maybe (throwError (UndefCtor pos cx)) pure

litType :: Const -> Type
litType = \case
    Unit -> TPrim TUnit
    Int _ -> TPrim TInt
    Double _ -> TPrim TDouble
    Str _ -> typeStr
    Bool _ -> TPrim TBool

typeStr :: Type
typeStr = TConst ("Str", [])

lookupEnv :: Id 'Small -> Infer Type
lookupEnv (Id (WithPos pos x)) = views envDefs (Map.lookup x) >>= \case
    Just scm -> instantiate scm
    Nothing -> throwError (UndefVar pos x)

withLocals :: [(String, Scheme)] -> Infer a -> Infer a
withLocals = withLocals' . Map.fromList

withLocals' :: Map String Scheme -> Infer a -> Infer a
withLocals' = augment envDefs

unify :: ExpectedType -> FoundType -> Infer ()
unify (Expected t1) (Found pos t2) = do
    s1 <- use substs
    s2 <- unify' (Expected (subst s1 t1)) (Found pos (subst s1 t2))
    assign substs (composeSubsts s2 s1)

unify' :: ExpectedType -> FoundType -> Infer Subst
unify' (Expected t1) (Found pos t2) = lift $ lift $ withExcept
    (\case
        InfiniteType'' a t -> InfType pos t1 t2 a t
        UnificationFailed'' t'1 t'2 -> UnificationFailed pos t1 t2 t'1 t'2
    )
    (unify'' t1 t2)

data UnifyErr'' = InfiniteType'' TVar Type | UnificationFailed'' Type Type

unify'' :: Type -> Type -> Except UnifyErr'' Subst
unify'' = curry $ \case
    (TPrim a, TPrim b) | a == b -> pure Map.empty
    (TConst (c0, ts0), TConst (c1, ts1)) | c0 == c1 ->
        if length ts0 /= length ts1
            then ice "lengths of TConst params differ in unify"
            else unifys ts0 ts1
    (TVar a, TVar b) | a == b -> pure Map.empty
    (TVar a, t) | occursIn a t -> throwError (InfiniteType'' a t)
    -- Do not allow "override" of explicit (user given) type variables.
    (a@(TVar (TVExplicit _)), b@(TVar (TVImplicit _))) -> unify'' b a
    (a@(TVar (TVExplicit _)), b) -> throwError (UnificationFailed'' a b)
    (TVar a, t) -> pure (Map.singleton a t)
    (t, TVar a) -> unify'' (TVar a) t
    (TFun t1 t2, TFun u1 u2) -> unifys [t1, t2] [u1, u2]
    (TBox t, TBox u) -> unify'' t u
    (t1, t2) -> throwError (UnificationFailed'' t1 t2)

unifys :: [Type] -> [Type] -> Except UnifyErr'' Subst
unifys ts us = foldM
    (\s (t, u) -> fmap (flip composeSubsts s) (unify'' (subst s t) (subst s u)))
    Map.empty
    (zip ts us)

occursIn :: TVar -> Type -> Bool
occursIn a t = Set.member a (ftv t)

instantiate :: Scheme -> Infer Type
instantiate (Forall params t) = do
    let params' = Set.toList params
    args <- mapM (const fresh) params'
    pure (subst (Map.fromList (zip params' args)) t)

generalize :: Type -> Infer Scheme
generalize t = do
    env <- ask
    s <- use substs
    let t' = subst s t
    pure (Forall (generalize' (substEnv s env) t') t')

generalize' :: Env -> Type -> Set TVar
generalize' env t = Set.difference (ftv t) (ftvEnv env)

substEnv :: Subst -> Env -> Env
substEnv s = over (envDefs . mapped . scmBody) (subst s)

ftv :: Type -> Set TVar
ftv = \case
    TVar tv -> Set.singleton tv
    TPrim _ -> Set.empty
    TFun t1 t2 -> Set.union (ftv t1) (ftv t2)
    TBox t -> ftv t
    TConst (_, ts) -> Set.unions (map ftv ts)

ftvEnv :: Env -> Set TVar
ftvEnv = Set.unions . map (ftvScheme . snd) . Map.toList . view envDefs

ftvScheme :: Scheme -> Set TVar
ftvScheme (Forall tvs t) = Set.difference (ftv t) tvs

fresh :: Infer Type
fresh = fmap TVar fresh'

fresh' :: Infer TVar
fresh' = fmap TVImplicit fresh''

fresh'' :: Infer Int
fresh'' = tvCount <<+= 1
