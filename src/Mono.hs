{-# LANGUAGE TemplateHaskell, LambdaCase, TupleSections
           , TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses #-}

-- | Monomorphization
module Mono (monomorphize) where

import Control.Applicative (liftA2, liftA3)
import Control.Lens (makeLenses, views, use, uses, modifying)
import Control.Monad.Reader
import Control.Monad.State
import Data.Functor
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import qualified Data.Set as Set
import Data.Set (Set)

import Misc
import qualified AnnotAst as An
import AnnotAst (TVar(..), Scheme(..))
import MonoAst

data Env = Env
    { _defs :: Map String (Scheme, An.Expr)
    , _tvBinds :: Map TVar Type
    }
makeLenses ''Env

data Insts = Insts
    { _defInsts :: Map String (Map Type Expr)
    , _tdefInsts :: Set TConst
    }
makeLenses ''Insts

-- | The monomorphization monad
type Mono = StateT Insts (Reader Env)

monomorphize :: An.Program -> Program
monomorphize (An.Program main defs tdefs) =
    let
        initInsts = Insts Map.empty Set.empty
        ((defs', main'), Insts _ tdefInsts') =
            runReader (runStateT (monoLet defs main) initInsts) initEnv
        tdefs' = instTypeDefs tdefs tdefInsts'
    in Program main' defs' tdefs'

initEnv :: Env
initEnv = Env { _defs = Map.empty, _tvBinds = Map.empty }

mono :: An.Expr -> Mono Expr
mono = \case
    An.Lit c -> pure (Lit c)
    An.Var (An.TypedVar x t) -> do
        t' <- monotype t
        addDefInst x t'
        pure (Var (TypedVar x t'))
    An.App f a -> liftA2 App (mono f) (mono a)
    An.If p c a -> liftA3 If (mono p) (mono c) (mono a)
    An.Fun p b -> monoFun p b
    An.Let ds b -> fmap (uncurry Let) (monoLet ds b)
    An.Match e cs -> monoMatch e cs
    An.Ctor c -> monoCtor c

monoFun :: (String, An.Type) -> (An.Expr, An.Type) -> Mono Expr
monoFun (p, tp) (b, bt) = do
    parentInst <- uses defInsts (Map.lookup p)
    modifying defInsts (Map.delete p)
    tp' <- monotype tp
    b' <- mono b
    bt' <- monotype bt
    maybe (pure ()) (modifying defInsts . Map.insert p) parentInst
    pure (Fun (TypedVar p tp') (b', bt'))

monoLet :: An.Defs -> An.Expr -> Mono (Defs, Expr)
monoLet (An.Defs ds) body = do
    let ks = Map.keys ds
    parentInsts <- uses defInsts (lookups ks)
    let newEmptyInsts = (fmap (const Map.empty) ds)
    modifying defInsts (Map.union newEmptyInsts)
    body' <- augment defs ds (mono body)
    dsInsts <- uses defInsts (lookups ks)
    modifying defInsts (Map.union (Map.fromList parentInsts))
    let ds' = Map.fromList $ do
            (name, dInsts) <- dsInsts
            (t, body) <- Map.toList dInsts
            pure (TypedVar name t, body)
    pure (Defs ds', body')

monoMatch :: An.Expr -> [(An.Pat, An.Expr)] -> Mono Expr
monoMatch e cs = do
    e' <- mono e
    cs' <- mapM monoCase cs
    pure (Match e' cs')

monoCase :: (An.Pat, An.Expr) -> Mono (Pat, Expr)
monoCase (p, e) = do
    (p', pvs) <- monoPat p
    let pvs' = Set.toList pvs
    parentInsts <- uses defInsts (lookups pvs')
    modifying defInsts (deletes pvs')
    e' <- mono e
    modifying defInsts (Map.union (Map.fromList parentInsts))
    pure (p', e')

monoPat :: An.Pat -> Mono (Pat, Set String)
monoPat = \case
    An.PConstruction c ps -> do
        (ps', bvs) <- fmap unzip (mapM monoPat ps)
        pure (PConstruction c ps', Set.unions bvs)
    An.PVar (An.TypedVar x t) ->
        fmap (\t' -> (PVar (TypedVar x t'), Set.singleton x)) (monotype t)

monoCtor :: An.Ctor -> Mono Expr
monoCtor (i, (tdefName, tdefArgs), ts) = do
    tdefArgs' <- mapM monotype tdefArgs
    let tdefInst = (tdefName, tdefArgs')
    modifying tdefInsts (Set.insert tdefInst)
    ts' <- mapM monotype ts
    pure (Ctor (i, tdefInst, ts'))

addDefInst :: String -> Type -> Mono ()
addDefInst x t1 = do
    use defInsts <&> Map.lookup x >>= \case
        -- If x is not in insts, it's a function parameter. Ignore.
        Nothing -> pure ()
        Just xInsts -> unless (Map.member t1 xInsts) $ do
            (Forall _ t2, body) <- views
                defs
                (lookup' (ice (x ++ " not in defs")) x)
            body' <- augment tvBinds (bindTvs t2 t1) (mono body)
            insertInst x t1 body'

bindTvs :: An.Type -> Type -> Map TVar Type
bindTvs a b = case (a, b) of
    (An.TVar v, t) -> Map.singleton v t
    (An.TFun p0 r0, TFun p1 r1) -> Map.union (bindTvs p0 p1) (bindTvs r0 r1)
    (An.TPrim _, TPrim _) -> Map.empty
    (An.TConst (_, ts0), TConst (_, ts1)) ->
        Map.unions (zipWith bindTvs ts0 ts1)
    (An.TPrim _, _) -> err
    (An.TFun _ _, _) -> err
    (An.TConst _, _) -> err
    where err = ice $ "bindTvs: " ++ show a ++ ", " ++ show b

monotype :: An.Type -> Mono Type
monotype = lift . monotype'

monotype' :: An.Type -> Reader Env Type
monotype' = \case
    An.TVar v -> views tvBinds (lookup' (ice (show v ++ " not in tvBinds")) v)
    An.TPrim c -> pure (TPrim c)
    An.TFun a b -> liftA2 TFun (monotype' a) (monotype' b)
    An.TConst (c, ts) -> fmap (curry TConst c) (mapM monotype' ts)

insertInst :: String -> Type -> Expr -> Mono ()
insertInst x t b = modifying defInsts (Map.adjust (Map.insert t b) x)

-- Anot: [(String, ([TVar], [[Type]]))]
-- Mono: [(TConst, [[Type]])]
--
-- Env
--    { _defs :: Map String (Scheme, An.Expr)
--    , _tvBinds :: Map TVar Type
--    }
instTypeDefs :: An.TypeDefs -> Set TConst -> TypeDefs
instTypeDefs tdefs insts = map
    (\(x, ts) -> instTypeDef x ts (lookup' (ice "in instTypeDefs") x tdefs))
    (Set.toList insts)
  where
    instTypeDef x ts (tvs, vs) =
        let
            vs' = runReader
                (mapM (mapM monotype') vs)
                (Env Map.empty (Map.fromList (zip tvs ts)))
        in ((x, ts), vs')

lookup' :: Ord k => v -> k -> Map k v -> v
lookup' = Map.findWithDefault

lookups :: Ord k => [k] -> Map k v -> [(k, v)]
lookups ks m = catMaybes (map (\k -> fmap (k, ) (Map.lookup k m)) ks)

deletes :: (Foldable t, Ord k) => t k -> Map k v -> Map k v
deletes = flip (foldr Map.delete)
