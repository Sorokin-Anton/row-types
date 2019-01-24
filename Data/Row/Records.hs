-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Row.Records
--
-- This module implements extensible records using closed type famillies.
--
-- See Examples.hs for examples.
--
-- Lists of (label,type) pairs are kept sorted thereby ensuring
-- that { x = 0, y = 0 } and { y = 0, x = 0 } have the same type.
--
-- In this way we can implement standard type classes such as Show, Eq, Ord and Bounded
-- for open records, given that all the elements of the open record satify the constraint.
--
-----------------------------------------------------------------------------


module Data.Row.Records
  (
  -- * Types and constraints
    Label(..)
  , KnownSymbol, AllUniqueLabels, WellBehaved
  , Rec, Row, Empty, type (≈)
  -- * Construction
  , empty
  , type (.==), (.==), pattern (:==), unSingleton
  , default', defaultA
  , fromLabels, fromLabelsA, fromLabelsMapA
  -- ** Extension
  , extend, Extend, Lacks, type (.\)
  -- ** Restriction
  , type (.-), (.-)
  , restrict, split
  -- ** Modification
  , update, focus, multifocus, Modify, rename, Rename
  -- * Query
  , HasType, type (.!), (.!)
  -- * Combine
  -- ** Disjoint union
  , type (.+), (.+), Disjoint, pattern (:+)
  -- * Native Conversion
  -- $native
  , toNative, toNativeExact, fromNative
  -- * Dynamic Conversion
  , toDynamicMap, fromDynamicMap
  -- * Row operations
  -- ** Map
  , Map, map, map', mapF
  , transform, transform'
  -- ** Fold
  , Forall, erase, eraseWithLabels, eraseZip, eraseToHashMap
  -- ** Zip
  , Zip, zip
  -- ** Sequence
  , sequence, sequence'
  -- ** Compose
  -- $compose
  , compose, uncompose
  , compose', uncompose'
  -- ** Labels
  , labels, labels'
  -- ** UNSAFE operations
  , unsafeRemove, unsafeInjectFront
  )
where

import Prelude hiding (map, sequence, zip)

import Control.DeepSeq (NFData(..), deepseq)

import Data.Constraint ((\\))
import Data.Dynamic
import Data.Functor.Compose
import Data.Functor.Const
import Data.Functor.Identity
import Data.Functor.Product
import Data.Hashable
import Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as M
import qualified Data.List as L
import Data.Monoid (Endo(..), appEndo)
import Data.Proxy
import Data.String (IsString)
import Data.Text (Text)

import qualified GHC.Generics as G
import GHC.TypeLits

import Unsafe.Coerce

import Data.Row.Internal


{--------------------------------------------------------------------
  Open records
--------------------------------------------------------------------}
-- | A record with row r.
newtype Rec (r :: Row *) where
  OR :: HashMap Text HideType -> Rec r

instance Forall r Show => Show (Rec r) where
  showsPrec p r =
    case eraseWithLabels @Show (showsPrec 7) r of
      [] ->
        showString "empty"
      xs ->
        showParen
          (p > 6)
          (appEndo $ foldMap Endo (L.intersperse (showString " .+ ") (L.map binds xs)))
    where
      binds (label, value) =
        showChar '#' .
        showString label .
        showString " .== " .
        value

instance Forall r Eq => Eq (Rec r) where
  r == r' = and $ eraseZip @Eq (==) r r'

instance (Forall r Eq, Forall r Ord) => Ord (Rec r) where
  compare m m' = cmp $ eraseZip @Ord compare m m'
      where cmp l | [] <- l' = EQ
                  | a : _ <- l' = a
                  where l' = dropWhile (== EQ) l

instance (Forall r Bounded, AllUniqueLabels r) => Bounded (Rec r) where
  minBound = default' @Bounded minBound
  maxBound = default' @Bounded maxBound

instance Forall r NFData => NFData (Rec r) where
  rnf r = getConst $ metamorph @_ @r @NFData @Rec @(Const ()) @Identity Proxy empty doUncons doCons r
    where empty = const $ Const ()
          doUncons l r = (Identity $ r .! l, unsafeRemove l r)
          doCons _ x r = deepseq x $ deepseq r $ Const ()

