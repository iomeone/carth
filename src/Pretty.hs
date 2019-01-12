{-# LANGUAGE LambdaCase #-}

module Pretty where

import NonEmpty
import Ast
import Data.List (intercalate)
import qualified Data.Map.Strict as Map

-- Pretty printing

prettyPrint :: Pretty a => a -> IO ()
prettyPrint = putStrLn . pretty

pretty :: Pretty a => a -> String
pretty = pretty' 0

-- Pretty print starting at some indentation depth
class Pretty a where
  pretty' :: Int -> a -> String

instance Pretty Program where
  pretty' d (Program main defs) =
    let allDefs = (Id "main", main) : Map.toList defs
        prettyDef (Id name, val) =
          concat [ replicate d ' ', "(define ", name, "\n"
                 , replicate (d + 2) ' ', pretty' (d + 2) val, ")" ]
    in unlines (map prettyDef allDefs)

-- type Defs = Map Id Expr

-- data Program = Program Expr Defs
--   deriving (Show, Eq)

instance Pretty Expr where
  pretty' d = \case
    Unit -> "unit"
    Int n -> show n
    Double x -> show x
    Str s -> '"' : (s >>= showChar') ++ "\""
    Bool b -> if b then "true" else "false"
    Var (Id v) -> v
    App f x ->
      concat [ "(", pretty' (d + 1) f, "\n"
             , replicate (d + 1) ' ',  pretty' (d + 1) x, ")" ]
    If pred cons alt ->
      concat [ "(if ", pretty' (d + 4) pred, "\n"
             , replicate (d + 4) ' ', pretty' (d + 4) cons, "\n"
             , replicate (d + 2) ' ', pretty' (d + 2) alt, ")" ]
    Fun (Id param) body ->
      concat [ "(fun [", param, "]", "\n"
             , replicate (d + 2) ' ', pretty' (d + 2) body, ")" ]
    Let binds body ->
      concat [ "(let ["
             , intercalate1 ("\n" ++ replicate (d + 6) ' ')
                            (map1 (prettyBracketPair (d + 6)) binds)
             , "]\n"
             , replicate (d + 2) ' ' ++ pretty' (d + 2) body, ")" ]
    Match e cs ->
      concat [ "(match ", pretty' (d + 7) e
             , "\n", replicate (d + 2) ' '
             , intercalate1 ("\n" ++ replicate (d + 2) ' ')
                            (map1 (prettyBracketPair (d + 2)) cs)
             , ")"]
    FunMatch cs ->
      concat [ "(fun-match"
             , "\n", replicate (d + 2) ' '
             , intercalate1 ("\n" ++ replicate (d + 2) ' ')
                            (map1 (prettyBracketPair (d + 2)) cs)
             , ")"]
    Constructor c -> c
    Char c -> showChar c
    where prettyBracketPair d (a, b) =
            concat [ "[", pretty' (d + 1) a, "\n"
                   , replicate (d + 1) ' ', pretty' (d + 1) b, "]" ]
          showChar' = \case
            '\0' -> "\\0"
            '\a' -> "\\a"
            '\b' -> "\\b"
            '\t' -> "\\t"
            '\n' -> "\\n"
            '\v' -> "\\v"
            '\f' -> "\\f"
            '\r' -> "\\r"
            '\\' -> "\\\\"
            '\"' -> "\\\""
            c -> [c]
          showChar c = "'" ++ showChar' c ++ "'"

instance Pretty Id where
  pretty' _ (Id s) = s

instance Pretty Pat where
  pretty' _ = \case
    PConstructor c -> c
    PConstruction c ps ->
      concat [ "(", c, " ", intercalate " " (nonEmptyToList (map1 pretty ps)), ")" ]
    PVar (Id v) -> v
