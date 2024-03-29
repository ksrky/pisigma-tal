{-# LANGUAGE TemplateHaskell #-}

module PisigmaTal.Alloc (
    Ty (..),
    TyF(..),
    RowTy(..),
    RowTyF(..),
    Const (..),
    Val (..),
    ValF (..),
    Primop(..),
    Bind (..),
    Exp (..),
    ExpF (..),
    Heap (..),
    Program,
    shiftTy,
    substTop,
    Typeable(..)
) where

import Control.Lens.At
import Control.Lens.Operators
import Data.Functor.Foldable
import Data.Functor.Foldable.TH (MakeBaseFunctor (makeBaseFunctor))
import PisigmaTal.Id
import PisigmaTal.Idx
import Prettyprinter            hiding (pretty)
import Prettyprinter.Prec

data Ty
    = TInt
    | TVar Int
    | TFun [Ty] Ty
    | TExists Ty
    | TRecurs Ty
    | TRow RowTy
    | TAlias Id (Maybe Ty)
    deriving (Eq, Show)

infixr 5 :>

data RowTy = REmpty | RVar Int | Ty :> RowTy
    deriving (Eq, Show)

type instance Index RowTy = Idx

type instance IxValue RowTy = Ty
instance Ixed RowTy where
    ix _ _ REmpty             = pure REmpty
    ix _ _ (RVar x)           = pure $ RVar x
    ix Idx1 f (ty :> row)     = f ty <&> (:> row)
    ix (IdxS k) f (ty :> row) = (ty :>) <$> ix k f row

data Primop = Add | Sub | Mul
    deriving (Eq, Show)

data Const
    = CInt Int
    | CPrimop Primop Ty
    | CGlobal Id Ty
    deriving (Eq, Show)

data Val
    = VVar Int Ty
    | VConst Const
    | VPack Ty Val Ty
    | VFixPack [(Ty, Val, Ty)]
    | VRoll Val Ty
    | VUnroll Val
    | VAnnot Val Ty
    deriving (Eq, Show)

data Bind
    = BVal Ty Val
    | BCall Ty Val [Val]
    | BProj Ty Val Idx
    | BUnpack Ty Val
    | BMalloc Ty [Ty]
    | BUpdate Ty Val Idx Val
    deriving (Eq, Show)

data Exp
    = ELet Bind Exp
    | ECase Val [Exp]
    | EReturn Val
    | EAnnot Exp Ty
    deriving (Eq, Show)

data Heap
    = HGlobal Ty Val
    | HCode [Ty] Ty Exp
    | HExtern Ty
    | HTypeAlias Ty
    deriving (Eq, Show)

type Program = ([(Id, Heap)], Exp)

makeBaseFunctor ''Ty
makeBaseFunctor ''RowTy
makeBaseFunctor ''Val
makeBaseFunctor ''Exp

mapTy :: (Int -> Int -> Ty) -> Int -> Ty -> Ty
mapTy onvar = flip $ cata $ \case
    TIntF -> const TInt
    TVarF x -> onvar x
    TFunF arg_tys ret_ty -> \c -> TFun (map ($ c) arg_tys) (ret_ty c)
    TExistsF ty -> \c -> TExists (ty (c + 1))
    TRecursF ty -> \c -> TRecurs (ty (c + 1))
    TRowF row_ty -> \c -> TRow $ mapRowTy onvar c row_ty
    TAliasF x mb_ty -> \c -> TAlias x (mb_ty <*> pure (c + 1))

mapRowTy :: (Int -> Int -> Ty) -> Int -> RowTy -> RowTy
mapRowTy onvar c = cata $ \case
    REmptyF -> REmpty
    RVarF x -> case onvar x c of
        TRow row -> row
        TVar y   -> RVar y
        _        -> error "TRow or TVar required"
    ty :>$ row -> mapTy onvar c ty :> row

shiftTy :: Int -> Ty -> Ty
shiftTy d = mapTy (\x c -> TVar (if x < c then x else x + d)) 0

substTy :: Ty -> Ty -> Ty
substTy s = mapTy (\x j -> if x == j then shiftTy j s else TVar x) 0

substTop :: Ty -> Ty -> Ty
substTop s t = shiftTy (-1) (substTy (shiftTy 1 s) t)

class Typeable a where
    typeof :: a -> Ty

instance Typeable Ty where
    typeof = id

instance Typeable Val where
    typeof = \case
        VVar _ t -> t
        VConst (CGlobal _ t) -> t
        VConst (CPrimop _ t) -> t
        VConst (CInt _) -> TInt
        VPack _ _ t -> t
        VFixPack _ -> undefined
        VRoll _ t -> t
        VUnroll v ->
            case typeof v of
                TRecurs t -> substTop (TRecurs t) t
                _         -> error "required recursive type"
        VAnnot _ t -> t

instance Typeable Exp where
    typeof = cata $ \case
        ELetF _ t -> t
        ECaseF _ ts -> head ts
        EReturnF v -> typeof v
        EAnnotF _ t -> t

instance PrettyPrec Primop where
    pretty = \case
        Add -> "add"; Sub -> "sub"; Mul -> "mul"

instance PrettyPrec Const where
    pretty (CInt i)      = pretty i
    pretty (CPrimop p _) = pretty p
    pretty (CGlobal f _) = pretty f

instance PrettyPrec Ty where
    prettyPrec _ TInt = "Int"
    prettyPrec _ (TVar i) = "`" <> pretty i
    prettyPrec p (TFun ts t) = parPrec p 2 $
        parens (hsep $ punctuate "," $ map (prettyPrec 1) ts) <+> "->" <+> prettyPrec 2 t
    prettyPrec p (TExists t) = parPrec p 0 $ "∃_" <> dot <+> pretty t
    prettyPrec p (TRecurs t) = parPrec p 0 $ "μ_" <> dot <+> pretty t
    prettyPrec _ (TRow r) = braces $ pretty r
    prettyPrec _ (TAlias x _) = pretty x

instance PrettyPrec RowTy where
    pretty REmpty      = "ε"
    pretty (RVar i)    = "`" <> pretty i
    pretty (ty :> row) = pretty ty <> "," <+> pretty row

instance PrettyPrec Val where
    prettyPrec _ (VVar i _)    = "`" <> pretty i
    prettyPrec _ (VConst c)    = pretty c
    prettyPrec p (VPack t1 v t2) = parPrec p 0 $ hang 2 $
        hsep ["pack", brackets (pretty t1 <> "," <+> pretty v) <> softline <> "as", prettyPrec 2 t2]
    prettyPrec _ (VFixPack _)  = error "prettyPrec Val: VFixPack"
    prettyPrec p (VRoll v t)   = parPrec p 0 $ hang 2 $ hsep ["roll", prettyMax v <> softline <> "as", prettyPrec 2 t]
    prettyPrec p (VUnroll v)   = parPrec p 0 $ "unroll" <+> prettyPrec 1 v
    prettyPrec _ (VAnnot v t)  = parens $ hang 2 $ sep [pretty v, ":" <+> pretty t]

instance PrettyPrec Bind where
    pretty (BVal _ v) = "_ =" <+> pretty v
    pretty (BCall _ f vs) = "_ =" <+> pretty f <+> hsep (map pretty vs)
    pretty (BProj _ v i) = "_ =" <+> pretty v <> "." <> pretty i
    pretty (BUnpack t v) = "[_, _ :" <+> pretty t <> "] = unpack" <+> pretty v
    pretty (BMalloc _ ts) = "_ = malloc" <+> brackets (hsep (punctuate ", " (map pretty ts)))
    pretty (BUpdate _ v1 i v2) = "_ =" <+> pretty v1 <> brackets (pretty i) <+> "<-" <+> pretty v2

instance PrettyPrec Exp where
    pretty (ELet b e)   = vsep [hang 2 ("let" <+> pretty b) <+> "in", pretty e]
    pretty (ECase v es) = vsep [ "case" <+> pretty v <+> "of"
                               , "  " <> align (vsep (map (\ei -> hang 2 $ sep ["_ ->", pretty ei]) es))]
    pretty (EReturn v)  = "ret" <+> prettyMax v
    pretty (EAnnot e t) = parens $ hang 2 $ sep [pretty e, ":" <+> pretty t]

instance PrettyPrec (Id, Heap) where
    pretty (x, HGlobal t v) = pretty x <+> ":" <+> pretty t <+> "=" <+> pretty v
    pretty (x, HCode ts1 t2 e) = pretty x <+> "="
        <+> parens (hsep $ punctuate ", " $ map (\t -> "_ :" <+> pretty t) ts1)
        <+> ":" <+> pretty t2 <+> "=" <+> pretty e
    pretty (x, HExtern t) = "extern" <+> pretty x <+> "=" <+> pretty t
    pretty (x, HTypeAlias t) = "type" <+> pretty x <+> "=" <+> pretty t

instance PrettyPrec Program where
    pretty (hs, e) = vsep (map pretty hs) <> line <> pretty e
