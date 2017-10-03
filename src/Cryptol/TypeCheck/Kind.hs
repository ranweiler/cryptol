-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE Safe #-}
module Cryptol.TypeCheck.Kind
  ( checkType
  , checkSchema
  , checkNewtype
  , checkTySyn
  , checkPropSyn
  , checkParameterType
  , checkParameterConstraints
  ) where

import qualified Cryptol.Parser.AST as P
import           Cryptol.Parser.AST (Named(..))
import           Cryptol.Parser.Position
import           Cryptol.ModuleSystem.Name(nameUnique)
import           Cryptol.TypeCheck.AST
import           Cryptol.TypeCheck.Monad hiding (withTParams)
import           Cryptol.TypeCheck.SimpType(tRebuild)
import           Cryptol.TypeCheck.Solve (simplifyAllConstraints
                                         ,wfTypeFunction)
import           Cryptol.Utils.PP
import           Cryptol.Utils.Panic (panic)

import qualified Data.Map as Map
import           Data.List(sortBy,groupBy)
import           Data.Maybe(fromMaybe)
import           Data.Function(on)
import           Control.Monad(unless,forM)



-- | Check a type signature.
checkSchema :: P.Schema Name -> InferM (Schema, [Goal])
checkSchema (P.Forall xs ps t mb) =
  do ((xs1,(ps1,t1)), gs) <-
        collectGoals $
        rng $ withTParams True schemaParam xs $
        do ps1 <- mapM checkProp ps
           t1  <- doCheckType t (Just KType)
           return (ps1,t1)
     return ( Forall xs1 (map tRebuild ps1) (tRebuild t1)
            , [ g { goal = tRebuild (goal g) } | g <- gs ]
            )

  where
  rng = case mb of
          Nothing -> id
          Just r  -> inRange r

checkParameterType :: P.ParameterType Name -> Maybe String -> InferM TParam
checkParameterType a mbDoc = -- XXX: Save the doc somewhere.
  do let k = cvtK (P.ptKind a)
         n = thing (P.ptName a)
     return TParam { tpUnique = nameUnique n -- XXX: ok to reuse?
                   , tpKind = k
                   , tpFlav = TPModParam n
                   }


-- | Check a type-synonym declaration.
checkTySyn :: P.TySyn Name -> Maybe String -> InferM TySyn
checkTySyn (P.TySyn x as t) mbD =
  do ((as1,t1),gs) <- collectGoals
                    $ inRange (srcRange x)
                    $ do r <- withTParams False tySynParam as
                                                      (doCheckType t Nothing)
                         simplifyAllConstraints
                         return r
     return TySyn { tsName   = thing x
                  , tsParams = as1
                  , tsConstraints = map (tRebuild . goal) gs
                  , tsDef = tRebuild t1
                  , tsDoc = mbD
                  }

-- | Check a constraint-synonym declaration.
checkPropSyn :: P.PropSyn Name -> Maybe String -> InferM TySyn
checkPropSyn (P.PropSyn x as ps) mbD =
  do ((as1,t1),gs) <- collectGoals
                    $ inRange (srcRange x)
                    $ do r <- withTParams False propSynParam as
                                                      (traverse checkProp ps)
                         simplifyAllConstraints
                         return r
     return TySyn { tsName   = thing x
                  , tsParams = as1
                  , tsConstraints = map (tRebuild . goal) gs
                  , tsDef = tRebuild (pAnd t1)
                  , tsDoc = mbD
                  }

-- | Check a newtype declaration.
-- XXX: Do something with constraints.
checkNewtype :: P.Newtype Name -> Maybe String -> InferM Newtype
checkNewtype (P.Newtype x as fs) mbD =
  do ((as1,fs1),gs) <- collectGoals $
       inRange (srcRange x) $
       do r <- withTParams False newtypeParam as $
               forM fs $ \field ->
                 let n = name field
                 in kInRange (srcRange n) $
                    do t1 <- doCheckType (value field) (Just KType)
                       return (thing n, t1)
          simplifyAllConstraints
          return r

     return Newtype { ntName   = thing x
                    , ntParams = as1
                    , ntConstraints = map goal gs
                    , ntFields = fs1
                    , ntDoc = mbD
                    }



checkType :: P.Type Name -> Maybe Kind -> InferM Type
checkType t k =
  do (_, t1) <- withTParams True schemaParam {-no params-} [] $ doCheckType t k
     return (tRebuild t1)

checkParameterConstraints :: [P.Prop Name] -> InferM [Prop]
checkParameterConstraints ps =
  do (_, cs) <- withTParams False schemaParam {-no params-}[]
                                                        (mapM checkProp ps)
     return (map tRebuild cs)


{- | Check something with type parameters.

When we check things with type parameters (i.e., type schemas, and type
synonym declarations) we do kind inference based only on the immediately
visible body.  Type parameters that are not mentioned in the body are
defaulted to kind 'KNum'.  If this is not the desired behavior, programmers
may add explicit kind annotations on the type parameters.

Here is an example of how this may show up:

> f : {n}. [8] -> [8]
> f x =  x + `n

Note that @n@ does not appear in the body of the schema, so we will
default it to 'KNum', which is the correct thing in this case.
To use such a function, we'd have to provide an explicit type application:

> f `{n = 3}

There are two reasons for this choice:

  1. It makes it possible to figure if something is correct without
     having to look through arbitrary amounts of code.

  2. It is a bit easier to implement, and it covers the large majority
     of use cases, with a very small inconvenience (an explicit kind
     annotation) in the rest.
-}

