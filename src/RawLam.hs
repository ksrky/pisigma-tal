module RawLam (r2lProg) where

import Control.Lens.Operators
import Control.Monad.Except
import Control.Monad.Reader
import Data.Functor.Foldable
import Data.IORef
import Id
import Lambda                 qualified as L
import Lambda.Init
import Raw                    qualified as R

type Ctx = [(String, (Id, L.Ty))]

type TcM = ReaderT Ctx IO

r2lLit :: R.Lit -> L.Lit
r2lLit (R.LInt i) = L.LInt i

newTyVar :: TcM L.Ty
newTyVar = L.TMeta . L.Meta <$> liftIO (newIORef Nothing)

readMeta :: L.Meta -> IO (Maybe L.Ty)
readMeta (L.Meta ref) = readIORef ref

writeMeta :: L.Meta -> L.Ty -> IO ()
writeMeta (L.Meta ref) t = writeIORef ref (Just t)

getMetas :: L.Ty -> [L.Meta]
getMetas = cata $ \case
    L.TIntF -> []
    L.TNameF _ -> []
    L.TFunF t1 t2 -> t1 ++ t2
    L.TTupleF ts -> concat ts
    L.TMetaF m -> [m]

unify :: L.Ty -> L.Ty -> IO ()
unify L.TInt L.TInt = return ()
unify (L.TName x) (L.TName y) | x == y = return ()
unify (L.TFun t1 t2) (L.TFun t1' t2') = do
    unify t1 t1'
    unify t2 t2'
unify (L.TMeta m1) (L.TMeta m2) | m1 == m2 = return ()
unify (L.TMeta m) t = unifyMeta m t
unify t (L.TMeta m) = unifyMeta m t
unify t1 t2 = fail $ "type mismatched. expected " ++ show t1 ++ ", but got " ++ show t2

unifyMeta :: L.Meta -> L.Ty -> IO ()
unifyMeta m1 t2 = do
    mbt1 <- readMeta m1
    case (mbt1, t2) of
        (Just t1, _) -> unify t1 t2
        (Nothing, L.TMeta m2) ->
            readMeta m2 >>= \case
                Just t2' -> unify (L.TMeta m1) t2'
                Nothing -> writeMeta m1 t2
        (Nothing, _) -> do
            occursCheck m1 t2
            writeMeta m1 t2

occursCheck :: L.Meta -> L.Ty -> IO ()
occursCheck tv1 ty2 = do
    let tvs2 = getMetas ty2
    when (tv1 `elem` tvs2) $ fail "occurs check failed"

r2lExp :: R.Exp -> TcM L.Exp
r2lExp e = do
    exp_ty <- newTyVar
    e' <- checkExp e exp_ty
    return $ L.EAnnot e' exp_ty

checkExp :: R.Exp -> L.Ty -> TcM L.Exp
checkExp (R.ELit l) exp_ty = do
    lift $ unify exp_ty L.TInt
    return $ L.ELit (r2lLit l)
