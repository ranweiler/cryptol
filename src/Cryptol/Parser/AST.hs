-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE Safe #-}

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Cryptol.Parser.AST
  ( -- * Names
    Ident, mkIdent, mkInfix, isInfixIdent, nullIdent, identText
  , ModName, modRange
  , PName(..), getModName, getIdent, mkUnqual, mkQual
  , Named(..)
  , Pass(..)
  , Assoc(..)

    -- * Types
  , Schema(..)
  , TParam(..)
  , Kind(..)
  , Type(..), tconNames
  , Prop(..)

    -- * Declarations
  , Module(..)
  , Program(..)
  , TopDecl(..)
  , Decl(..)
  , Fixity(..), defaultFixity
  , FixityCmp(..), compareFixity
  , TySyn(..)
  , PropSyn(..)
  , Bind(..)
  , BindDef(..), LBindDef
  , Pragma(..)
  , ExportType(..)
  , TopLevel(..)
  , Import(..), ImportSpec(..)
  , Newtype(..)
  , ParameterType(..)
  , ParameterFun(..)

    -- * Interactive
  , ReplInput(..)

    -- * Expressions
  , Expr(..)
  , Literal(..), NumInfo(..)
  , Match(..)
  , Pattern(..)
  , Selector(..)
  , TypeInst(..)

    -- * Positions
  , Located(..)
  , LPName, LString, LIdent
  , NoPos(..)

    -- * Pretty-printing
  , cppKind, ppSelector
  ) where

import Cryptol.Parser.Name
import Cryptol.Parser.Position
import Cryptol.Prims.Syntax (TFun(..))
import Cryptol.Utils.Ident
import Cryptol.Utils.PP
import Cryptol.Utils.Panic (panic)

import           Data.List(intersperse)
import           Data.Bits(shiftR)
import           Data.Maybe (catMaybes)
import qualified Data.Map as Map
import           Numeric(showIntAtBase)

import GHC.Generics (Generic)
import Control.DeepSeq

import Prelude ()
import Prelude.Compat

-- AST -------------------------------------------------------------------------

-- | A name with location information.
type LPName    = Located PName

-- | An identifier with location information.
type LIdent    = Located Ident

-- | A string with location information.
type LString  = Located String


newtype Program name = Program [TopDecl name]
                       deriving (Show)

-- | A parsed module.
data Module name = Module
  { mName     :: Located ModName            -- ^ Name of the module
  , mInstance :: !(Maybe (Located ModName)) -- ^ Functor to instantiate
                                            -- (if this is a functor instnaces)
  , mImports  :: [Located Import]           -- ^ Imports for the module
  , mDecls    :: [TopDecl name]             -- ^ Declartions for the module
  } deriving (Show, Generic, NFData)


modRange :: Module name -> Range
modRange m = rCombs $ catMaybes
    [ getLoc (mName m)
    , getLoc (mImports m)
    , getLoc (mDecls m)
    , Just (Range { from = start, to = start, source = "" })
    ]


data TopDecl name =
    Decl (TopLevel (Decl name))
  | TDNewtype (TopLevel (Newtype name)) -- ^ @newtype T as = t
  | Include (Located FilePath)          -- ^ @include File@
  | DParameterType (ParameterType name) -- ^ @parameter type T : #@
  | DParameterConstraint [Located (Prop name)]
                                        -- ^ @parameter type constraint (fin T)@
  | DParameterFun  (ParameterFun name)  -- ^ @parameter someVal : [256]@
                    deriving (Show, Generic, NFData)

data Decl name = DSignature [Located name] (Schema name)
               | DFixity !Fixity [Located name]
               | DPragma [Located name] Pragma
               | DBind (Bind name)
               | DPatBind (Pattern name) (Expr name)
               | DType (TySyn name)
               | DProp (PropSyn name)
               | DLocated (Decl name) Range
                 deriving (Eq, Show, Generic, NFData, Functor)


-- | A type parameter
data ParameterType name = ParameterType
  { ptName    :: Located name     -- ^ name of type parameter
  , ptKind    :: Kind             -- ^ kind of parameter
  , ptDoc     :: Maybe String     -- ^ optional documentation
  , ptFixity  :: Maybe Fixity     -- ^ info for infix use
  , ptNumber  :: !Int             -- ^ number of the parameter
  } deriving (Eq,Show,Generic,NFData)

-- | A value parameter
data ParameterFun name = ParameterFun
  { pfName   :: Located name      -- ^ name of value parameter
  , pfSchema :: Schema name       -- ^ schema for parameter
  , pfDoc    :: Maybe String      -- ^ optional documentation
  , pfFixity :: Maybe Fixity      -- ^ info for infix use
  } deriving (Eq,Show,Generic,NFData)


-- | An import declaration.
data Import = Import { iModule    :: !ModName
                     , iAs        :: Maybe ModName
                     , iSpec      :: Maybe ImportSpec
                     } deriving (Eq, Show, Generic, NFData)

-- | The list of names following an import.
--
-- INVARIANT: All of the 'Name' entries in the list are expected to be
-- unqualified names; the 'QName' or 'NewName' constructors should not be
-- present.
data ImportSpec = Hiding [Ident]
                | Only   [Ident]
                  deriving (Eq, Show, Generic, NFData)

