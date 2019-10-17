{-# LANGUAGE LambdaCase, OverloadedStrings, TemplateHaskell, TupleSections
  , TypeSynonymInstances, FlexibleInstances, RankNTypes, FlexibleContexts #-}

module Check (typecheck) where

import Control.Lens
    ((<<+=), assign, makeLenses, over, use, view, views, locally, mapped)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State.Strict
import Control.Arrow ((>>>))
import Data.Either.Combinators
import Data.Bifunctor
import Data.Graph (SCC(..), flattenSCC, stronglyConnComp)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)

import Misc
import SrcPos
import FreeVars
import NonEmpty
import qualified Ast
import Ast (Id, idstr, scmBody)
import TypeErr
import AnnotAst

data Env = Env
    { _envDefs :: Map String Scheme
    -- | Maps a constructor to its variant index in the type definition it
    --   constructs, the signature/left-hand-side of the type definition, and
    --   the types of its parameters
    , _envCtors :: Map String (VariantIx, (String, [TVar]), [Type])
    }
makeLenses ''Env

-- | Map of substitutions from type-variables to more specific types
type Subst = Map TVar Type

data St = St
    { _tvCount :: Int
    , _substs :: Subst
    }
    deriving (Show)
makeLenses ''St

-- | Type checker monad
type Infer a = ReaderT Env (StateT St (Except TypeErr)) a

typecheck :: Ast.Program -> Either TypeErr Program
typecheck = runInfer . inferProgram

