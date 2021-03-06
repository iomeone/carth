{-# LANGUAGE LambdaCase, TemplateHaskell #-}

module Gen
    ( Gen
    , Gen'
    , Out(..)
    , outBlocks
    , outStrings
    , outFuncs
    , St(..)
    , currentBlockLabel
    , currentBlockInstrs
    , registerCount
    , lambdaParentFunc
    , outerLambdaN
    , Env(..)
    , env
    , dataTypes
    , lookupDatatype
    )
where

import LLVM.AST
import Control.Monad.Writer
import Control.Monad.State
import Control.Monad.Reader
import qualified Data.Map as Map
import Data.Map (Map)
import Control.Lens (makeLenses, views)

import Misc
import MonoAst hiding (Type, Const)


data Env = Env
    -- TODO: Could operands in env be Val instead? I.e., either stack-allocated
    --       or local?
    { _env :: Map TypedVar Operand  -- ^ Environment of stack allocated variables
    , _dataTypes :: Map Name Type
    }
makeLenses ''Env

data St = St
    { _currentBlockLabel :: Name
    , _currentBlockInstrs :: [Named Instruction]
    , _registerCount :: Word
    -- | Keep track of the parent function name so that we can name the
    --   outermost lambdas of a function definition well.
    , _lambdaParentFunc :: Maybe String
    , _outerLambdaN :: Word
    }
makeLenses ''St

type Gen' = StateT St (Reader Env)

-- | The output of generating a function
data Out = Out
    { _outBlocks :: [BasicBlock]
    , _outStrings :: [(Name, String)]
    , _outFuncs :: [(Name, [TypedVar], TypedVar, Expr)]
    }
makeLenses ''Out

type Gen = WriterT Out Gen'


instance Semigroup Out where
    Out bs1 ss1 fs1 <> Out bs2 ss2 fs2 =
        Out (bs1 <> bs2) (ss1 <> ss2) (fs1 <> fs2)
instance Monoid Out where
    mempty = Out [] [] []


lookupDatatype :: Name -> Gen' Type
lookupDatatype x = views dataTypes (Map.lookup x) >>= \case
    Just u -> pure u
    Nothing -> ice $ "Undefined datatype " ++ show x
