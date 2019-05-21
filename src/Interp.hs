{-# LANGUAGE LambdaCase #-}

module Interp
    ( interpret
    ) where

import Annot hiding (Type)
import Ast (Const(..))
import Control.Applicative (liftA3)
import Control.Monad.Reader
import Data.Bool.HT
import Data.Functor
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
import Mono

data Val
    = VConst Const
    | VFun (Val -> IO Val)

type Env = Map (String, Type) Val

type Eval = ReaderT Env IO

interpret :: MProgram -> IO ()
interpret p = runEval (evalProgram p)

runEval :: Eval a -> IO a
runEval m = runReaderT m builtinValues

builtinValues :: Map (String, Type) Val
builtinValues =
    Map.fromList
        [ ( ("printInt", TFun typeInt typeUnit)
          , VFun (\v -> print (unwrapInt v) $> VConst Unit))
        , ( ("+", TFun typeInt (TFun typeInt typeInt))
          , VFun (\a -> pure (VFun (\b -> pure (plus a b)))))
        ]

plus :: Val -> Val -> Val
plus a b = VConst (Int (unwrapInt a + unwrapInt b))

evalProgram :: MProgram -> Eval ()
evalProgram (Program main defs) = do
    f <- evalLet defs main
    fmap unwrapUnit (unwrapFun' f (VConst Unit))

evalDefs :: Defs -> Eval (Map (String, Type) Val)
evalDefs (Defs defs) = do
    let (defNames, defBodies) = unzip (Map.toList defs)
    defVals <- mapM eval defBodies
    pure (Map.fromList (zip defNames defVals))

eval :: MExpr -> Eval Val
eval =
    \case
        Lit c -> pure (VConst c)
        Var x t -> lookupEnv (x, t)
        App ef ea -> do
            f <- fmap unwrapFun' (eval ef)
            a <- eval ea
            f a
        If p c a -> liftA3 (if' . unwrapBool) (eval p) (eval c) (eval a)
        Fun (p, pt) b -> do
            env <- ask
            let f v = runEval (withLocals env (withLocal (p, pt) v (eval b)))
            pure (VFun f)
        Let defs body -> evalLet defs body

evalLet :: Defs -> MExpr -> Eval Val
evalLet defs body = do
    defs' <- evalDefs defs
    withLocals defs' (eval body)

lookupEnv :: (String, Type) -> Eval Val
lookupEnv (x, t) =
    fmap
        (fromMaybe (ice ("Unbound variable: " ++ x ++ " of type " ++ show t)))
        (asks (Map.lookup (x, t)))

withLocals :: Map (String, Type) Val -> Eval a -> Eval a
withLocals defs = local (Map.union defs)

withLocal :: (String, Type) -> Val -> Eval a -> Eval a
withLocal var val = local (Map.insert var val)

unwrapFun' :: Val -> (Val -> Eval Val)
unwrapFun' v = \x -> lift (unwrapFun v x)

unwrapUnit :: Val -> ()
unwrapUnit =
    \case
        VConst Unit -> ()
        x -> ice ("Unwrapping unit, found " ++ showVariant x)

unwrapInt :: Val -> Int
unwrapInt =
    \case
        VConst (Int n) -> n
        x -> ice ("Unwrapping int, found " ++ showVariant x)

unwrapBool :: Val -> Bool
unwrapBool =
    \case
        VConst (Bool b) -> b
        x -> ice ("Unwrapping bool, found " ++ showVariant x)

unwrapFun :: Val -> (Val -> IO Val)
unwrapFun =
    \case
        VFun f -> f
        x -> ice ("Unwrapping function, found " ++ showVariant x)

showVariant :: Val -> String
showVariant =
    \case
        VConst c ->
            case c of
                Unit -> "unit"
                Int _ -> "int"
                Double _ -> "double"
                Str _ -> "string"
                Bool _ -> "bool"
                Char _ -> "character"
        VFun _ -> "function"