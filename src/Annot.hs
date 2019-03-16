{-# LANGUAGE TemplateHaskell #-}

module Annot
  ( Program (..)
  , Expr (..)
  , Def, Defs
  , TVar, Type (..)
  , Scheme (..), scmParams, scmBody
  , typeUnit, typeInt, typeDouble, typeStr, typeBool, typeChar
  , typeOfMain ) where

import NonEmpty
import Ast (Id, Pat (..))
import Data.Map.Strict (Map)
import Data.Set (Set)
import qualified Data.Set as Set
import Control.Lens

-- Type annotated AST

type TVar = String

data Type = TVar TVar
          | TConst String
          | TFun Type Type
  deriving (Show, Eq)

typeUnit, typeInt, typeDouble, typeStr, typeBool, typeChar :: Type
typeUnit = TConst "Unit"; typeInt = TConst "Int"; typeDouble = TConst "Double"
typeChar = TConst "Char"; typeStr = TConst "Str"; typeBool   = TConst "Bool";

data Scheme = Forall { _scmParams :: (Set TVar), _scmBody :: Type }
  deriving (Show, Eq)
makeLenses ''Scheme

typeOfMain :: Scheme
typeOfMain = Forall Set.empty (TFun typeUnit typeInt)

data Expr
  = Unit
  | Int Int
  | Double Double
  | Str String
  | Bool Bool
  | Var Id
  | App Expr Expr
  | If Expr Expr Expr
  | Fun Id Expr
  | Let Defs Expr
  | Match Expr (NonEmpty (Pat, Expr))
  | FunMatch (NonEmpty (Pat, Expr))
  | Constructor String
  | Char Char
  deriving (Show, Eq)

type Def = (Id, Expr)
type Defs = Map Id (Scheme, Expr)

data Program = Program Expr Defs
  deriving Show
