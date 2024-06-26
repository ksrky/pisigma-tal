module Tal.Prettyprint (PprTal(..)) where

import Data.Map.Strict qualified as M
import Prettyprinter
import Tal.Syntax

class PprTal a where
    pprtal :: a -> Doc ann

instance PprTal Reg where
    pprtal (GeneralReg i) = "r" <> pretty i
    pprtal (SpecialReg s) = pretty s

instance PprTal Name where
    pprtal (Name s _) = pretty s

instance PprTal TyVar where
    pprtal = pretty

instance PprTal Ty where
    pprtal TInt                 = "int"
    pprtal (TVar i)             = "#" <> pretty i
    pprtal (TRegFile qnts rfty) = "∀" <> encloseSep "[" "]" ", " (map (const "・") qnts) <> pprtal rfty
    pprtal (TExists ty)         = "∃・." <+> pprtal ty
    pprtal (TRecurs ty)         = "μ・." <+> pprtal ty
    pprtal (TRow rty)           = "⟨" <> pprtal rty <> "⟩"
    pprtal TNonsense            = "ns"
    pprtal (TPtr sty)           = "ptr" <+> pprtal sty
    pprtal (TAlias name)        = pprtal name

instance PprTal RowTy where
    pprtal REmpty        = "ε"
    pprtal (RVar i)      = "#" <> pretty i
    pprtal (RSeq ty rty) = pprtal ty <> "," <+> pprtal rty

instance PprTal StackTy where
    pprtal SNil              = "nil"
    pprtal (SVar i)          = "#" <> pretty i
    pprtal (SCons ty sty)    = pprtal ty <+> "::" <+> pprtal sty
    pprtal (SComp sty1 sty2) = pprtal sty1 <+> "∘" <+> pprtal sty2

instance PprTal RegFileTy where
    pprtal (RegFileTy rfty mb_sty) = encloseSep "{" "}" ", " $
        map (\(reg, ty) -> pprtal reg <> ":" <+> pprtal ty) (M.toList rfty)
        ++ maybe [] (\sty -> ["sp" <> ":" <+> pprtal sty]) mb_sty

instance PprTal (Val a) where
    pprtal (VReg r) = pprtal r
    pprtal (VWord w) = pprtal w
    pprtal (VLabel l) = pprtal l
    pprtal (VInt i) = pretty i
    pprtal (VJunk ty) = "?" <> pprtal ty
    pprtal (VPack ty v ty') =
        "pack" <+> brackets (pprtal ty <> ", " <+> pprtal v) <+> "as" <+> pprtal ty'
    pprtal (VRoll v ty) = "roll" <+> parens (pprtal v) <+> "as" <+> pprtal ty
    pprtal (VUnroll v) = "unroll" <+> parens (pprtal v)
    pprtal VNonsense = "nonsense"
    pprtal (VPtr i) = "ptr" <> parens (pretty i)

instance PprTal (Name, Heap) where
    pprtal (name, HGlobal word) = "global" <+> pprtal name <+> "=" <+> pprtal word
    pprtal (name, HCode tvs rfty instrs) = pprtal name <+> "=" <+> "code" <>
        encloseSep "[" "]" ", " (map (const "・") tvs) <> "." <+> pprtal rfty <> "." <> line <> indent 2 (pprtal instrs)
    pprtal (name, HStruct ws) = "struct" <+> pprtal name <+> "=" <+>
        encloseSep "{" "}" ", " (map pprtal ws)
    pprtal (name, HExtern ty) = "extern" <+> pprtal name <+> ":" <+> pprtal ty
    pprtal (name, HTypeAlias ty) = "type" <+> pprtal name <+> "=" <+> pprtal ty

instance PprTal Aop where
    pprtal Add = "add"
    pprtal Sub = "sub"
    pprtal Mul = "mul"
    pprtal Div = "div"

instance PprTal Bop where
    pprtal Bz  = "bz"
    pprtal Bnz = "bnz"
    pprtal Bgt = "bgt"
    pprtal Blt = "blt"

instance PprTal Instr where
    pprtal (IAop aop r1 r2 v) = pprtal aop <+> pprtal r1 <> "," <+> pprtal r2 <> "," <+> pprtal v
    pprtal (IBop bop r v) = pprtal bop <+> pprtal r <> "," <+> pprtal v
    pprtal (ICall ty v) = "call" <+> pprtal ty  <> "," <+> pprtal v
    pprtal (ILoad r1 r2 i) = "ld" <+> pprtal r1 <> "," <+> pprtal r2 <> parens (pretty i)
    pprtal (IMalloc r tys) = "malloc" <+> pprtal r <+> encloseSep "[" "]" "," (map pprtal tys)
    pprtal (IMove r v) = "mv" <+> pprtal r <> "," <+> pprtal v
    pprtal (IStore r1 i r2) = "st" <+> pprtal r1 <> parens (pretty i) <> "," <+> pprtal r2
    pprtal (IUnpack r) = "unpack" <+> pprtal r
    pprtal (ISalloc n) = "salloc" <+> pretty n
    pprtal (ISfree n) = "sfree" <+> pretty n
    pprtal (ISload r1 r2 i) = "sld" <+> pprtal r1 <> "," <+> pprtal r2 <> parens (pretty i)
    pprtal (ISstore r1 i r2) = "sst" <+> pprtal r1 <> parens (pretty i) <> "," <+> pprtal r2

instance PprTal Instrs where
    pprtal (ISeq instr instrs) = vsep [hang 2 (pprtal instr), pprtal instrs]
    pprtal (IJump v)           = "jmp" <+> pprtal v
    pprtal (IHalt ty)          = "halt" <+> brackets (pprtal ty)

instance PprTal Program where
    pprtal (heaps, instrs) = vsep (map pprtal (M.toList heaps)) <> line <>
        "main =" <> line <> indent 2 (pprtal instrs)