checkExp (R.EVar x) exp_ty = do
    ctx <- ask
    case lookup x ctx of
        Just (x', t) -> do
            lift $ unify exp_ty t
            return $ L.EVar (x', t)
        Nothing -> fail "unbound variable"
checkExp (R.ELab l) exp_ty = do
    ctx <- ask
    case lookup l ctx of
        Just (_, t) -> do
            lift $ unify exp_ty t
            return $ L.ELab l t
        Nothing      -> fail "unknown label"
checkExp (R.EApp e1 e2) exp_ty = do
    t2 <- newTyVar
    e1' <- checkExp e1 (L.TFun t2 exp_ty)
    e2' <- checkExp e2 t2
    return $ L.EAnnot (L.EApp e1' e2') exp_ty
checkExp (R.ELam x e) exp_ty = do
    x' <- mkId x
    t1 <- newTyVar
    t2 <- newTyVar
    lift $ unify exp_ty (L.TFun t1 t2)
    e' <- local ((x, (x', t1)):) $ checkExp e t2
    return $ L.EAnnot (L.ELam (x', t1) e') exp_ty
checkExp (R.EBinOp op e1 e2) exp_ty = do
    ctx <- ask
    op' <- case lookup op ctx of
        Just op' -> return op'
        Nothing  -> fail "unknown binop"
    case snd op' of
        L.TFun (L.TTuple [t1', t2']) tr -> do
            e1' <- checkExp e1 t1'
            e2' <- checkExp e2 t2'
            lift $ unify exp_ty tr
            return $ L.EAnnot (L.EApp (L.EVar op') (L.ETuple [e1', e2'])) exp_ty
        _ -> fail "required binary function type"
checkExp (R.ELet xes e2) exp_ty = do
    xes' <- forM xes $ \(x, e) -> do
        x' <- mkId x
        t <- newTyVar
        e' <- checkExp e t
        return ((x', t), e')
    e2' <- local (map (\(x, _) -> (fst x ^. name, x)) xes' ++) $ checkExp e2 exp_ty
    return $ L.EAnnot (foldr (uncurry L.ELet) e2' xes') exp_ty
checkExp (R.ELetrec xes e2) exp_ty = do
    env <- forM xes $ \(x, _) -> do
        x' <- mkId x
        tv <- newTyVar
        return (x, (x', tv))
    local (env ++) $ do
        xes' <- zipWithM (\(_, x) (_, e) -> do
            e' <- checkExp e (snd x)
            return (x, e')) env xes
        e2' <- local (env ++) $ checkExp e2 exp_ty
        return $ L.EAnnot (L.ELetrec xes' e2') exp_ty
checkExp (R.EIf e1 e2 e3) exp_ty = do
    e1' <- checkExp e1 tyBool
    e2' <- checkExp e2 exp_ty
    e3' <- checkExp e3 exp_ty
    return $ L.EAnnot (L.ECase (L.EAnnot e1' tyBool) [("True", e2'), ("False", e3')]) exp_ty

class Zonking a where
    zonk :: a -> IO a

instance Zonking L.Ty where
    zonk :: L.Ty -> IO L.Ty
    zonk = cata $ \case
        L.TIntF -> return L.TInt
        L.TNameF x -> return $ L.TName x
        L.TFunF t1 t2 -> L.TFun <$> t1 <*> t2
        L.TTupleF ts -> L.TTuple <$> sequence ts
        L.TMetaF m -> readMeta m >>= \case
            Nothing -> return L.TInt -- return $ L.TMeta m
            Just t -> do
                t' <- zonk t
                writeMeta m t'
                -- return t'
                -- tmp: unsolved meta is coerced to TInt
                case t' of
                    L.TMeta _ -> return L.TInt
                    _         -> return t'

instance Zonking L.Var where
    zonk (x, t) = (x,) <$> zonk t

instance Zonking L.Exp where
    zonk = cata $ \case
        L.ELitF l -> return $ L.ELit l
        L.EVarF x -> L.EVar <$> zonk x
        L.ELabF l t -> return $ L.ELab l t
        L.EAppF e1 e2 -> L.EApp <$> e1 <*> e2
        L.ELamF x e -> L.ELam <$> zonk x <*> e
        L.ELetF x e1 e2 -> L.ELet <$> zonk x <*> e1 <*> e2
        L.ELetrecF xes e2 -> L.ELetrec <$> mapM (\(x, e) -> ((,) <$> zonk x) <*> e) xes <*> e2
        L.ETupleF es -> L.ETuple <$> sequence es
        L.ECaseF e les -> L.ECase <$> e <*> mapM (\(l, ei) -> (l,) <$> ei) les
        L.EAnnotF e t -> L.EAnnot <$> e <*> zonk t

r2lProg :: R.Program -> IO L.Program
r2lProg raw_prog = do
    e <- zonk =<< runReaderT (r2lExp raw_prog) initCtx
    return (initEnv, e)
