-- Mainly provides a kind checker on types
{-# LANGUAGE ImplicitParams #-}

module Checker.Kinds (kindCheckDef
                    , inferKindOfType
                    , inferKindOfType'
                    , joinCoeffectConstr
                    , hasLub
                    , joinKind) where

import Control.Monad.State.Strict
import Control.Monad.Trans.Maybe

import Checker.Monad

import Checker.Predicates
import Checker.Coeffects
import Syntax.Expr
import Syntax.Pretty
import Context
import Utils

-- Currently we expect that a type scheme has kind KType
kindCheckDef :: (?globals :: Globals) => Def -> MaybeT Checker ()
kindCheckDef (Def s _ _ _ (Forall _ quantifiedVariables ty)) = do
  -- Set up the quantified variables in the type variable context
  modify (\st -> st { tyVarContext = map (\(n, c) -> (n, (c, ForallQ))) quantifiedVariables})

  kind <- inferKindOfType' s quantifiedVariables ty
  case kind of
    KType -> modify (\st -> st { tyVarContext = [] })
    _     -> illKindedNEq s KType kind

inferKindOfType :: (?globals :: Globals) => Span -> Type -> MaybeT Checker Kind
inferKindOfType s t = do
    checkerState <- get
    inferKindOfType' s (stripQuantifiers $ tyVarContext checkerState) t

inferKindOfType' :: (?globals :: Globals) => Span -> Ctxt Kind -> Type -> MaybeT Checker Kind
inferKindOfType' s quantifiedVariables t =
    typeFoldM (TypeFold kFun kCon kBox kDiamond kVar kApp kInt kInfix) t
  where
    kFun (KConstr c) (KConstr c') | internalName c == internalName c' = return $ KConstr c
    kFun KType KType = return KType
    kFun KType y = illKindedNEq s KType y
    kFun x _     = illKindedNEq s KType x
    kCon conId = do
        st <- get
        case lookup conId (typeConstructors st) of
          Just (kind,_) -> return kind
          Nothing   -> halt $ UnboundVariableError (Just s) (pretty conId ++ " constructor.")

    kBox c KType = do
       -- Infer the coeffect (fails if that is ill typed)
       _ <- inferCoeffectType s c
       return KType
    kBox _ x = illKindedNEq s KType x

    kDiamond _ KType = return KType
    kDiamond _ x     = illKindedNEq s KType x

    kVar tyVar =
      case lookup tyVar quantifiedVariables of
        Just kind -> return kind
        Nothing   -> halt $ UnboundVariableError (Just s) $
                       "Type variable `" ++ pretty tyVar ++ "` is unbound (not quantified)." <?> show quantifiedVariables

    kApp (KFun k1 k2) kArg | k1 `hasLub` kArg = return k2
    kApp k kArg = illKindedNEq s (KFun kArg (KVar $ mkId "...")) k

    kInt _ = return $ KConstr $ mkId "Nat"

    kInfix op k1 k2 = do
      st <- get
      case lookup (mkId op) (typeConstructors st) of
       Just (KFun k1' (KFun k2' kr), _) ->
         if k1 `hasLub` k1'
          then if k2 `hasLub` k2'
               then return kr
               else illKindedNEq s k2' k2
          else illKindedNEq s k1' k1
       Nothing   -> halt $ UnboundVariableError (Just s) (pretty op ++ " operator.")

joinKind :: Kind -> Kind -> Maybe Kind
joinKind k1 k2 | k1 == k2 = Just k1
joinKind (KConstr kc1) (KConstr kc2) = fmap KConstr $ joinCoeffectConstr kc1 kc2
joinKind _ _ = Nothing

hasLub :: Kind -> Kind -> Bool
hasLub k1 k2 =
  case joinKind k1 k2 of
    Nothing -> False
    Just _  -> True
