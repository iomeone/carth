{-# LANGUAGE FlexibleContexts, LambdaCase, TupleSections #-}

module Parse (parse, reserveds) where

import Control.Monad
import Data.Char (isMark, isPunctuation, isSymbol, isUpper)
import Data.Functor
import Data.Bifunctor
import Data.Maybe
import Control.Applicative (liftA2)
import qualified Text.Megaparsec as Megaparsec
import Text.Megaparsec hiding (parse, match)
import Text.Megaparsec.Char hiding (space, space1)
import qualified Text.Megaparsec.Char as Char
import qualified Text.Megaparsec.Char.Lexer as Lexer
import qualified Data.Set as Set
import qualified Data.Map as Map
import Data.Either.Combinators
import Data.Void
import Data.Composition

import Misc
import SrcPos
import Ast
import NonEmpty

type Parser = Parsec Void String

type SourceName = String

parse :: SourceName -> String -> Either String Program
parse = parse' program

parse' :: Parser a -> SourceName -> String -> Either String a
parse' p name src = mapLeft errorBundlePretty (Megaparsec.parse p name src)

program :: Parser Program
program = do
    space
    (defs, typedefs) <- toplevels
    eof
    pure (Program defs typedefs)

toplevels :: Parser ([Def], [TypeDef])
toplevels = option ([], []) (toplevel >>= flip fmap toplevels)

toplevel :: Parser (([Def], [TypeDef]) -> ([Def], [TypeDef]))
toplevel = do
    topPos <- getSrcPos
    parens $ choice
        [fmap (second . (:)) typedef, fmap (first . (:)) (def topPos)]

typedef :: Parser TypeDef
typedef = do
    _ <- reserved "type"
    let onlyName = fmap (, []) big
    let nameAndSome = parens . liftA2 (,) big . some
    (name, params) <- onlyName <|> nameAndSome small'
    constrs <- many (onlyName <|> nameAndSome type_)
    pure (TypeDef name params (ConstructorDefs (Map.fromList constrs)))

def :: SrcPos -> Parser Def
def topPos = defUntyped topPos <|> defTyped topPos

defUntyped :: SrcPos -> Parser Def
defUntyped = (reserved "define" *>) . def' (pure Nothing)

defTyped :: SrcPos -> Parser Def
defTyped = (reserved "define:" *>) . def' (fmap Just scheme)

def'
    :: Parser (Maybe (WithPos Scheme))
    -> SrcPos
    -> Parser (Id, (Maybe (WithPos Scheme), Expr))
def' schemeParser topPos = varDef <|> funDef
  where
    varDef = do
        name <- small'
        scm <- schemeParser
        body <- expr
        pure (name, (scm, body))
    funDef = do
        (name, params) <- parens (liftM2 (,) small' (some small'))
        scm <- schemeParser
        body <- expr
        let fun = foldr (WithPos topPos .* Fun) body params
        pure (name, (scm, fun))

expr :: Parser Expr
expr =
    withPos $ choice [unit, charLit, str, bool, var, num, eConstructor, pexpr]

unit :: Parser Expr'
unit = reserved "unit" $> Lit Unit

num :: Parser Expr'
num = lexeme $ do
    neg <- option False (char '-' $> True)
    a <- eitherP (try (Lexer.decimal <* notFollowedBy (char '.'))) Lexer.float
    let
        e = either
            (\n -> Int (if neg then -n else n))
            (\x -> Double (if neg then -x else x))
            a
    pure (Lit e)

charLit :: Parser Expr'
charLit = lexeme
    $ fmap (Lit . Char) (between (char '\'') (char '\'') Lexer.charLiteral)

str :: Parser Expr'
str = lexeme
    $ fmap (Lit . Str) (char '"' >> manyTill Lexer.charLiteral (char '"'))

bool :: Parser Expr'
bool = do
    b <- (reserved "true" $> True) <|> (reserved "false" $> False)
    pure (Lit (Bool b))

var :: Parser Expr'
var = fmap Var small'

eConstructor :: Parser Expr'
eConstructor = fmap Constructor big'

pexpr :: Parser Expr'
pexpr = parens (choice [funMatch, match, if', fun, let', typeAscr, app])

funMatch :: Parser Expr'
funMatch = reserved "fun-match" *> fmap FunMatch cases

match :: Parser Expr'
match = do
    reserved "match"
    e <- expr
    cs <- cases
    pure (Match e cs)

cases :: Parser (NonEmpty (Pat, Expr))
cases = some' case'

case' :: Parser (Pat, Expr)
case' = parens (liftM2 (,) pat expr)