withTParams :: Bool              {- ^ Do we allow wild cards -} ->
              (Name -> TPFlavor) {- ^ What sort of params are these? -} ->
              [P.TParam Name]    {- ^ The params -} ->
              KindM a            {- ^ do this using the params -} ->
              InferM ([TParam], a)
withTParams allowWildCards flav xs m =
  do (as,a,ctrs) <-
        mdo mapM_ recordError duplicates
            (a, vars,ctrs) <- runKindM allowWildCards (zip' xs ts) m
            (as, ts)  <- unzip `fmap` mapM (newTP vars) xs
            return (as,a,ctrs)
     mapM_ (uncurry newGoals) ctrs
     return (as,a)

  where
  getKind vs tp =
    case Map.lookup (P.tpName tp) vs of
      Just k  -> return k
      Nothing -> do recordWarning (DefaultingKind tp P.KNum)
                    return KNum

  newTP vs tp = do k <- getKind vs tp
                   n <- newTParam (flav (P.tpName tp)) k
                   return (n, TVar (tpVar n))


  {- Note that we only zip based on the first argument.
  This is needed to make the monadic recursion work correctly,
  because the data dependency is only on the part that is known. -}
  zip' [] _           = []
  zip' (a:as) ~(t:ts) = (P.tpName a, fmap cvtK (P.tpKind a), t) : zip' as ts

  duplicates = [ RepeatedTyParams ds
                    | ds@(_ : _ : _) <- groupBy ((==) `on` P.tpName)
                                      $ sortBy (compare `on` P.tpName) xs ]

cvtK :: P.Kind -> Kind
cvtK P.KNum  = KNum
cvtK P.KType = KType



-- | Check an application of a type constant.
tcon :: TCon            -- ^ Type constant being applied
     -> [P.Type Name]   -- ^ Type parameters
     -> Maybe Kind      -- ^ Expected kind
     -> KindM Type      -- ^ Resulting type
tcon tc ts0 k =
  do (ts1,k1) <- appTy ts0 (kindOf tc)
     checkKind (TCon tc ts1) k k1

-- | Check a use of a type-synonym, newtype, abs type, or scoped-type variable.
tySyn :: Bool         -- ^ Should we check for scoped type vars.
      -> Name         -- ^ Name of type sysnonym
      -> [P.Type Name]-- ^ Type synonym parameters
      -> Maybe Kind   -- ^ Expected kind
      -> KindM Type   -- ^ Resulting type
tySyn scoped x ts k =
  do mb <- kLookupTSyn x
     case mb of
       Just (tysyn@(TySyn { tsName = f, tsParams = as
                          , tsConstraints = ps, tsDef = def })) ->
          do (ts1,k1) <- appTy ts (kindOf tysyn)
             ts2 <- checkParams as ts1
             let su = zip as ts2
             ps1 <- mapM (`kInstantiateT` su) ps
             kNewGoals (CtPartialTypeFun (UserTyFun f)) ps1
             t1  <- kInstantiateT def su
             checkKind (TUser x ts1 t1) k k1

       -- Maybe it is a newtype?
       Nothing ->
         do mbN <- kLookupNewtype x
            case mbN of
              Just nt ->
                do let tc = newtypeTyCon nt
                   (ts1,_) <- appTy ts (kindOf tc)
                   ts2 <- checkParams (ntParams nt) ts1
                   return (TCon tc ts2)

              -- Maybe it is a parameter type?
              Nothing ->
                do mbA <- kLookupParamType x
                   case mbA of
                     Just a ->
                       do let ty = tpVar a
                          (ts1,k1) <- appTy ts (kindOf ty)
                          case k of
                            Just ks
                              | ks /= k1 -> kRecordError $ KindMismatch ks k1
                            _ -> return ()

                          unless (null ts1)
                            $ panic "Kind.tySyn" [ "Unexpected parameters" ]

                          return (TVar ty)

                     -- Maybe it is a scoped type variable?
                     Nothing
                       | scoped -> kExistTVar x $ fromMaybe KNum k
                       | otherwise ->
                          do kRecordError $ UndefinedTypeSynonym x
                             kNewType (text "type synonym" <+> pp x) $
                                                            fromMaybe KNum k
  where
  checkParams as ts1
    | paramHave == paramNeed = return ts1
    | paramHave < paramNeed  =
                   do kRecordError (TooFewTySynParams x (paramNeed-paramHave))
                      let src = text "missing prameter of" <+> pp x
                      fake <- mapM (kNewType src . kindOf . tpVar)
                                   (drop paramHave as)
                      return (ts1 ++ fake)
    | otherwise = do kRecordError (TooManyTySynParams x (paramHave-paramNeed))
                     return (take paramNeed ts1)
    where paramHave = length ts1
          paramNeed = length as


-- | Check a type-application.
appTy :: [P.Type Name]        -- ^ Parameters to type function
      -> Kind                 -- ^ Kind of type function
      -> KindM ([Type], Kind) -- ^ Validated parameters, resulting kind
appTy [] k1 = return ([],k1)

appTy (t : ts) (k1 :-> k2) =
  do t1      <- doCheckType t (Just k1)
     (ts1,k) <- appTy ts k2
     return (t1 : ts1, k)

appTy ts k1 =
  do kRecordError (TooManyTypeParams (length ts) k1)
     return ([], k1)


-- | Validate a parsed type.
doCheckType :: P.Type Name  -- ^ Type that needs to be checked
          -> Maybe Kind     -- ^ Expected kind (if any)
          -> KindM Type     -- ^ Checked type
doCheckType ty k =
  case ty of
    P.TWild         ->
      do ok <- kWildOK
         unless ok $ kRecordError UnexpectedTypeWildCard
         theKind <- case k of
                      Just k1 -> return k1
                      Nothing -> do kRecordWarning (DefaultingWildType P.KNum)
                                    return KNum
         kNewType (text "wildcard") theKind

    P.TFun t1 t2    -> tcon (TC TCFun)                 [t1,t2] k
    P.TSeq t1 t2    -> tcon (TC TCSeq)                 [t1,t2] k
    P.TBit          -> tcon (TC TCBit)                 [] k
    P.TInteger      -> tcon (TC TCInteger)             [] k
    P.TNum n        -> tcon (TC (TCNum n))             [] k
    P.TChar n       -> tcon (TC (TCNum $ fromIntegral $ fromEnum n)) [] k
    P.TInf          -> tcon (TC TCInf)                 [] k
    P.TApp tf ts    ->
      do it <- tcon (TF tf) ts k

         -- Now check for additional well-formedness
         -- constraints.
         case it of
           TCon (TF f) ts' ->
              case wfTypeFunction f ts' of
                 [] -> return ()
                 ps -> kNewGoals (CtPartialTypeFun (BuiltInTyFun f)) ps
           _ -> return ()

         return it
    P.TTuple ts     -> tcon (TC (TCTuple (length ts))) ts k

    P.TRecord fs    -> do t1 <- TRec `fmap` mapM checkF fs
                          checkKind t1 k KType
    P.TLocated t r1 -> kInRange r1 $ doCheckType t k

    P.TUser x []    -> checkTyThing x k
    P.TUser x ts    -> tySyn False x ts k

    P.TParens t     -> doCheckType t k

    P.TInfix{}      -> panic "KindCheck"
                       [ "TInfix not removed by the renamer", show ty ]


  where
  checkF f = do t <- kInRange (srcRange (name f))
                   $ doCheckType (value f) (Just KType)
                return (thing (name f), t)



-- | Check a type-variable or type-synonym.
checkTyThing :: Name          -- ^ Name of thing that needs checking
             -> Maybe Kind    -- ^ Expected kind
             -> KindM Type
checkTyThing x k =
  do it <- kLookupTyVar x
     case it of
       Just (TLocalVar t mbk) ->
         case k of
           Nothing -> return t
           Just k1 ->
             case mbk of
               Nothing -> kSetKind x k1 >> return t
               Just k2 -> checkKind t k k2

       Just (TOuterVar t) -> checkKind t k (kindOf t)
       Nothing            -> tySyn True x [] k


-- | Validate a parsed proposition.
checkProp :: P.Prop Name      -- ^ Proposition that need to be checked
          -> KindM Type       -- ^ Checked representation
checkProp prop =
  case prop of
    P.CFin t1       -> tcon (PC PFin)           [t1]    (Just KProp)
    P.CEqual t1 t2  -> tcon (PC PEqual)         [t1,t2] (Just KProp)
    P.CGeq t1 t2    -> tcon (PC PGeq)           [t1,t2] (Just KProp)
    P.CZero t1      -> tcon (PC PZero)          [t1]    (Just KProp)
    P.CLogic t1     -> tcon (PC PLogic)         [t1]    (Just KProp)
    P.CArith t1     -> tcon (PC PArith)         [t1]    (Just KProp)
    P.CCmp t1       -> tcon (PC PCmp)           [t1]    (Just KProp)
    P.CSignedCmp t1 -> tcon (PC PSignedCmp)     [t1]    (Just KProp)
    P.CUser x []    -> checkTyThing x (Just KProp)
    P.CUser x ts    -> tySyn False x ts (Just KProp)
    P.CLocated p r1 -> kInRange r1 (checkProp p)
    P.CType _       -> panic "checkProp" [ "Unexpected CType", show prop ]


-- | Check that a type has the expected kind.
checkKind :: Type         -- ^ Kind-checked type
          -> Maybe Kind   -- ^ Expected kind (if any)
          -> Kind         -- ^ Inferred kind
          -> KindM Type   -- ^ A type consistent with expectations.
checkKind _ (Just k1) k2
  | k1 /= k2    = do kRecordError (KindMismatch k1 k2)
                     kNewType (text "kind error") k1
checkKind t _ _ = return t


