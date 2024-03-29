module PisigmaTal.Parser (pExp, parseProgram) where

import Control.Monad
import Control.Monad.Combinators.Expr
import Data.Text                      (Text)
import Data.Text                      qualified as Text
import Data.Void
import PisigmaTal.Raw
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer     qualified as L

type Parser = Parsec Void Text

sc :: Parser ()
sc = L.space
        space1
        (L.skipLineComment "//")
        (L.skipBlockComment "/-" "-/")

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

charL :: Char -> Parser Char
charL = lexeme . char

stringL :: Text -> Parser Text
stringL = lexeme . string

parens :: Parser a -> Parser a
parens = lexeme . between (char '(') (char ')')

pName :: Parser String
pName = do
    x <- lexeme ((:) <$> lowerChar <*> many alphaNumChar) <?> "Name"
    guard (x `notElem` ["let", "in", "rec", "and", "if", "then", "else"])
    return x

pLabel :: Parser String
pLabel = lexeme ((:) <$> upperChar <*> many alphaNumChar) <?> "Label"

pLit :: Parser Lit
pLit = LInt <$> lexeme L.decimal <?> "Lit"

pELit :: Parser Exp
pELit = ELit <$> pLit <?> "ELit"

pEVar :: Parser Exp
pEVar = EVar <$> pName <?> "EVar"

pELabel :: Parser Exp
pELabel = ELabel <$> pLabel <?> "ELabel"

pEApp :: Parser Exp
pEApp = do
    e1 <- pExp1
    es <- some $ try pExp1
    return (foldl EApp e1 es) <?> "EApp"

pELam :: Parser Exp
pELam = ELam <$> (charL '\\' *> pName) <* stringL "->" <*> pExp <?> "ELam"

pBind :: Parser (String, Exp)
pBind = (,) <$> pName <* charL '=' <*> lexeme pExp <?> "Binding"

pBinds :: Parser [(String, Exp)]
pBinds = pBind `sepBy` stringL "and" <?> "Bindings"

pELet :: Parser Exp
pELet = ELet <$> (stringL "let" *> pBinds) <* stringL "in" <*> pExp <?> "ELet"

pELetrec :: Parser Exp
pELetrec = ELetrec <$> (stringL "let rec" *> pBinds) <* stringL "in" <*> pExp <?> "ELet"

pEIf :: Parser Exp
pEIf = EIf <$> (stringL "if" *> pExp) <*> (stringL "then" *> pExp) <*> (stringL "else" *> pExp) <?> "EIf"

pExp1 :: Parser Exp
pExp1 =
    pELit
    <|> pEVar
    <|> pELabel
    <|> parens pExp <?> "Exp1"

pExp2 :: Parser Exp
pExp2 = makeExprParser (try pEApp <|> pExp1) table <?> "Exp2"
  where
    table =
        [ [InfixL (EBinOp . Text.unpack <$> stringL "*"), InfixL (EBinOp . Text.unpack <$> stringL "/")]
        , [InfixL (EBinOp . Text.unpack <$> stringL "+"), InfixL (EBinOp . Text.unpack <$> stringL "-")]
        , [InfixL (EBinOp . Text.unpack <$> stringL "==")]
        ]

pExp :: Parser Exp
pExp = lexeme (pELam <|> try pELetrec <|> pELet <|> pEIf <|> pExp2) <?> "Exp"

pProgram :: Parser Program
pProgram = pExp <* eof <?> "Program"

parseProgram :: MonadFail m => Text -> m Program
parseProgram inp = case runParser pProgram "main" inp of
    Left err   -> fail $ errorBundlePretty err
    Right prog -> return prog