pat :: Parser Pat
pat = patTor <|> patTion <|> patVar
  where
    patTor = fmap (\x -> PConstruction (getPos x) x []) big'
    patTion = parens (liftM3 PConstruction getSrcPos big' (some pat))
    patVar = fmap PVar small'

app :: Parser Expr'
app = do
    rator <- expr
    rands <- some expr
    pure (unpos (foldl (WithPos (getPos rator) .* App) rator rands))

if' :: Parser Expr'
if' = do
    reserved "if"
    pred <- expr
    conseq <- expr
    alt <- expr
    pure (If pred conseq alt)

fun :: Parser Expr'
fun = do
    reserved "fun"
    params <- choice
        [parens (some (withPos small')), fmap (\x -> [x]) (withPos small')]
    body <- expr
    pure $ unpos
        (foldr (\(WithPos pos p) b -> WithPos pos (Fun p b)) body params)


let' :: Parser Expr'
let' = do
    reserved "let"
    bindings <- parens (some' binding)
    body <- expr
    pure (Let bindings body)

binding :: Parser Def
binding = parens (bindingTyped <|> bindingUntyped)
  where
    bindingTyped =
        reserved ":" *> liftA2 (,) small' (liftA2 (,) (fmap Just scheme) expr)
    bindingUntyped = liftA2 (,) small' (fmap (Nothing, ) expr)

typeAscr :: Parser Expr'
typeAscr = reserved ":" *> liftA2 TypeAscr expr type_

scheme :: Parser (WithPos Scheme)
scheme = withPos $ wrap nonptype <|> parens (universal <|> wrap ptype')
  where
    wrap = fmap (Forall Set.empty)
    universal = reserved "forall" *> liftA2 Forall tvars type_
    tvars = parens (fmap Set.fromList (many tvar))

type_ :: Parser Type
type_ = nonptype <|> ptype

nonptype :: Parser Type
nonptype = choice [fmap TPrim tprim, fmap TVar tvar, fmap (flip TConst []) big]

ptype :: Parser Type
ptype = parens ptype'

ptype' :: Parser Type
ptype' = tfun <|> tapp

tapp :: Parser Type
tapp = liftA2 TConst big (some type_)

tfun :: Parser Type
tfun = do
    reserved "Fun"
    t <- type_
    ts <- some type_
    pure (foldr1 TFun (t : ts))

tprim :: Parser TPrim
tprim = try $ do
    s <- big
    case s of
        "Unit" -> pure TUnit
        "Int" -> pure TInt
        "Double" -> pure TDouble
        "Char" -> pure TChar
        "Str" -> pure TStr
        "Bool" -> pure TBool
        _ -> fail $ "Undefined type constant " ++ s

tvar :: Parser TVar
tvar = fmap TVExplicit small'

-- Note that () and [] can be used interchangeably, as long as the
-- opening and closing bracket matches.
parens :: Parser a -> Parser a
parens p = choice
    (map (($ p) . uncurry between . both symbol) [("(", ")"), ("[", "]")])

big' :: Parser Id
big' = withPos big

big :: Parser String
big = try $ do
    s <- identifier
    let c = head s
    if (isUpper c || [c] == ":")
        then pure s
        else fail "Big identifier must start with an uppercase letter or colon."

small' :: Parser Id
small' = withPos small

small :: Parser String
small = try $ do
    s <- identifier
    let c = head s
    if (isUpper c || [c] == ":")
        then
            fail
                "Small identifier must not start with an uppercase letter or colon."
        else pure s

identifier :: Parser String
identifier = do
    name <- ident
    if elem name reserveds
        then unexpected (Label (toList1 ("reserved word " ++ show name)))
        else pure name

ident :: Parser String
ident = lexeme $ label "identifier" $ liftA2 (:) identStart (many identLetter)

identStart :: Parser Char
identStart =
    choice [letterChar, otherChar, try (oneOf "-+" <* notFollowedBy digitChar)]

identLetter :: Parser Char
identLetter = letterChar <|> otherChar <|> oneOf "-+" <|> digitChar

reserved :: String -> Parser ()
reserved x = do
    if not (elem x reserveds)
        then ice ("`" ++ x ++ "` is not a reserved word")
        else label ("reserved word " ++ x) (try (mfilter (== x) ident)) $> ()

lexeme :: Parser a -> Parser a
lexeme = Lexer.lexeme space

symbol :: String -> Parser String
symbol = Lexer.symbol space

reserveds :: [String]
reserveds =
    [ ":"
    , "Fun"
    , "define"
    , "define:"
    , "forall"
    , "unit"
    , "true"
    , "false"
    , "fun-match"
    , "match"
    , "if"
    , "fun"
    , "let"
    , "type"
    ]

otherChar :: Parser Char
otherChar = satisfy
    (\c -> and
        [ any ($ c) [isMark, isPunctuation, isSymbol]
        , not (elem c "()[]{}")
        , not (elem c "\"-+")
        ]
    )

some' :: Parser a -> Parser (NonEmpty a)
some' = fmap (fromJust . nonEmpty) . some

-- | Spaces, line comments, and block comments
space :: Parser ()
space = Lexer.space Char.space1 (Lexer.skipLineComment ";") empty

withPos :: Parser a -> Parser (WithPos a)
withPos = liftA2 WithPos getSrcPos

getSrcPos :: Parser SrcPos
getSrcPos = fmap SrcPos getSourcePos
