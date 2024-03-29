{-# LANGUAGE TemplateHaskell #-}

module PisigmaTal.ClosureAlloc (closureAllocProgram) where

import Control.Lens.Combinators hiding (op)
import Control.Lens.Operators
import Control.Monad.Reader
import Control.Monad.Writer
import Data.Functor.Foldable
import Data.List                qualified as List
import Data.Maybe
import PisigmaTal.Alloc         qualified as A
import PisigmaTal.Closure       qualified as C
import PisigmaTal.Id
import PisigmaTal.Idx
import Prelude                  hiding (exp)

data Ctx = Ctx {
    _varScope    :: [Id],
    _labelIndex  :: [(C.Label, Int)],
    _typeAliases :: [(Id, A.Ty)]
}

makeLenses ''Ctx

type CtxM = ReaderT Ctx IO

runCtxM :: CtxM a -> IO a
runCtxM m = runReaderT m (Ctx [] [] [])

closureAllocTy :: C.Ty -> CtxM A.Ty
closureAllocTy = cata $ \case
    C.TIntF -> return A.TInt
    C.TVarF x -> do
        vsc <- view varScope
        case List.elemIndex x vsc of
            Just i  -> return $ A.TVar i
            Nothing -> fail $ "unbound type variable: " ++ show x
    C.TNameF x -> do
        tas <- view typeAliases
        return $ A.TAlias x (lookup x tas)
    C.TFunF ts1 t2 -> A.TFun <$> sequence ts1 <*> t2
    C.TExistsF x t -> A.TExists <$> locally varScope (x :) t
    C.TRecursF x t -> A.TRecurs <$> locally varScope (x :) t
    C.TRowF row -> A.TRow <$> closureAllocRowTy row

closureAllocRowTy :: C.RowTy -> CtxM A.RowTy
closureAllocRowTy = cata $ \case
    ty C.:>$ row -> do
        ty' <- closureAllocTy ty
        (ty' A.:>) <$> row
    C.RVarF x -> do
        vsc <- view varScope
        case List.elemIndex x vsc of
            Just idx -> return $ A.RVar idx
            Nothing  -> fail $ "unbound type variable: " ++ show x
    C.REmptyF -> return A.REmpty

closureAllocLit :: C.Lit -> A.Const
closureAllocLit (C.LInt i) = A.CInt i

closureAllocVal :: C.Val -> WriterT [A.Bind] CtxM A.Val
closureAllocVal (C.VLit l)      = return $ A.VConst (closureAllocLit l)
closureAllocVal (C.VVar (x, t)) = do
    vsc <- view varScope
    case List.elemIndex x vsc of
        Just i  -> lift $ A.VVar i <$> closureAllocTy t
        Nothing -> fail $ "unbound variable: " ++ show x
closureAllocVal (C.VFun (f, t)) = lift $ A.VConst <$> (A.CGlobal f <$> closureAllocTy t)
closureAllocVal (C.VLabel l _) = do
    labix <- view labelIndex
    case lookup l labix of
        Just i  -> return $ A.VConst (A.CInt i)
        Nothing -> fail $ "label not found: " ++ show l
closureAllocVal (C.VTuple vals) = do
    let n_vals = length vals
    tys <- lift $ mapM (closureAllocTy . C.typeof) vals
    let rowty = A.TRow $ foldr (A.:>) A.REmpty tys
        bind0 = A.BMalloc rowty tys
    binds <- forM [1 .. n_vals] $ \i -> do
        val <- locally varScope (replicate i dummyId ++) $ closureAllocVal (vals !! (i - 1))
        return $ A.BUpdate rowty (A.VVar 0 rowty) (intToIdx i) val
    tell (bind0 : binds)
    return $ A.VVar 0 rowty
closureAllocVal (C.VPack t1 v t2) =
    A.VPack <$> lift (closureAllocTy t1) <*> closureAllocVal v <*> lift (closureAllocTy t2)
closureAllocVal (C.VRoll v t) = do
    A.VRoll <$> closureAllocVal v <*> lift (closureAllocTy t)
closureAllocVal (C.VUnroll v) =
    A.VUnroll <$> closureAllocVal v
closureAllocVal (C.VAnnot v t) =
    A.VAnnot <$> closureAllocVal v <*> lift (closureAllocTy t)

dummyIds :: [A.Bind] -> [Id]
dummyIds bs = replicate (length bs) dummyId

closureAllocExp :: C.Exp -> CtxM A.Exp
closureAllocExp (C.ELet (C.BVal x val) exp) = do
    ty <- closureAllocTy (snd x)
    (val', binds) <- runWriterT $ closureAllocVal val
    exp' <- locally varScope ((fst x : dummyIds binds) ++) $ closureAllocExp exp
    return $ foldr A.ELet exp' (binds |> A.BVal ty val')
closureAllocExp (C.ELet (C.BCall x fun args) exp) = do
    ty <- closureAllocTy (snd x)
    fun' <- case fun of
        C.KnownFun (f, fty) |  "#" `List.isInfixOf` (f ^. name) -> do
            fty' <- closureAllocTy fty
            case f ^. name of
                "#add" -> return $ A.VConst (A.CPrimop A.Add fty')
                "#sub" -> return $ A.VConst (A.CPrimop A.Sub fty')
                "#mul" -> return $ A.VConst (A.CPrimop A.Mul fty')
                _      -> fail $ "unknown primitive: " ++ show f
        C.KnownFun (f, fty) -> A.VConst . A.CGlobal f <$> closureAllocTy fty
        C.LocalFun (f, fty) -> do
            vsc <- view varScope
            case List.elemIndex f vsc of
                Just i  -> A.VVar i <$> closureAllocTy fty
                Nothing -> fail $ "unknown function: " ++ show f
    (args', bindss) <- mapAndUnzipM (runWriterT . closureAllocVal) args
    let binds = concat bindss
    exp' <- locally varScope ((fst x : dummyIds binds) ++) $ closureAllocExp exp
    return $ foldr A.ELet exp' (binds |> A.BCall ty fun' args')
closureAllocExp (C.ELet (C.BProj x v i) e) = do
    ty <- closureAllocTy (snd x)
    (v', binds) <- runWriterT $ closureAllocVal v
    e' <- locally varScope ((fst x : dummyIds binds) ++) $ closureAllocExp e
    return $ foldr A.ELet e' (binds |> A.BProj ty v' i)
closureAllocExp (C.ELet (C.BUnpack tv x v) e) = do
    ty <-  locally varScope (tv :) $ closureAllocTy (snd x)
    (v', binds) <- runWriterT $ closureAllocVal v
    e' <- locally varScope ((fst x : tv : dummyIds binds) ++) $ closureAllocExp e
    return $ foldr A.ELet e' (binds |> A.BUnpack ty v')
closureAllocExp (C.ELetrec binds exp) = do
    let bindIds = map (fst . C.bindVar) binds
    binds' <- locally varScope (reverse bindIds ++) $ do
        (packs, binds') <- runWriterT $ forM binds $ \case
            C.BVal _ (C.VPack ty1 val ty2) -> do
                ty1' <- lift $ closureAllocTy ty1
                val' <- closureAllocVal val
                ty2' <- lift $ closureAllocTy ty2
                return (ty1', val', ty2')
            _ -> fail "not supported yet"
        let pack_tys = map (view _3) packs
            packs_ty = A.TRow $ foldr (A.:>) A.REmpty pack_tys
            binds'' = A.BVal packs_ty (A.VFixPack packs) :
                map (\i -> A.BProj (pack_tys !! i) (A.VVar i packs_ty) (intToIdx (i + 1))) [0 .. length binds - 1]
        return $ binds' ++ binds''
    exp' <- locally varScope ((dummyIds binds' ++ [dummyId] ++ reverse bindIds) ++) $ closureAllocExp exp
    return $ foldr A.ELet exp' binds'
closureAllocExp (C.ECase v les) = do
    (v', bs) <- runWriterT $ closureAllocVal v
    ies' <- forM les $ \(l, e) -> do
        labix <- view labelIndex
        case lookup l labix of
            Just i  -> (i,) <$> closureAllocExp e
            Nothing -> fail $ "label not found: " ++ show l
    es' <- forM [1..length les] $ \i -> case lookup i ies' of
        Just e  -> return e
        Nothing -> fail "label index not found"
    return $ foldr A.ELet (A.ECase v' es') bs
closureAllocExp (C.EReturn v) = do
    (v', bs) <- runWriterT $ closureAllocVal v
    return $ foldr A.ELet (A.EReturn v') bs
closureAllocExp (C.EAnnot e t) = A.EAnnot <$> closureAllocExp e <*> closureAllocTy t

closureAllocDecs :: [C.Dec] -> WriterT [(Id, A.Heap)] CtxM a -> WriterT [(Id, A.Heap)] CtxM a
closureAllocDecs [] cont = cont
closureAllocDecs (C.DEnum x ls : decs) cont = do
    tell [(x, A.HTypeAlias A.TInt)]
    tell $ zipWith (\l i -> (x, A.HGlobal (A.TAlias (newIdUnsafe l) (Just A.TInt)) (A.VConst (A.CInt i)))) ls [0 ..]
    locally typeAliases ((x, A.TInt) :)
        $ locally labelIndex (zip ls [0 ..] ++) $ closureAllocDecs decs cont
closureAllocDecs (C.DBind x t : decs) cont = do
    t' <- lift $ closureAllocTy t
    tell [(x, A.HExtern t')]
    closureAllocDecs decs cont

closureAllocTopExp :: C.TopExp -> WriterT [(Id, A.Heap)] CtxM A.Exp
closureAllocTopExp (defns, exp) = do
    forM_ defns $ \(f, C.Code xs e) -> do
        arg_tys <- lift $ mapM (closureAllocTy . snd) xs
        ret_ty <- lift $ closureAllocTy (C.typeof e)
        e' <- lift $ locally varScope (reverse (map fst xs) ++) $ closureAllocExp e
        tell [(fst f, A.HCode arg_tys ret_ty e')]
    lift $ closureAllocExp exp

closureAllocProgram :: C.Program -> IO A.Program
closureAllocProgram (decs, texp) = runCtxM $ do
    (exp', heaps) <- runWriterT $
        closureAllocDecs decs $
        closureAllocTopExp texp
    return (heaps, exp')