-- | The empty record
empty :: Rec Empty
empty = OR M.empty

-- | The singleton record
infix 7 .==
(.==) :: KnownSymbol l => Label l -> a -> Rec (l .== a)
l .== a = extend l a empty

-- | A pattern for the singleton record; can be used to both destruct a record
-- when in a pattern position or construct one in an expression position.
{-# COMPLETE (:==) #-}
infix 7 :==
pattern (:==) :: forall l a. KnownSymbol l => Label l -> a -> Rec (l .== a)
pattern l :== a <- (unSingleton @l @a -> (l, a)) where
        (:==) l a = l .== a

-- | Turns a singleton record into a pair of the label and value.
unSingleton :: forall l a. KnownSymbol l => Rec (l .== a) -> (Label l, a)
unSingleton r = (l, r .! l) where l = Label @l

{--------------------------------------------------------------------
  Basic record operations
--------------------------------------------------------------------}


-- | Record extension. The row may already contain the label,
--   in which case the origin value can be obtained after restriction ('.-') with
--   the label.
extend :: forall a l r. KnownSymbol l => Label l -> a -> Rec r -> Rec (Extend l a r)
extend (toKey -> l) a (OR m) = OR $ M.insert l (HideType a) m

-- | Update the value associated with the label.
update :: (KnownSymbol l, r .! l ≈ a) => Label l -> a -> Rec r -> Rec r
update (toKey -> l) a (OR m) = OR $ M.adjust f l m where f = const (HideType a)

-- | Focus on the value associated with the label.
focus ::
  ( KnownSymbol l
  , r' .! l ≈ b
  , r  .! l ≈ a
  , r' ~ Modify l b r
  , r  ~ Modify l a r'
  , Functor f)
  => Label l -> (a -> f b) -> Rec r -> f (Rec r')
focus (toKey -> l) f (OR m) = case m M.! l of
  HideType x -> OR . flip (M.insert l) m . HideType <$> f (unsafeCoerce x)

-- | Focus on a sub-record
multifocus :: forall u v r f.
  ( Functor f
  , Disjoint u r
  , Disjoint v r)
  => (Rec u -> f (Rec v)) -> Rec (u .+ r) -> f (Rec (v .+ r))
multifocus f (u :+ r) = (.+ r) <$> f u

-- | Rename a label.
rename :: (KnownSymbol l, KnownSymbol l') => Label l -> Label l' -> Rec r -> Rec (Rename l l' r)
rename (toKey -> l) (toKey -> l') (OR m) = OR $ M.insert l' (m M.! l) $ M.delete l m

-- | Record selection
(.!) :: KnownSymbol l => Rec r -> Label l -> r .! l
OR m .! (toKey -> a) = case m M.! a of
  HideType x -> unsafeCoerce x

infixl 6 .-
-- | Record restriction. Remove the label l from the record.
(.-) :: KnownSymbol l => Rec r -> Label l -> Rec (r .- l)
-- OR m .- _ = OR m
OR m .- (toKey -> a) = OR $ M.delete a m

-- | Record disjoint union (commutative)
infixl 6 .+
(.+) :: Rec l -> Rec r -> Rec (l .+ r)
OR l .+ OR r = OR $ M.unionWith (error "Impossible") l r


-- | A pattern version of record union, for use in pattern matching.
{-# COMPLETE (:+) #-}
infixl 6 :+
pattern (:+) :: forall l r. Disjoint l r => Rec l -> Rec r -> Rec (l .+ r)
pattern l :+ r <- (split @l -> (l, r)) where
        (:+) l r = l .+ r

-- | Split a record into two sub-records.
split :: forall s r. (Forall s Unconstrained1, Subset s r)
         => Rec r -> (Rec s, Rec (r .\\ s))
split (OR m) = (OR $ M.intersection m labelMap, OR $ M.difference m labelMap)
  where labelMap = M.fromList $ L.zip (labels @s @Unconstrained1) (repeat ())

-- | Arbitrary record restriction.  Turn a record into a subset of itself.
restrict :: forall r r'. (Forall r Unconstrained1, Subset r r') => Rec r' -> Rec r
restrict = fst . split

-- | Removes a label from the record but does not remove the underlying value.
--
-- This is faster than regular record removal ('.-') but should only be used when
-- either: the record will never be merged with another record again, or a new
-- value will soon be placed into the record at this label (as in, an 'update'
-- that is split over two commands).
--
-- If the resulting record is then merged (with '.+') with another record that
-- contains a value at that label, an "impossible" error will occur.
unsafeRemove :: KnownSymbol l => Label l -> Rec r -> Rec (r .- l)
unsafeRemove _ (OR m) = OR m


{--------------------------------------------------------------------
  Folds and maps
--------------------------------------------------------------------}
-- An easier type synonym for a pair where both elements are the same type.
type IPair = Product Identity Identity

-- Construct an IPair.
iPair :: τ -> τ -> IPair τ
iPair = (. Identity) . Pair . Identity

-- Destruct an IPair.  Easily used with ViewPatterns.
unIPair :: IPair τ -> (τ, τ)
unIPair (Pair (Identity x) (Identity y)) = (x,y)


-- | A standard fold
erase :: forall c ρ b. Forall ρ c => (forall a. c a => a -> b) -> Rec ρ -> [b]
erase f = fmap (snd @String) . eraseWithLabels @c f

-- | A fold with labels
eraseWithLabels :: forall c ρ s b. (Forall ρ c, IsString s) => (forall a. c a => a -> b) -> Rec ρ -> [(s,b)]
eraseWithLabels f = getConst . metamorph @_ @ρ @c @Rec @(Const [(s,b)]) @Identity Proxy doNil doUncons doCons
  where doNil _ = Const []
        doUncons l r = (Identity $ r .! l, unsafeRemove l r)
        doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
               => Label ℓ -> Identity τ -> Const [(s,b)] ('R ρ) -> Const [(s,b)] ('R (ℓ :-> τ ': ρ))
        doCons l (Identity x) (Const c) = Const $ (show' l, f x) : c

-- | A fold over two row type structures at once
eraseZip :: forall c ρ b. Forall ρ c => (forall a. c a => a -> a -> b) -> Rec ρ -> Rec ρ -> [b]
eraseZip f x y = getConst $ metamorph @_ @ρ @c @(Product Rec Rec) @(Const [b]) @IPair Proxy (const $ Const []) doUncons doCons (Pair x y)
  where doUncons l (Pair r1 r2) = (iPair a b, Pair r1' r2')
          where (a, r1') = (r1 .! l, unsafeRemove l r1)
                (b, r2') = (r2 .! l, unsafeRemove l r2)
        doCons :: forall ℓ τ ρ. c τ
               => Label ℓ -> IPair τ -> Const [b] ('R ρ) -> Const [b] ('R (ℓ :-> τ ': ρ))
        doCons _ (unIPair -> x) (Const c) = Const $ uncurry f x : c

-- | Turns a record into a 'HashMap' from values representing the labels to
--   the values of the record.
eraseToHashMap :: forall c r s b. (IsString s, Eq s, Hashable s, Forall r c) =>
                  (forall a . c a => a -> b) -> Rec r -> HashMap s b
eraseToHashMap f r = M.fromList $ eraseWithLabels @c f r

-- | RMap is used internally as a type level lambda for defining record maps.
newtype RMap (f :: * -> *) (ρ :: Row *) = RMap { unRMap :: Rec (Map f ρ) }
newtype RMap2 (f :: * -> *) (g :: * -> *) (ρ :: Row *) = RMap2 { unRMap2 :: Rec (Map f (Map g ρ)) }

-- | A function to map over a record given a constraint.
map :: forall c f r. Forall r c => (forall a. c a => a -> f a) -> Rec r -> Rec (Map f r)
map f = unRMap . metamorph @_ @r @c @Rec @(RMap f) @Identity Proxy doNil doUncons doCons
  where
    doNil _ = RMap empty
    doUncons l r = (Identity $ r .! l, unsafeRemove l r)
    doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
           => Label ℓ -> Identity τ -> RMap f ('R ρ) -> RMap f ('R (ℓ :-> τ ': ρ))
    doCons l (Identity v) (RMap r) = RMap (unsafeInjectFront l (f v) r)

newtype RFMap (g :: k1 -> k2) (ϕ :: Row (k2 -> *)) (ρ :: Row k1) = RFMap { unRFMap :: Rec (Ap ϕ (Map g ρ)) }
newtype RecAp (ϕ :: Row (k -> *)) (ρ :: Row k) = RecAp (Rec (Ap ϕ ρ))
newtype App (f :: k -> *) (a :: k) = App (f a)

-- | A function to map over a Ap record given constraints.
mapF :: forall c g (ϕ :: Row (k -> *)) (ρ :: Row k). BiForall ϕ ρ c
     => (forall f a. (c f a) => f a -> f (g a))
     -> Rec (Ap ϕ ρ)
     -> Rec (Ap ϕ (Map g ρ))
mapF f = unRFMap . biMetamorph @_ @_ @ϕ @ρ @c @RecAp @(RFMap g) @App Proxy doNil doUncons doCons . RecAp
  where
    doNil _ = RFMap empty
    doUncons l (RecAp r) = (App $ r .! l, RecAp $ unsafeRemove l r)
    doCons :: forall ℓ τ1 τ2 ρ1 ρ2. (KnownSymbol ℓ, c τ1 τ2)
           => Label ℓ -> App τ1 τ2 -> RFMap g ('R ρ1) ('R ρ2) -> RFMap g ('R (ℓ :-> τ1 ': ρ1)) ('R (ℓ :-> τ2 ': ρ2))
    doCons l (App v) (RFMap r) = RFMap (unsafeInjectFront l (f @τ1 @τ2 v) r)

-- | A function to map over a record given no constraint.
map' :: forall f r. Forall r Unconstrained1 => (forall a. a -> f a) -> Rec r -> Rec (Map f r)
map' = map @Unconstrained1

-- | Lifts a natural transformation over a record.  In other words, it acts as a
-- record transformer to convert a record of @f a@ values to a record of @g a@
-- values.  If no constraint is needed, instantiate the first type argument with
-- 'Unconstrained1' or use 'transform''.
transform :: forall c r (f :: * -> *) (g :: * -> *). Forall r c => (forall a. c a => f a -> g a) -> Rec (Map f r) -> Rec (Map g r)
transform f = unRMap . metamorph @_ @r @c @(RMap f) @(RMap g) @f Proxy doNil doUncons doCons . RMap
  where
    doNil _ = RMap empty
    doUncons l (RMap r) = (r .! l, RMap $ unsafeRemove l r)
    doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
           => Label ℓ -> f τ -> RMap g ('R ρ) -> RMap g ('R (ℓ :-> τ ': ρ))
    doCons l v (RMap r) = RMap (unsafeInjectFront l (f v) r)

-- | A version of 'transform' for when there is no constraint.
transform' :: forall r (f :: * -> *) (g :: * -> *). Forall r Unconstrained1 => (forall a. f a -> g a) -> Rec (Map f r) -> Rec (Map g r)
transform' = transform @Unconstrained1 @r

-- | A version of 'sequence' in which the constraint for 'Forall' can be chosen.
sequence' :: forall f r c. (Forall r c, Applicative f)
          => Rec (Map f r) -> f (Rec r)
sequence' = getCompose . metamorph @_ @r @c @(RMap f) @(Compose f Rec) @f Proxy doNil doUncons doCons . RMap
  where
    doNil _ = Compose (pure empty)
    doUncons l (RMap r) = (r .! l, RMap $ unsafeRemove l r)
    doCons l fv (Compose fr) = Compose $ unsafeInjectFront l <$> fv <*> fr

-- | Applicative sequencing over a record.
sequence :: forall f r. (Forall r Unconstrained1, Applicative f)
         => Rec (Map f r) -> f (Rec r)
sequence = sequence' @_ @_ @Unconstrained1

-- $compose
-- We can easily convert between mapping two functors over the types of a row
-- and mapping the composition of the two functors.  The following two functions
-- perform this composition with the gaurantee that:
--
-- >>> compose . uncompose = id
--
-- >>> uncompose . compose = id

-- | A version of 'compose' in which the constraint for 'Forall' can be chosen.
compose' :: forall c (f :: * -> *) (g :: * -> *) (r :: Row *) . Forall r c
        => Rec (Map f (Map g r)) -> Rec (Map (Compose f g) r)
compose' = unRMap . metamorph @_ @r @c @(RMap2 f g) @(RMap (Compose f g)) @(Compose f g) Proxy doNil doUncons doCons . RMap2
  where
    doNil _ = RMap empty
    doUncons l (RMap2 r) = (Compose $ r .! l, RMap2 $ unsafeRemove l r)
    doCons l v (RMap r) = RMap $ unsafeInjectFront l v r

-- | Convert from a record where two functors have been mapped over the types to
-- one where the composition of the two functors is mapped over the types.
compose :: forall (f :: * -> *) (g :: * -> *) r . Forall r Unconstrained1
        => Rec (Map f (Map g r)) -> Rec (Map (Compose f g) r)
compose = compose' @Unconstrained1 @f @g @r

-- | A version of 'uncompose' in which the constraint for 'Forall' can be chosen.
uncompose' :: forall c (f :: * -> *) (g :: * -> *) r . Forall r c
           => Rec (Map (Compose f g) r) -> Rec (Map f (Map g r))
uncompose' = unRMap2 . metamorph @_ @r @c @(RMap (Compose f g)) @(RMap2 f g) @(Compose f g) Proxy doNil doUncons doCons . RMap
  where
    doNil _ = RMap2 empty
    doUncons l (RMap r) = (r .! l, RMap $ unsafeRemove l r)
    doCons l (Compose v) (RMap2 r) = RMap2 $ unsafeInjectFront l v r

-- | Convert from a record where the composition of two functors have been mapped
-- over the types to one where the two functors are mapped individually one at a
-- time over the types.
uncompose :: forall (f :: * -> *) (g :: * -> *) r . Forall r Unconstrained1
          => Rec (Map (Compose f g) r) -> Rec (Map f (Map g r))
uncompose = uncompose' @Unconstrained1 @f @g @r


-- | RZipPair is used internally as a type level lambda for zipping records.
newtype RecPair  (ρ1 :: Row *) (ρ2 :: Row *) = RecPair  (Rec ρ1, Rec ρ2)
newtype RZipPair (ρ1 :: Row *) (ρ2 :: Row *) = RZipPair { unRZipPair :: Rec (Zip ρ1 ρ2) }

-- | Zips together two records that have the same set of labels.
zip :: forall r1 r2. BiForall r1 r2 Unconstrained2 => Rec r1 -> Rec r2 -> Rec (Zip r1 r2)
zip r1 r2 = unRZipPair $ biMetamorph @_ @_ @r1 @r2 @Unconstrained2 @RecPair @RZipPair @(,) Proxy doNil doUncons doCons $ RecPair (r1, r2)
  where
    doNil _ = RZipPair empty
    doUncons l (RecPair (r1, r2)) = ((r1 .! l, r2 .! l), RecPair (unsafeRemove l r1, unsafeRemove l r2))
    doCons l (v1, v2) (RZipPair r) = RZipPair $ unsafeInjectFront l (v1, v2) r

-- | A helper function for unsafely adding an element to the front of a record.
-- This can cause the resulting record to be malformed, for instance, if the record
-- already contains labels that are lexicographically before the given label.
-- Realistically, this function should only be used when writing calls to 'metamorph'.
unsafeInjectFront :: KnownSymbol l => Label l -> a -> Rec (R r) -> Rec (R (l :-> a ': r))
unsafeInjectFront (toKey -> a) b (OR m) = OR $ M.insert a (HideType b) m
{-# INLINE unsafeInjectFront #-}


{--------------------------------------------------------------------
  Record initialization
--------------------------------------------------------------------}

-- | Initialize a record with a default value at each label.
default' :: forall c ρ. (Forall ρ c, AllUniqueLabels ρ) => (forall a. c a => a) -> Rec ρ
default' v = runIdentity $ defaultA @c $ pure v

-- | Initialize a record with a default value at each label; works over an 'Applicative'.
defaultA :: forall c f ρ. (Applicative f, Forall ρ c, AllUniqueLabels ρ)
         => (forall a. c a => f a) -> f (Rec ρ)
defaultA v = fromLabelsA @c $ pure v

-- | Initialize a record, where each value is determined by the given function over
-- the label at that value.
fromLabels :: forall c ρ. (Forall ρ c, AllUniqueLabels ρ)
           => (forall l a. (KnownSymbol l, c a) => Label l -> a) -> Rec ρ
fromLabels f = runIdentity $ fromLabelsA @c $ (pure .) f

-- | Initialize a record, where each value is determined by the given function over
-- the label at that value.  This function works over an 'Applicative'.
fromLabelsA :: forall c f ρ. (Applicative f, Forall ρ c, AllUniqueLabels ρ)
            => (forall l a. (KnownSymbol l, c a) => Label l -> f a) -> f (Rec ρ)
fromLabelsA mk = getCompose $ metamorph @_ @ρ @c @(Const ()) @(Compose f Rec) @(Const ()) Proxy doNil doUncons doCons (Const ())
  where doNil _ = Compose $ pure empty
        doUncons _ _ = (Const (), Const ())
        doCons :: forall ℓ τ ρ. (KnownSymbol ℓ, c τ)
               => Label ℓ -> Const () τ -> Compose f Rec ('R ρ) -> Compose f Rec ('R (ℓ :-> τ ': ρ))
        doCons l _ (Compose r) = Compose $ unsafeInjectFront l <$> mk l <*> r

-- | Initialize a record that is produced by a `Map`.
fromLabelsMapA :: forall c f g ρ. (Applicative f, Forall ρ c, AllUniqueLabels ρ)
               => (forall l a. (KnownSymbol l, c a) => Label l -> f (g a)) -> f (Rec (Map g ρ))
fromLabelsMapA f = fromLabelsA @(IsA c g) @f @(Map g ρ) inner
                \\ mapForall @g @c @ρ
                \\ uniqueMap @g @ρ
   where inner :: forall l a. (KnownSymbol l, IsA c g a) => Label l -> f a
         inner l = case as @c @g @a of As -> f l


{--------------------------------------------------------------------
  Dynamic compatibility
--------------------------------------------------------------------}

-- | Converts a 'Rec' into a 'HashMap' of 'Dynamic's.
toDynamicMap :: Forall r Typeable => Rec r -> HashMap Text Dynamic
toDynamicMap = eraseToHashMap @Typeable @_ @Text @Dynamic toDyn

-- | Produces a 'Rec' from a 'HashMap' of 'Dynamic's.
fromDynamicMap :: (AllUniqueLabels r, Forall r Typeable)
               => HashMap Text Dynamic -> Maybe (Rec r)
fromDynamicMap m = fromLabelsA @Typeable
  $ \ (toKey -> k) -> M.lookup k m >>= fromDynamic


{--------------------------------------------------------------------
  Native data type compatibility
--------------------------------------------------------------------}
-- ToNative is shamelessly copied from
--   https://www.athiemann.net/2017/07/02/superrecord.html

-- $native
-- The 'toNative' and 'fromNative' functions allow one to convert between
-- 'Rec's and regular Haskell data types ("native" types) that have a single constructor and any
-- number of named fields with the same names and types as the 'Rec'.  That
-- said, they do not compose to form the identity because 'toNative' allows
-- fields to be dropped: a record with excess fields can still be transformed
-- to a native type, but when the native type is converted to a record, the
-- fields are exactly transformed.  Because of this, 'toNative' requires a type
-- application (although 'fromNative' does not).  The only requirement is that
-- the native Haskell data type be an instance of 'Generic'.
--
-- For example, consider the following simple data type:
--
-- >>> data Person = Person { name :: String, age :: Int} deriving (Generic, Show)
--
-- Then, we have the following:
--
-- >>> toNative @Person $ #name .== "Alice" .+ #age .== 7 .+ #hasDog .== True
-- Person {name = "Alice", age = 7}
-- >>> fromNative $ Person "Bob" 9
-- { age=9, name="Bob" }
--
-- The 'toNativeExact' function is a more restricted version of 'toNative' that
-- does not allow fields to be dropped; in other words, the fields in the record
-- must exactly match the fields in the data type.  Because of this, 'toNativeExact'
-- and 'fromNative' compose to form the identity function.


-- | Conversion helper to bring a record back into a Haskell type. Note that the
-- native Haskell type must be an instance of 'Generic'.
class ToNative a ρ where
  toNative' :: Rec ρ -> a x

instance ToNative cs ρ => ToNative (G.D1 m cs) ρ where
  toNative' xs = G.M1 $ toNative' xs

instance ToNative cs ρ => ToNative (G.C1 m cs) ρ where
  toNative' xs = G.M1 $ toNative' xs

instance ToNative G.U1 ρ where
  toNative' _ = G.U1

instance (KnownSymbol name, ρ .! name ≈ t)
    => ToNative (G.S1 ('G.MetaSel ('Just name) p s l) (G.Rec0 t)) ρ where
  toNative' r = G.M1 $ G.K1 $ r .! (Label @name)

instance (ToNative l ρ, ToNative r ρ)
    => ToNative (l G.:*: r) ρ where
  toNative' r = toNative' r G.:*: toNative' r

-- | Convert a record to a native Haskell type.
toNative :: forall t ρ. (G.Generic t, ToNative (G.Rep t) ρ) => Rec ρ -> t
toNative = G.to . toNative'


-- | Conversion helper to bring a record back into a Haskell type. Note that the
-- native Haskell type must be an instance of 'Generic'.
class ToNativeExact a ρ where
  toNativeExact' :: Rec ρ -> a x

instance ToNativeExact cs ρ => ToNativeExact (G.D1 m cs) ρ where
  toNativeExact' xs = G.M1 $ toNativeExact' xs

instance ToNativeExact cs ρ => ToNativeExact (G.C1 m cs) ρ where
  toNativeExact' xs = G.M1 $ toNativeExact' xs

instance ToNativeExact G.U1 Empty where
  toNativeExact' _ = G.U1

instance (KnownSymbol name, ρ ≈ name .== t)
    => ToNativeExact (G.S1 ('G.MetaSel ('Just name) p s l) (G.Rec0 t)) ρ where
  toNativeExact' r = G.M1 $ G.K1 $ r .! (Label @name)

instance (ToNativeExact l ρ₁, ToNativeExact r ρ₂, ρ ≈ ρ₁ .+ ρ₂, Disjoint ρ₁ ρ₂)
    => ToNativeExact (l G.:*: r) ρ where
  toNativeExact' r = toNativeExact' r1 G.:*: toNativeExact' r2
    where
      (r1 :: Rec ρ₁) :+ (r2 :: Rec ρ₂) = r

-- | Convert a record to an exactly matching native Haskell type.
toNativeExact :: forall t ρ. (G.Generic t, ToNativeExact (G.Rep t) ρ) => Rec ρ -> t
toNativeExact = G.to . toNativeExact'


-- | Conversion helper to turn a Haskell record into a row-types extensible
-- record. Note that the native Haskell type must be an instance of 'Generic'.
class FromNative a ρ where
  fromNative' :: a x -> Rec ρ

instance FromNative cs ρ => FromNative (G.D1 m cs) ρ where
  fromNative' (G.M1 xs) = fromNative' xs

instance FromNative cs ρ => FromNative (G.C1 m cs) ρ where
  fromNative' (G.M1 xs) = fromNative' xs

instance FromNative G.U1 Empty where
  fromNative' G.U1 = empty

instance (KnownSymbol name, ρ ≈ name .== t)
    => FromNative (G.S1 ('G.MetaSel ('Just name) p s l) (G.Rec0 t)) ρ where
  fromNative' (G.M1 (G.K1 x)) =  (Label @name) .== x

instance (FromNative l ρ₁, FromNative r ρ₂, ρ ≈ ρ₁ .+ ρ₂)
    => FromNative (l G.:*: r) ρ where
  fromNative' (x G.:*: y) = fromNative' @l @ρ₁ x .+ fromNative' @r @ρ₂ y

-- | Convert a Haskell record to a row-types Rec.
fromNative :: forall t ρ. (G.Generic t, FromNative (G.Rep t) ρ) => t -> Rec ρ
fromNative = fromNative' . G.from
