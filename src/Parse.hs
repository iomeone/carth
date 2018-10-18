{-# LANGUAGE FlexibleContexts #-}

module Parse where

import Text.Parsec
import Data.Char (isMark, isPunctuation, isSymbol)
import Data.List (intercalate)
import Data.Either.Combinators (rightToMaybe)

data Expr = Var String
          | Str String
          | App Expr [Expr]
          | Lam String Expr
  deriving (Show, Eq)

and' a b = a && b

isBracket c = elem c "()[]{}"

(<:>) p q = do
  a <- p
  as <- q
  return (a:as)

spaces1 = skipMany1 space

symbol = satisfy (\c -> and [ any (\pred -> pred c)
                                  [isMark, isPunctuation, isSymbol]
                            , not (isBracket c)
                            , not (c == '"') ])

identFirstChar = letter <|> symbol
identRestChar = identFirstChar <|> digit
ident = identFirstChar <:> many identRestChar

var = fmap Var ident

escaped :: Parsec String () String
escaped = do
  char '\\'
  c <- anyChar
  return ['\\', c]

str' = do
  char '"'
  s <- many (escaped <|> fmap (\c -> [c]) (noneOf ['"']))
  char '"'
  return (concat s)

str = fmap Str str'

app = do
  char '('
  spaces
  rator <- expr
  rands <- many (spaces1 >> expr)
  spaces
  char ')'
  return (App rator rands)

expr = choice [var, str, app]

lam = do
  char '('
  spaces
  string "lambda"
  spaces1
  params <- between (char '(' >> spaces) (spaces >> char ')') (sepEndBy1 ident spaces1)
  spaces1
  body <- expr
  spaces
  char ')'
  return (foldr (\param inner -> Lam param inner) body params)



--- Testing

type Test = (String, String, Parsec String () String, Maybe String)

tIdent :: Test
tIdent = ("parse identifier",
          "_mäin-1",
          ident,
          Just "_mäin-1")

tStr :: Test
tStr = ("parse string",
        "\"Hello, \\\"World!\\\"\"",
        fmap show str,
        Just (show (Str "Hello, \\\"World!\\\"")))

tApp :: Test
tApp = ("parse app",
        "(display \"Hello, World!\")",
        fmap show app,
        Just (show (App (Var "display") [Str "Hello, World!"])))

tLam :: Test
tLam = ("parse lambda",
        "(lambda (a b) (+ a b))",
        fmap show lam,
        Just (show (Lam "a"
                        (Lam "b"
                             (App (Var "+") [Var "a", Var "b"])))))

-- tDef :: Test
-- tDef = ("parse var definition",
--         "(define pi 3.1415)",
--         fmap show def,
--         Just (show (Def "pi" ())))

tests = [tIdent, tStr, tApp, tLam]

runTest (name, input, parser, expected) =
  let result = parse parser name input
  in if (rightToMaybe result) == expected
     then Right name
     else Left (name, result, expected)

testResults = map runTest tests

prettyTestResults = intercalate "\n" (map pretty testResults)
  where pretty (Right name) = "Test `" ++ name ++ "` passed!"
        pretty (Left (name, found, expected)) =
          "Test `" ++ name ++ "` failed!\n"
          ++ "  Expected "
          ++ case expected of
               Just s  -> "successful parse of\n    `" ++ s ++ "`"
               Nothing -> "failed parse"
          ++ "\n  found\n    "
          ++ show found

printTestResults = putStrLn prettyTestResults