data TySyn n  = TySyn (Located n) [TParam n] (Type n)
                deriving (Eq, Show, Generic, NFData, Functor)

data PropSyn n = PropSyn (Located n) [TParam n] [Prop n]
                 deriving (Eq, Show, Generic, NFData, Functor)

{- | Bindings.  Notes:

    * The parser does not associate type signatures and pragmas with
      their bindings: this is done in a separate pass, after de-sugaring
      pattern bindings.  In this way we can associate pragmas and type
      signatures with the variables defined by pattern bindings as well.

    * Currently, there is no surface syntax for defining monomorphic
      bindings (i.e., bindings that will not be automatically generalized
      by the type checker.  However, they are useful when de-sugaring
      patterns.
-}
data Bind name = Bind { bName      :: Located name -- ^ Defined thing
                      , bParams    :: [Pattern name]-- ^ Parameters
                      , bDef       :: Located (BindDef name) -- ^ Definition
                      , bSignature :: Maybe (Schema name) -- ^ Optional type sig
                      , bInfix     :: Bool         -- ^ Infix operator?
                      , bFixity    :: Maybe Fixity -- ^ Optional fixity info
                      , bPragmas   :: [Pragma]     -- ^ Optional pragmas
                      , bMono      :: Bool         -- ^ Is this a monomorphic binding
                      , bDoc       :: Maybe String -- ^ Optional doc string
                      } deriving (Eq, Generic, NFData, Functor, Show)

type LBindDef = Located (BindDef PName)

data BindDef name = DPrim
                  | DExpr (Expr name)
                    deriving (Eq, Show, Generic, NFData, Functor)

data Fixity   = Fixity { fAssoc :: !Assoc
                       , fLevel :: !Int
                       } deriving (Eq, Generic, NFData, Show)

data FixityCmp = FCError
               | FCLeft
               | FCRight
                 deriving (Show,Eq)

compareFixity :: Fixity -> Fixity -> FixityCmp
compareFixity (Fixity a1 p1) (Fixity a2 p2) =
  case compare p1 p2 of
    GT -> FCLeft
    LT -> FCRight
    EQ -> case (a1,a2) of
            (LeftAssoc,LeftAssoc)   -> FCLeft
            (RightAssoc,RightAssoc) -> FCRight
            _                       -> FCError

-- | The fixity used when none is provided.
defaultFixity :: Fixity
defaultFixity  = Fixity LeftAssoc 100

data Pragma   = PragmaNote String
              | PragmaProperty
                deriving (Eq, Show, Generic, NFData)

data Newtype name = Newtype { nName   :: Located name        -- ^ Type name
                            , nParams :: [TParam name]       -- ^ Type params
                            , nBody   :: [Named (Type name)] -- ^ Constructor
                            } deriving (Eq, Show, Generic, NFData)

-- | Input at the REPL, which can either be an expression or a @let@
-- statement.
data ReplInput name = ExprInput (Expr name)
                    | LetInput (Decl name)
                      deriving (Eq, Show)

-- | Export information for a declaration.
data ExportType = Public
                | Private
                  deriving (Eq, Show, Ord, Generic, NFData)

-- | A top-level module declaration.
data TopLevel a = TopLevel { tlExport :: ExportType
                           , tlDoc    :: Maybe (Located String)
                           , tlValue  :: a
                           }
  deriving (Show, Generic, NFData, Functor, Foldable, Traversable)


-- | Infromation about the representation of a numeric constant.
data NumInfo  = BinLit Int                      -- ^ n-digit binary literal
              | OctLit Int                      -- ^ n-digit octal  literal
              | DecLit                          -- ^ overloaded decimal literal
              | HexLit Int                      -- ^ n-digit hex literal
              | CharLit                         -- ^ character literal
              | PolyLit Int                     -- ^ polynomial literal
                deriving (Eq, Show, Generic, NFData)

-- | Literals.
data Literal  = ECNum Integer NumInfo           -- ^ @0x10@  (HexLit 2)
              | ECString String                 -- ^ @\"hello\"@
                deriving (Eq, Show, Generic, NFData)

data Expr n   = EVar n                          -- ^ @ x @
              | ELit Literal                    -- ^ @ 0x10 @
              | ETuple [Expr n]                 -- ^ @ (1,2,3) @
              | ERecord [Named (Expr n)]        -- ^ @ { x = 1, y = 2 } @
              | ESel (Expr n) Selector          -- ^ @ e.l @
              | EList [Expr n]                  -- ^ @ [1,2,3] @
              | EFromTo (Type n) (Maybe (Type n)) (Maybe (Type n)) -- ^ @[1, 5 ..  117 ] @
              | EInfFrom (Expr n) (Maybe (Expr n))-- ^ @ [1, 3 ...] @
              | EComp (Expr n) [[Match n]]      -- ^ @ [ 1 | x <- xs ] @
              | EApp (Expr n) (Expr n)          -- ^ @ f x @
              | EAppT (Expr n) [(TypeInst n)]   -- ^ @ f `{x = 8}, f`{8} @
              | EIf (Expr n) (Expr n) (Expr n)  -- ^ @ if ok then e1 else e2 @
              | EWhere (Expr n) [Decl n]        -- ^ @ 1 + x where { x = 2 } @
              | ETyped (Expr n) (Type n)        -- ^ @ 1 : [8] @
              | ETypeVal (Type n)               -- ^ @ `(x + 1)@, @x@ is a type
              | EFun [Pattern n] (Expr n)       -- ^ @ \\x y -> x @
              | ELocated (Expr n) Range         -- ^ position annotation

              | EParens (Expr n)                -- ^ @ (e)   @ (Removed by Fixity)
              | EInfix (Expr n) (Located n) Fixity (Expr n)-- ^ @ a + b @ (Removed by Fixity)
                deriving (Eq, Show, Generic, NFData, Functor)

data TypeInst name = NamedInst (Named (Type name))
                   | PosInst (Type name)
                     deriving (Eq, Show, Generic, NFData, Functor)

{- | Selectors are used for projecting from various components.
Each selector has an option spec to specify the shape of the thing
that is being selected.  Currently, there is no surface syntax for
list selectors, but they are used during the desugaring of patterns.
-}

data Selector = TupleSel Int   (Maybe Int)
                -- ^ Zero-based tuple selection.
                -- Optionally specifies the shape of the tuple (one-based).

              | RecordSel Ident (Maybe [Ident])
                -- ^ Record selection.
                -- Optionally specifies the shape of the record.

              | ListSel Int    (Maybe Int)
                -- ^ List selection.
                -- Optionally specifies the length of the list.
                deriving (Eq, Show, Ord, Generic, NFData)

data Match name = Match (Pattern name) (Expr name)              -- ^ p <- e
                | MatchLet (Bind name)
                  deriving (Eq, Show, Generic, NFData, Functor)

data Pattern n = PVar (Located n)              -- ^ @ x @
               | PWild                         -- ^ @ _ @
               | PTuple [Pattern n]            -- ^ @ (x,y,z) @
               | PRecord [ Named (Pattern n) ] -- ^ @ { x = (a,b,c), y = z } @
               | PList [ Pattern n ]           -- ^ @ [ x, y, z ] @
               | PTyped (Pattern n) (Type n)   -- ^ @ x : [8] @
               | PSplit (Pattern n) (Pattern n)-- ^ @ (x # y) @
               | PLocated (Pattern n) Range    -- ^ Location information
                 deriving (Eq, Show, Generic, NFData, Functor)

data Named a = Named { name :: Located Ident, value :: a }
  deriving (Eq, Show, Foldable, Traversable, Generic, NFData, Functor)

data Schema n = Forall [TParam n] [Prop n] (Type n) (Maybe Range)
  deriving (Eq, Show, Generic, NFData, Functor)

data Kind = KNum | KType
  deriving (Eq, Show, Generic, NFData)

data TParam n = TParam { tpName  :: n
                       , tpKind  :: Maybe Kind
                       , tpRange :: Maybe Range
                       }
  deriving (Eq, Show, Generic, NFData, Functor)

data Type n = TFun (Type n) (Type n)  -- ^ @[8] -> [8]@
            | TSeq (Type n) (Type n)  -- ^ @[8] a@
            | TBit                    -- ^ @Bit@
            | TInteger                -- ^ @Integer@
            | TNum Integer            -- ^ @10@
            | TChar Char              -- ^ @'a'@
            | TInf                    -- ^ @inf@
            | TUser n [Type n]        -- ^ A type variable or synonym
            | TApp TFun [Type n]      -- ^ @2 + x@
            | TRecord [Named (Type n)]-- ^ @{ x : [8], y : [32] }@
            | TTuple [Type n]         -- ^ @([8], [32])@
            | TWild                   -- ^ @_@, just some type.
            | TLocated (Type n) Range -- ^ Location information
            | TParens (Type n)        -- ^ @ (ty) @
            | TInfix (Type n) (Located n) Fixity (Type n) -- ^ @ ty + ty @
              deriving (Eq, Show, Generic, NFData, Functor)

tconNames :: Map.Map PName (Type PName)
tconNames  = Map.fromList
  [ (mkUnqual (packIdent "Bit"), TBit)
  , (mkUnqual (packIdent "Integer"), TInteger)
  , (mkUnqual (packIdent "inf"), TInf)
  ]

data Prop n   = CFin (Type n)             -- ^ @ fin x   @
              | CEqual (Type n) (Type n)  -- ^ @ x == 10 @
              | CGeq (Type n) (Type n)    -- ^ @ x >= 10 @
              | CZero (Type n)            -- ^ @ Zero a  @
              | CLogic (Type n)           -- ^ @ Logic a @
              | CArith (Type n)           -- ^ @ Arith a @
              | CCmp (Type n)             -- ^ @ Cmp a @
              | CSignedCmp (Type n)       -- ^ @ SignedCmp a @
              | CUser n [Type n]          -- ^ Constraint synonym
              | CLocated (Prop n) Range   -- ^ Location information
              | CType (Type n)            -- ^ After parsing
                deriving (Eq, Show, Generic, NFData, Functor)


--------------------------------------------------------------------------------
-- Note: When an explicit location is missing, we could use the sub-components
-- to try to estimate a location...


instance AddLoc (Expr n) where
  addLoc = ELocated

  dropLoc (ELocated e _) = dropLoc e
  dropLoc e              = e

instance HasLoc (Expr name) where
  getLoc (ELocated _ r) = Just r
  getLoc _              = Nothing

instance HasLoc (TParam name) where
  getLoc (TParam _ _ r) = r

instance AddLoc (TParam name) where
  addLoc (TParam a b _) l = TParam a b (Just l)
  dropLoc (TParam a b _)  = TParam a b Nothing

instance HasLoc (Type name) where
  getLoc (TLocated _ r) = Just r
  getLoc _              = Nothing

instance AddLoc (Type name) where
  addLoc = TLocated

  dropLoc (TLocated e _) = dropLoc e
  dropLoc e              = e

instance HasLoc (Prop name) where
  getLoc (CLocated _ r) = Just r
  getLoc _              = Nothing

instance AddLoc (Prop name) where
  addLoc = CLocated

  dropLoc (CLocated e _) = dropLoc e
  dropLoc e              = e

instance AddLoc (Pattern name) where
  addLoc = PLocated

  dropLoc (PLocated e _) = dropLoc e
  dropLoc e              = e

instance HasLoc (Pattern name) where
  getLoc (PLocated _ r) = Just r
  getLoc (PTyped r _)   = getLoc r
  getLoc (PVar x)       = getLoc x
  getLoc _              = Nothing

instance HasLoc (Bind name) where
  getLoc b = getLoc (bName b, bDef b)

instance HasLoc (Match name) where
  getLoc (Match p e)    = getLoc (p,e)
  getLoc (MatchLet b)   = getLoc b

instance HasLoc a => HasLoc (Named a) where
  getLoc l = getLoc (name l, value l)

instance HasLoc (Schema name) where
  getLoc (Forall _ _ _ r) = r

instance AddLoc (Schema name) where
  addLoc  (Forall xs ps t _) r = Forall xs ps t (Just r)
  dropLoc (Forall xs ps t _)   = Forall xs ps t Nothing

instance HasLoc (Decl name) where
  getLoc (DLocated _ r) = Just r
  getLoc _              = Nothing

instance AddLoc (Decl name) where
  addLoc d r             = DLocated d r

  dropLoc (DLocated d _) = dropLoc d
  dropLoc d              = d

instance HasLoc a => HasLoc (TopLevel a) where
  getLoc = getLoc . tlValue

instance HasLoc (TopDecl name) where
  getLoc td = case td of
    Decl tld    -> getLoc tld
    TDNewtype n -> getLoc n
    Include lfp -> getLoc lfp
    DParameterType d -> getLoc d
    DParameterFun d  -> getLoc d
    DParameterConstraint d -> getLoc d

instance HasLoc (ParameterType name) where
  getLoc a = getLoc (ptName a)

instance HasLoc (ParameterFun name) where
  getLoc a = getLoc (pfName a)

instance HasLoc (Module name) where
  getLoc m
    | null locs = Nothing
    | otherwise = Just (rCombs locs)
    where
    locs = catMaybes [ getLoc (mName m)
                     , getLoc (mImports m)
                     , getLoc (mDecls m)
                     ]

instance HasLoc (Newtype name) where
  getLoc n
    | null locs = Nothing
    | otherwise = Just (rCombs locs)
    where
    locs = catMaybes [ getLoc (nName n), getLoc (nBody n) ]


--------------------------------------------------------------------------------





--------------------------------------------------------------------------------
-- Pretty printing


ppL :: PP a => Located a -> Doc
ppL = pp . thing

ppNamed :: PP a => String -> Named a -> Doc
ppNamed s x = ppL (name x) <+> text s <+> pp (value x)


instance (Show name, PPName name) => PP (Module name) where
  ppPrec _ m = text "module" <+> ppL (mName m) <+> text "where"
            $$ vcat (map ppL (mImports m))
            $$ vcat (map pp (mDecls m))

instance (Show name, PPName name) => PP (Program name) where
  ppPrec _ (Program ds) = vcat (map pp ds)

instance (Show name, PPName name) => PP (TopDecl name) where
  ppPrec _ top_decl =
    case top_decl of
      Decl    d   -> pp d
      TDNewtype n -> pp n
      Include l   -> text "include" <+> text (show (thing l))
      DParameterFun d -> pp d
      DParameterType d -> pp d
      DParameterConstraint d ->
        "parameter" <+> "type" <+> "constraint" <+> prop
        where prop = case map pp d of
                       [x] -> x
                       []  -> "()"
                       xs  -> parens (hsep (punctuate comma xs))

instance (Show name, PPName name) => PP (ParameterType name) where
  ppPrec _ a = text "parameter" <+> text "type" <+>
               ppPrefixName (ptName a) <+> text ":" <+> pp (ptKind a)

instance (Show name, PPName name) => PP (ParameterFun name) where
  ppPrec _ a = text "parameter" <+> ppPrefixName (pfName a) <+> text ":"
                  <+> pp (pfSchema a)


instance (Show name, PPName name) => PP (Decl name) where
  ppPrec n decl =
    case decl of
      DSignature xs s -> commaSep (map ppL xs) <+> text ":" <+> pp s
      DPatBind p e    -> pp p <+> text "=" <+> pp e
      DBind b         -> ppPrec n b
      DFixity f ns    -> ppFixity f ns
      DPragma xs p    -> ppPragma xs p
      DType ts        -> ppPrec n ts
      DProp ps        -> ppPrec n ps
      DLocated d _    -> ppPrec n d

ppFixity :: PPName name => Fixity -> [Located name] -> Doc
ppFixity (Fixity LeftAssoc  i) ns = text "infixl" <+> int i <+> commaSep (map pp ns)
ppFixity (Fixity RightAssoc i) ns = text "infixr" <+> int i <+> commaSep (map pp ns)
ppFixity (Fixity NonAssoc   i) ns = text "infix"  <+> int i <+> commaSep (map pp ns)

instance PPName name => PP (Newtype name) where
  ppPrec _ nt = hsep
    [ text "newtype", ppL (nName nt), hsep (map pp (nParams nt)), char '='
    , braces (commaSep (map (ppNamed ":") (nBody nt))) ]

instance PP Import where
  ppPrec _ d = text "import" <+> sep [ pp (iModule d), mbAs, mbSpec ]
    where
    mbAs = maybe empty (\ name -> text "as" <+> pp name ) (iAs d)

    mbSpec = maybe empty pp (iSpec d)

instance PP ImportSpec where
  ppPrec _ s = case s of
    Hiding names -> text "hiding" <+> parens (commaSep (map pp names))
    Only names   ->                   parens (commaSep (map pp names))

-- TODO: come up with a good way of showing the export specification here
instance PP a => PP (TopLevel a) where
  ppPrec _ tl = pp (tlValue tl)


instance PP Pragma where
  ppPrec _ (PragmaNote x) = text x
  ppPrec _ PragmaProperty = text "property"

ppPragma :: PPName name => [Located name] -> Pragma -> Doc
ppPragma xs p =
  text "/*" <+> text "pragma" <+> commaSep (map ppL xs) <+> text ":" <+> pp p
  <+> text "*/"

instance (Show name, PPName name) => PP (Bind name) where
  ppPrec _ b = sig $$ vcat [ ppPragma [f] p | p <- bPragmas b ] $$
               hang (def <+> eq) 4 (pp (thing (bDef b)))
    where def | bInfix b  = lhsOp
              | otherwise = lhs
          f = bName b
          sig = case bSignature b of
                  Nothing -> empty
                  Just s  -> pp (DSignature [f] s)
          eq  = if bMono b then text ":=" else text "="
          lhs = ppL f <+> fsep (map (ppPrec 3) (bParams b))

          lhsOp = case bParams b of
                    [x,y] -> pp x <+> ppL f <+> pp y
                    xs -> parens (parens (ppL f) <+> fsep (map (ppPrec 0) xs))
                    -- _     -> panic "AST" [ "Malformed infix operator", show b ]


instance (Show name, PPName name) => PP (BindDef name) where
  ppPrec _ DPrim     = text "<primitive>"
  ppPrec p (DExpr e) = ppPrec p e


instance PPName name => PP (TySyn name) where
  ppPrec _ (TySyn x xs t) = text "type" <+> ppL x <+> fsep (map (ppPrec 1) xs)
                                        <+> text "=" <+> pp t

instance PPName name => PP (PropSyn name) where
  ppPrec _ (PropSyn x xs ps) =
    text "constraint" <+> ppL x <+> fsep (map (ppPrec 1) xs)
                      <+> text "=" <+> parens (commaSep (map pp ps))

instance PP Literal where
  ppPrec _ lit =
    case lit of
      ECNum n i     -> ppNumLit n i
      ECString s    -> text (show s)


ppNumLit :: Integer -> NumInfo -> Doc
ppNumLit n info =
  case info of
    DecLit    -> integer n
    CharLit   -> text (show (toEnum (fromInteger n) :: Char))
    BinLit w  -> pad 2  "0b" w
    OctLit w  -> pad 8  "0o" w
    HexLit w  -> pad 16 "0x" w
    PolyLit w -> text "<|" <+> poly w <+> text "|>"
  where
  pad base pref w =
    let txt = showIntAtBase base ("0123456789abcdef" !!) n ""
    in text pref <> text (replicate (w - length txt) '0') <> text txt

  poly w = let (res,deg) = bits Nothing [] 0 n
               z | w == 0 = []
                 | Just d <- deg, d + 1 == w = []
                 | otherwise = [polyTerm0 (w-1)]
           in fsep $ intersperse (text "+") $ z ++ map polyTerm res

  polyTerm 0 = text "1"
  polyTerm 1 = text "x"
  polyTerm p = text "x" <> text "^^" <> int p

  polyTerm0 0 = text "0"
  polyTerm0 p = text "0" <> text "*" <> polyTerm p

  bits d res p num
    | num == 0  = (res,d)
    | even num  = bits d             res  (p + 1) (num `shiftR` 1)
    | otherwise = bits (Just p) (p : res) (p + 1) (num `shiftR` 1)

wrap :: Int -> Int -> Doc -> Doc
wrap contextPrec myPrec doc = if myPrec < contextPrec then parens doc else doc

isEApp :: Expr n -> Maybe (Expr n, Expr n)
isEApp (ELocated e _)     = isEApp e
isEApp (EApp e1 e2)       = Just (e1,e2)
isEApp _                  = Nothing

asEApps :: Expr n -> (Expr n, [Expr n])
asEApps expr = go expr []
    where go e es = case isEApp e of
                      Nothing       -> (e, es)
                      Just (e1, e2) -> go e1 (e2 : es)

instance PPName name => PP (TypeInst name) where
  ppPrec _ (PosInst t)   = pp t
  ppPrec _ (NamedInst x) = ppNamed "=" x

{- Precedences:
0: lambda, if, where, type annotation
2: infix expression   (separate precedence table)
3: application, prefix expressions
-}
instance (Show name, PPName name) => PP (Expr name) where
  -- Wrap if top level operator in expression is less than `n`
  ppPrec n expr =
    case expr of

      -- atoms
      EVar x        -> ppPrefixName x
      ELit x        -> pp x
      ETuple es     -> parens (commaSep (map pp es))
      ERecord fs    -> braces (commaSep (map (ppNamed "=") fs))
      EList es      -> brackets (commaSep (map pp es))
      EFromTo e1 e2 e3 -> brackets (pp e1 <> step <+> text ".." <+> end)
        where step = maybe empty (\e -> comma <+> pp e) e2
              end  = maybe empty pp e3
      EInfFrom e1 e2 -> brackets (pp e1 <> step <+> text "...")
        where step = maybe empty (\e -> comma <+> pp e) e2
      EComp e mss   -> brackets (pp e <+> vcat (map arm mss))
        where arm ms = text "|" <+> commaSep (map pp ms)
      ETypeVal t    -> text "`" <> ppPrec 5 t     -- XXX
      EAppT e ts    -> ppPrec 4 e <> text "`" <> braces (commaSep (map pp ts))
      ESel    e l   -> ppPrec 4 e <> text "." <> pp l

      -- low prec
      EFun xs e     -> wrap n 0 ((text "\\" <> hsep (map (ppPrec 3) xs)) <+>
                                 text "->" <+> pp e)

      EIf e1 e2 e3  -> wrap n 0 $ sep [ text "if"   <+> pp e1
                                      , text "then" <+> pp e2
                                      , text "else" <+> pp e3 ]

      ETyped e t    -> wrap n 0 (ppPrec 2 e <+> text ":" <+> pp t)

      EWhere  e ds  -> wrap n 0 (pp e
                                $$ text "where"
                                $$ nest 2 (vcat (map pp ds))
                                $$ text "")

      -- infix applications
      _ | Just ifix <- isInfix expr ->
              optParens (n > 2)
              $ ppInfix 2 isInfix ifix

      EApp _ _      -> let (e, es) = asEApps expr in
                       wrap n 3 (ppPrec 3 e <+> fsep (map (ppPrec 4) es))

      ELocated e _  -> ppPrec n e

      EParens e -> parens (pp e)

      EInfix e1 op _ e2 -> wrap n 0 (pp e1 <+> ppInfixName (thing op) <+> pp e2)
   where
   isInfix (EApp (EApp (EVar ieOp) ieLeft) ieRight) = do
     (ieAssoc,iePrec) <- ppNameFixity ieOp
     return Infix { .. }
   isInfix _ = Nothing

instance PP Selector where
  ppPrec _ sel =
    case sel of
      TupleSel x sig    -> int x <+> ppSig tupleSig sig
      RecordSel x sig  -> pp x  <+> ppSig recordSig sig
      ListSel x sig    -> int x <+> ppSig listSig sig

    where
    tupleSig n   = int n
    recordSig xs = braces $ fsep $ punctuate comma $ map pp xs
    listSig n    = int n

    ppSig f = maybe empty (\x -> text "/* of" <+> f x <+> text "*/")


-- | Display the thing selected by the selector, nicely.
ppSelector :: Selector -> Doc
ppSelector sel =
  case sel of
    TupleSel x _  -> ordinal x <+> text "field"
    RecordSel x _ -> text "field" <+> pp x
    ListSel x _   -> ordinal x <+> text "element"



instance PPName name => PP (Pattern name) where
  ppPrec n pat =
    case pat of
      PVar x        -> pp (thing x)
      PWild         -> char '_'
      PTuple ps     -> parens   (commaSep (map pp ps))
      PRecord fs    -> braces   (commaSep (map (ppNamed "=") fs))
      PList ps      -> brackets (commaSep (map pp ps))
      PTyped p t    -> wrap n 0 (ppPrec 1 p  <+> text ":" <+> pp t)
      PSplit p1 p2  -> wrap n 1 (ppPrec 1 p1 <+> text "#" <+> ppPrec 1 p2)
      PLocated p _  -> ppPrec n p

instance (Show name, PPName name) => PP (Match name) where
  ppPrec _ (Match p e)  = pp p <+> text "<-" <+> pp e
  ppPrec _ (MatchLet b) = pp b


instance PPName name => PP (Schema name) where
  ppPrec _ (Forall xs ps t _) = sep [vars <+> preds, pp t]
    where vars = case xs of
                   [] -> empty
                   _  -> braces (commaSep (map pp xs))
          preds = case ps of
                    [] -> empty
                    _  -> parens (commaSep (map pp ps)) <+> text "=>"

instance PP Kind where
  ppPrec _ KType  = text "*"
  ppPrec _ KNum   = text "#"

-- | "Conversational" printing of kinds (e.g., to use in error messages)
cppKind :: Kind -> Doc
cppKind KType = text "a value type"
cppKind KNum  = text "a numeric type"

instance PPName name => PP (TParam name) where
  ppPrec n (TParam p Nothing _)   = ppPrec n p
  ppPrec n (TParam p (Just k) _)  = wrap n 1 (pp p <+> text ":" <+> pp k)

-- 4: wrap [_] t
-- 3: wrap application
-- 2: wrap function
-- 1:
instance PPName name => PP (Type name) where
  ppPrec n ty =
    case ty of
      TWild          -> text "_"
      TTuple ts      -> parens $ commaSep $ map pp ts
      TRecord fs     -> braces $ commaSep $ map (ppNamed ":") fs
      TBit           -> text "Bit"
      TInteger       -> text "Integer"
      TInf           -> text "inf"
      TNum x         -> integer x
      TChar x        -> text (show x)
      TSeq t1 TBit   -> brackets (pp t1)
      TSeq t1 t2     -> optParens (n > 3)
                      $ brackets (pp t1) <> ppPrec 3 t2

      _ | Just tinf <- isInfix ty ->
              optParens (n > 2)
              $ ppInfix 2 isInfix tinf

      TApp f ts      -> optParens (n > 2)
                      $ pp f <+> fsep (map (ppPrec 4) ts)

      TUser f []     -> ppPrefixName f

      TUser f ts     -> optParens (n > 2)
                      $ ppPrefixName f <+> fsep (map (ppPrec 4) ts)

      TFun t1 t2     -> optParens (n > 1)
                      $ sep [ppPrec 2 t1 <+> text "->", ppPrec 1 t2]

      TLocated t _   -> ppPrec n t

      TParens t      -> parens (pp t)

      TInfix t1 o _ t2 -> optParens (n > 0)
                        $ sep [ppPrec 2 t1 <+> ppInfixName o, ppPrec 1 t2]

   where
   isInfix (TApp ieOp [ieLeft, ieRight]) = do
     (ieAssoc,iePrec) <- ppNameFixity ieOp
     return Infix { .. }
   isInfix _ = Nothing

instance PPName name => PP (Prop name) where
  ppPrec n prop =
    case prop of
      CFin t       -> text "fin"   <+> ppPrec 4 t
      CZero t      -> text "Zero"  <+> ppPrec 4 t
      CLogic t     -> text "Logic" <+> ppPrec 4 t
      CArith t     -> text "Arith" <+> ppPrec 4 t
      CCmp t       -> text "Cmp"   <+> ppPrec 4 t
      CSignedCmp t -> text "SignedCmp" <+> ppPrec 4 t
      CEqual t1 t2 -> ppPrec 2 t1 <+> text "==" <+> ppPrec 2 t2
      CGeq t1 t2   -> ppPrec 2 t1 <+> text ">=" <+> ppPrec 2 t2
      CUser f ts   -> optParens (n > 2)
                    $ ppPrefixName f <+> fsep (map (ppPrec 4) ts)
      CLocated c _ -> ppPrec n c

      CType t      -> ppPrec n t


--------------------------------------------------------------------------------
-- Drop all position information, so equality reflects program structure

class NoPos t where
  noPos :: t -> t

-- WARNING: This does not call `noPos` on the `thing` inside
instance NoPos (Located t) where
  noPos x = x { srcRange = rng }
    where rng = Range { from = Position 0 0, to = Position 0 0, source = "" }

instance NoPos t => NoPos (Named t) where
  noPos t = Named { name = noPos (name t), value = noPos (value t) }

instance NoPos t => NoPos [t]       where noPos = fmap noPos
instance NoPos t => NoPos (Maybe t) where noPos = fmap noPos

instance NoPos (Program name) where
  noPos (Program x) = Program (noPos x)

instance NoPos (Module name) where
  noPos m = Module { mName      = mName m
                   , mInstance  = mInstance m
                   , mImports   = noPos (mImports m)
                   , mDecls     = noPos (mDecls m)
                   }

instance NoPos (TopDecl name) where
  noPos decl =
    case decl of
      Decl    x   -> Decl     (noPos x)
      TDNewtype n -> TDNewtype(noPos n)
      Include x   -> Include  (noPos x)
      DParameterFun d  -> DParameterFun (noPos d)
      DParameterType d -> DParameterType (noPos d)
      DParameterConstraint d -> DParameterConstraint (noPos d)

instance NoPos (ParameterType name) where
  noPos a = a

instance NoPos (ParameterFun x) where
  noPos x = x { pfSchema = noPos (pfSchema x) }

instance NoPos a => NoPos (TopLevel a) where
  noPos tl = tl { tlValue = noPos (tlValue tl) }

instance NoPos (Decl name) where
  noPos decl =
    case decl of
      DSignature x y   -> DSignature (noPos x) (noPos y)
      DPragma    x y   -> DPragma    (noPos x) (noPos y)
      DPatBind   x y   -> DPatBind   (noPos x) (noPos y)
      DFixity f ns     -> DFixity f (noPos ns)
      DBind      x     -> DBind      (noPos x)
      DType      x     -> DType      (noPos x)
      DProp      x     -> DProp      (noPos x)
      DLocated   x _   -> noPos x

instance NoPos (Newtype name) where
  noPos n = Newtype { nName   = noPos (nName n)
                    , nParams = nParams n
                    , nBody   = noPos (nBody n)
                    }

instance NoPos (Bind name) where
  noPos x = Bind { bName      = noPos (bName      x)
                 , bParams    = noPos (bParams    x)
                 , bDef       = noPos (bDef       x)
                 , bSignature = noPos (bSignature x)
                 , bInfix     = bInfix x
                 , bFixity    = bFixity x
                 , bPragmas   = noPos (bPragmas   x)
                 , bMono      = bMono x
                 , bDoc       = bDoc x
                 }

instance NoPos Pragma where
  noPos p@(PragmaNote {})   = p
  noPos p@(PragmaProperty)  = p



instance NoPos (TySyn name) where
  noPos (TySyn x y z) = TySyn (noPos x) (noPos y) (noPos z)

instance NoPos (PropSyn name) where
  noPos (PropSyn x y z) = PropSyn (noPos x) (noPos y) (noPos z)

instance NoPos (Expr name) where
  noPos expr =
    case expr of
      EVar x        -> EVar     x
      ELit x        -> ELit     x
      ETuple x      -> ETuple   (noPos x)
      ERecord x     -> ERecord  (noPos x)
      ESel x y      -> ESel     (noPos x) y
      EList x       -> EList    (noPos x)
      EFromTo x y z -> EFromTo  (noPos x) (noPos y) (noPos z)
      EInfFrom x y  -> EInfFrom (noPos x) (noPos y)
      EComp x y     -> EComp    (noPos x) (noPos y)
      EApp  x y     -> EApp     (noPos x) (noPos y)
      EAppT x y     -> EAppT    (noPos x) (noPos y)
      EIf   x y z   -> EIf      (noPos x) (noPos y) (noPos z)
      EWhere x y    -> EWhere   (noPos x) (noPos y)
      ETyped x y    -> ETyped   (noPos x) (noPos y)
      ETypeVal x    -> ETypeVal (noPos x)
      EFun x y      -> EFun     (noPos x) (noPos y)
      ELocated x _  -> noPos x

      EParens e     -> EParens (noPos e)
      EInfix x y f z-> EInfix (noPos x) y f (noPos z)

instance NoPos (TypeInst name) where
  noPos (PosInst ts)   = PosInst (noPos ts)
  noPos (NamedInst fs) = NamedInst (noPos fs)

instance NoPos (Match name) where
  noPos (Match x y)  = Match (noPos x) (noPos y)
  noPos (MatchLet b) = MatchLet (noPos b)

instance NoPos (Pattern name) where
  noPos pat =
    case pat of
      PVar x       -> PVar    (noPos x)
      PWild        -> PWild
      PTuple x     -> PTuple  (noPos x)
      PRecord x    -> PRecord (noPos x)
      PList x      -> PList   (noPos x)
      PTyped x y   -> PTyped  (noPos x) (noPos y)
      PSplit x y   -> PSplit  (noPos x) (noPos y)
      PLocated x _ -> noPos x

instance NoPos (Schema name) where
  noPos (Forall x y z _) = Forall (noPos x) (noPos y) (noPos z) Nothing

instance NoPos (TParam name) where
  noPos (TParam x y _)  = TParam x y Nothing

instance NoPos (Type name) where
  noPos ty =
    case ty of
      TWild         -> TWild
      TApp x y      -> TApp     x         (noPos y)
      TUser x y     -> TUser    x         (noPos y)
      TRecord x     -> TRecord  (noPos x)
      TTuple x      -> TTuple   (noPos x)
      TFun x y      -> TFun     (noPos x) (noPos y)
      TSeq x y      -> TSeq     (noPos x) (noPos y)
      TBit          -> TBit
      TInteger      -> TInteger
      TInf          -> TInf
      TNum n        -> TNum n
      TChar n       -> TChar n
      TLocated x _  -> noPos x
      TParens x     -> TParens (noPos x)
      TInfix x y f z-> TInfix (noPos x) y f (noPos z)

instance NoPos (Prop name) where
  noPos prop =
    case prop of
      CEqual  x y   -> CEqual  (noPos x) (noPos y)
      CGeq x y      -> CGeq (noPos x) (noPos y)
      CFin x        -> CFin (noPos x)
      CZero x       -> CZero  (noPos x)
      CLogic x      -> CLogic (noPos x)
      CArith x      -> CArith (noPos x)
      CCmp x        -> CCmp   (noPos x)
      CSignedCmp x  -> CSignedCmp (noPos x)
      CUser x y     -> CUser x (noPos y)
      CLocated c _  -> noPos c
      CType t       -> CType (noPos t)