runInfer :: Infer Program -> Either TypeErr Program
runInfer m =
    mapRight (\(p, st) -> substProgram (view substs st) p) (runInfer' m)

runInfer' :: Infer a -> Either TypeErr (a, St)
runInfer' = runExcept . flip runStateT initSt . flip runReaderT initEnv

initEnv :: Env
initEnv = Env { _envDefs = builtinSchemes, _envCtors = Map.empty }

builtinSchemes :: Map String Scheme
builtinSchemes = Map.fromList
    [("printInt", Forall Set.empty (TFun (TPrim TInt) (TPrim TUnit)))]

initSt :: St
initSt = St { _tvCount = 0, _substs = Map.empty }

fresh :: Infer Type
fresh = fmap TVar fresh'

fresh' :: Infer TVar
fresh' = fmap TVImplicit fresh''

freshVar :: Infer String
freshVar = fmap show fresh''

fresh'' :: Infer Int
fresh'' = tvCount <<+= 1

withLocals :: [(String, Scheme)] -> Infer a -> Infer a
withLocals = withLocals' . Map.fromList

withLocals' :: Map String Scheme -> Infer a -> Infer a
withLocals' = augment envDefs

withLocal :: (String, Scheme) -> Infer a -> Infer a
withLocal b = locally envDefs (uncurry Map.insert b)

-- Inference
--------------------------------------------------------------------------------
inferProgram :: Ast.Program -> Infer Program
inferProgram (Ast.Program defs tdefs) = do
    (_, (WithPos mainPos _)) <- maybe
        (throwError MainNotDefined)
        pure
        (lookup "main" (map (first unpos) defs))
    (tdefs', ctors) <- checkTypeDefs tdefs
    Defs defs' <- augment envCtors ctors (inferDefs defs)
    let (Forall _ mainT, main) = fromJust (Map.lookup "main" defs')
    let expectedMainType = TFun (TPrim TUnit) (TPrim TUnit)
    unify (Expected expectedMainType) (Found mainPos mainT)
    let defs'' = Map.delete "main" defs'
    pure (Program main (Defs defs'') tdefs')

checkTypeDefs
    :: [Ast.TypeDef]
    -> Infer
           ( Map String ([TVar], [[Type]])
           , Map String (VariantIx, (String, [TVar]), [Type])
           )
checkTypeDefs =
    (fmap (second (fmap snd)) .)
        $ flip foldM (Map.empty, Map.empty)
        $ \(tds', csAcc) td@(Ast.TypeDef x _ _) -> do
            when (Map.member (idstr x) tds') (throwError (ConflictingTypeDef x))
            (td', cs) <- checkTypeDef td
            case listToMaybe (Map.elems (Map.intersection csAcc cs)) of
                Just (cId, _) -> throwError (ConflictingCtorDef cId)
                Nothing ->
                    pure (uncurry Map.insert td' tds', Map.union cs csAcc)

checkTypeDef
    :: Ast.TypeDef
    -> Infer
           ( (String, ([TVar], [[Type]]))
           , Map String (Id, (VariantIx, (String, [TVar]), [Type]))
           )
checkTypeDef (Ast.TypeDef (WithPos _ x) ps (Ast.ConstructorDefs cs)) = do
    let ps' = map TVExplicit ps
    let cs' = map snd cs
    cs''' <- foldM
        (\cs'' (i, (cx, cps)) -> if Map.member (idstr cx) cs''
            then throwError (ConflictingCtorDef cx)
            else pure (Map.insert (idstr cx) (cx, (i, (x, ps'), cps)) cs'')
        )
        Map.empty
        (zip [0 ..] cs)
    pure ((x, (ps', cs')), cs''')
--
-- withTypes tds =
--     let
--         tds' = Map.fromList (map (\td@(Ast.TypeDef x _ _) -> (x, td)) tds)
--         tdsCs = Map.fromList (concatMap extractCtors tds)
--         extractCtors td@(Ast.TypeDef _ _ (Ast.ConstructorDefs cs)) =
--             map (second (const td)) cs
--     in augment envTypeDefs tds' . augment envCtors tdsCs

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
    [] -> pure (Defs Map.empty)
    (scc : sccs) -> do
        let (idents, rhss) = unzip (flattenSCC scc)
        let (mayscms, bodies) = unzip rhss
        checkUserSchemes (catMaybes mayscms)
        let mayscms' = map (fmap unpos) mayscms
        let names = map idstr idents
        ts <- replicateM (length names) fresh
        let scms = map
                (\(mayscm, t) -> fromMaybe (Forall Set.empty t) mayscm)
                (zip mayscms' ts)
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
        Defs annotRest <- withLocals
            (zip names scms')
            (inferDefsComponents sccs)
        pure (Defs (Map.union annotRest annotDefs))

-- | Verify that user-provided type signature schemes are valid
checkUserSchemes :: [WithPos Scheme] -> Infer ()
checkUserSchemes scms = forM_ scms $ \(WithPos p s1@(Forall _ t)) ->
    generalize t
        >>= \s2 -> when (s1 /= s2) (throwError (InvalidUserTypeSig p s1 s2))

infer :: Ast.Expr -> Infer (Type, Expr)
infer = unpos >>> \case
    Ast.Lit l -> pure (litType l, Lit l)
    Ast.Var x -> fmap (\t -> (t, Var (TypedVar (idstr x) t))) (lookupEnv x)
    Ast.App f a -> do
        ta <- fresh
        tr <- fresh
        (tf', f') <- infer f
        unify (Expected (TFun ta tr)) (Found (getPos f) tf')
        (ta', a') <- infer a
        unify (Expected ta) (Found (getPos a) ta')
        pure (tr, App f' a')
    Ast.If p c a -> do
        (tp, p') <- infer p
        (tc, c') <- infer c
        (ta, a') <- infer a
        unify (Expected (TPrim TBool)) (Found (getPos p) tp)
        unify (Expected tc) (Found (getPos a) ta)
        pure (tc, If p' c' a')
    Ast.Fun p b -> do
        tp <- fresh
        (tb, b') <- withLocal (idstr p, Forall Set.empty tp) (infer b)
        pure (TFun tp tb, Fun (idstr p, tp) (b', tb))
    Ast.Let defs b -> do
        Defs annotDefs <- inferDefs (fromList1 defs)
        let defsScms = fmap (\(scm, _) -> scm) annotDefs
        (bt, b') <- withLocals' defsScms (infer b)
        pure (bt, Let (Defs annotDefs) b')
    Ast.TypeAscr x t -> do
        (tx, x') <- infer x
        unify (Expected t) (Found (getPos x) tx)
        pure (t, x')
    Ast.Match matchee cases -> do
        (tmatchee, matchee') <- infer matchee
        (tbody, cases') <- inferCases (Expected tmatchee) cases
        pure (tbody, Match matchee' cases')
    Ast.FunMatch cases -> do
        tpat <- fresh
        (tbody, cases') <- inferCases (Expected tpat) cases
        let t = TFun tpat tbody
        x <- freshVar
        let e = Fun (x, tpat) (Match (Var (TypedVar x tpat)) cases', tbody)
        pure (t, e)
    Ast.Constructor c -> inferExprConstructor c

-- TODO: Check that the patterns are exhaustive or variable/wildcard
-- | All the patterns must be of the same types, and all the bodies must be of
--   the same type.
inferCases
    :: ExpectedType -- Type of matchee. Expected type of pattern.
    -> NonEmpty (Ast.Pat, Ast.Expr)
    -> Infer (Type, [(Pat, Expr)])
inferCases tmatchee cases = do
    (tpats, tbodies, cases') <- fmap unzip3 (mapM inferCase (fromList1 cases))
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

inferPat :: Ast.Pat -> Infer (Type, Pat, Map Id Scheme)
inferPat = \case
    Ast.PConstruction pos c ps -> inferPatConstruction pos c ps
    Ast.PVar x -> do
        tv <- fresh'
        let tv' = TVar tv
        pure
            ( tv'
            , PVar (TypedVar (idstr x) tv')
            , Map.singleton x (Forall Set.empty tv')
            )

inferPatConstruction
    :: SrcPos -> Id -> [Ast.Pat] -> Infer (Type, Pat, Map Id Scheme)
inferPatConstruction pos c cArgs = do
    (variantIx, tdefLhs, cParams) <- lookupEnvConstructor c
    let arity = length cParams
    let nArgs = length cArgs
    unless (arity == nArgs) (throwError (CtorArityMismatch pos c arity nArgs))
    (tdefInst, cParams') <- instantiateConstructorOfTypeDef tdefLhs cParams
    let t = TConst tdefInst
    (cArgTs, cArgs', cArgsVars) <- fmap unzip3 (mapM inferPat cArgs)
    cArgsVars' <- nonconflictingPatVarDefs cArgsVars
    forM_ (zip3 cParams' cArgTs cArgs) $ \(cParamT, cArgT, cArg) ->
        unify (Expected cParamT) (Found (getPos cArg) cArgT)
    pure (t, PConstruction variantIx cArgs', cArgsVars')

nonconflictingPatVarDefs :: [Map Id Scheme] -> Infer (Map Id Scheme)
nonconflictingPatVarDefs = flip foldM Map.empty $ \acc ks ->
    case listToMaybe (Map.keys (Map.intersection acc ks)) of
        Just (WithPos pos v) -> throwError (ConflictingPatVarDefs pos v)
        Nothing -> pure (Map.union acc ks)

inferExprConstructor :: Id -> Infer (Type, Expr)
inferExprConstructor c = do
    (variantIx, tdefLhs, cParams) <- lookupEnvConstructor c
    (tdefInst, cParams') <- instantiateConstructorOfTypeDef tdefLhs cParams
    cParams'' <- mapM (\t -> freshVar >>= \x -> (x, t)) cParams'
    let cArgs = map (Var .* TypedVar) cParams''
        tInner = TConst tdefInst
    let t = foldr TFun tInner cParams'
    let e = foldr Fun (Ction (variantIx, tdefInst, cArgs), tInner) cParams''
    pure (t, e)

instantiateConstructorOfTypeDef
    :: (String, [TVar]) -> [Type] -> Infer (TConst, [Type])
instantiateConstructorOfTypeDef (tName, tParams) cParams = do
    tVars <- mapM (const fresh) tParams
    let cParams' = map (subst (Map.fromList (zip tParams tVars))) cParams
    pure ((tName, tVars), cParams')

lookupEnvConstructor :: Id -> Infer (VariantIx, (String, [TVar]), [Type])
lookupEnvConstructor (WithPos pos cx) =
    views envCtors (Map.lookup cx)
        >>= maybe (throwError (UndefCtor pos cx)) pure
    -- views envCtors (Map.lookup cx) >>= \case
    --     Just (Ast.TypeDef tx tps cs) ->
    --         case lookupConstructorParamTypes cx cs of
    --             Just cps -> pure (cps, (tx, tps))
    --             Nothing ->
    --                 ice
    --                     $ ("lookup failed for ctor `" ++ cx)
    --                     ++ ("` in type `" ++ tx ++ "`")
    --     Nothing -> throwError (UndefCtor pos cx)

-- lookupConstructorParamTypes :: String -> Ast.ConstructorDefs -> Maybe [Type]
-- lookupConstructorParamTypes cx (Ast.ConstructorDefs cs) = lookup cx cs

litType :: Const -> Type
litType = \case
    Unit -> TPrim TUnit
    Int _ -> TPrim TInt
    Double _ -> TPrim TDouble
    Char _ -> TPrim TChar
    Str _ -> TPrim TStr
    Bool _ -> TPrim TBool

lookupEnv :: Id -> Infer Type
lookupEnv (WithPos pos x) = views envDefs (Map.lookup x) >>= \case
    Just scm -> instantiate scm
    Nothing -> throwError (UndefVar pos x)

-- Substitution
--------------------------------------------------------------------------------
substProgram :: Subst -> Program -> Program
substProgram s (Program main (Defs defs) tdefs) =
    Program (substExpr s main) (Defs (fmap (substDef s) defs)) tdefs

substDef :: Subst -> (Scheme, Expr) -> (Scheme, Expr)
substDef s = bimap id (substExpr s)

substExpr :: Subst -> Expr -> Expr
substExpr s = \case
    Lit c -> Lit c
    Var (TypedVar x t) -> Var (TypedVar x (subst s t))
    App f a -> App (substExpr s f) (substExpr s a)
    If p c a -> If (substExpr s p) (substExpr s c) (substExpr s a)
    Fun (p, tp) (b, bt) -> Fun (p, subst s tp) (substExpr s b, subst s bt)
    Let (Defs defs) body ->
        Let (Defs (fmap (substDef s) defs)) (substExpr s body)
    Match e cs -> Match
        (substExpr s e)
        (map (\(p, b) -> (substPat s p, substExpr s b)) cs)
    Ctor c -> Ctor c

substPat :: Subst -> Pat -> Pat
substPat s = \case
    PConstruction c ps -> PConstruction c (map (substPat s) ps)
    PVar (TypedVar x t) -> PVar (TypedVar x (subst s t))

subst :: Subst -> Type -> Type
subst s t = case t of
    TVar tv -> fromMaybe t (Map.lookup tv s)
    TPrim _ -> t
    TFun a b -> TFun (subst s a) (subst s b)
    TConst (c, ts) -> TConst (c, (map (subst s) ts))

substEnv :: Subst -> Env -> Env
substEnv s = over (envDefs . mapped . scmBody) (subst s)

composeSubsts :: Subst -> Subst -> Subst
composeSubsts s1 s2 = Map.union (fmap (subst s1) s2) s1

-- Unification
--------------------------------------------------------------------------------
newtype ExpectedType = Expected Type
data FoundType = Found SrcPos Type

unify :: ExpectedType -> FoundType -> Infer ()
unify (Expected t1) (Found pos t2) = do
    s1 <- use substs
    s2 <- unify' (Expected (subst s1 t1)) (Found pos (subst s1 t2))
    assign substs (composeSubsts s2 s1)

unify' :: ExpectedType -> FoundType -> Infer Subst
unify' (Expected t1) (Found pos t2) = lift $ lift $ withExcept
    (\case
        InfiniteType'' a t -> InfType pos a t
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
    (t1, t2) -> throwError (UnificationFailed'' t1 t2)

unifys :: [Type] -> [Type] -> Except UnifyErr'' Subst
unifys ts us = foldM
    (\s (t, u) -> fmap (flip composeSubsts s) (unify'' (subst s t) (subst s u)))
    Map.empty
    (zip ts us)

occursIn :: TVar -> Type -> Bool
occursIn a t = Set.member a (ftv t)

-- Instantiation and generalization
--------------------------------------------------------------------------------
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

-- Free type variables
--------------------------------------------------------------------------------
ftv :: Type -> Set TVar
ftv = \case
    TVar tv -> Set.singleton tv
    TPrim _ -> Set.empty
    TFun t1 t2 -> Set.union (ftv t1) (ftv t2)
    TConst (_, ts) -> Set.unions (map ftv ts)

ftvEnv :: Env -> Set TVar
ftvEnv = Set.unions . map (ftvScheme . snd) . Map.toList . view envDefs

ftvScheme :: Scheme -> Set TVar
ftvScheme (Forall tvs t) = Set.difference (ftv t) tvs
