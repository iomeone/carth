{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Data.Functor
import System.Environment

import Misc
import qualified TypeErr
import qualified Ast
import qualified DesugaredAst
import qualified MonoAst
import Check
import Config
import Compile
import Mono
import qualified Parse
import EnvVars

main :: IO ()
main = uncurry compileFile =<< getConfig

compileFile :: FilePath -> CompileConfig -> IO ()
compileFile f cfg = do
    putStrLn ("   Compiling " ++ f ++ "")
    putStrLn ("     Environment variables:")
    lp <- lookupEnv "LIBRARY_PATH"
    mp <- modulePaths
    putStrLn ("       library path = " ++ show lp)
    putStrLn ("       module paths = " ++ show mp)
    putStrLn ("   Parsing")
    ast <- parse f
    putStrLn ("   Typechecking")
    ann <- typecheck' f ast
    putStrLn ("   Monomorphizing")
    mon <- monomorphize' ann
    compile f cfg mon
    putStrLn ""

parse :: FilePath -> IO Ast.Program
parse f = Parse.parse f >>= \case
    Left e -> putStrLn (formatParseErr e) >> abort f
    Right p -> writeFile ".dbg.out.parsed" (pretty p) $> p
  where
    formatParseErr e =
        let ss = lines e in (unlines ((head ss ++ " Error:") : tail ss))

typecheck' :: FilePath -> Ast.Program -> IO DesugaredAst.Program
typecheck' f p = case typecheck p of
    Left e -> TypeErr.printErr e >> abort f
    Right p -> writeFile ".dbg.out.checked" (show p) $> p

monomorphize' :: DesugaredAst.Program -> IO MonoAst.Program
monomorphize' p = do
    let p' = monomorphize p
    writeFile ".dbg.out.mono" (show p')
    pure p'
