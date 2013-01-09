{-# LANGUAGE CPP #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

#ifndef MIN_VERSION_base
#define MIN_VERSION_base(x,y,z) 0
#endif
--------------------------------------------------------------------
-- |
-- Module    :  Ermine.Meta
-- Copyright :  (c) Edward Kmett 2011-2012
-- License   :  BSD3
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
-- Skolem and Meta variables
--------------------------------------------------------------------
module Ermine.Meta
  (
  -- * Meta variables
    Meta(Meta,Skolem)
  , metaId, metaValue, metaRef
  -- ** Meta Prisms
  , skolem
  -- ** λ-Depth
  , Depth, metaDepth, depthInf
  -- ** Union-By-Rank
  , Rank, metaRank, bumpRank
  -- ** Working with Meta
  , newMeta
  , newSkolem
  , readMeta
  , writeMeta
  -- ** Pruning
  , semiprune
  , zonk
  -- * MetaEnv
  , MetaEnv
  , HasMetaEnv(..)
  -- * The unification monad
  , M, runM, runM_
  , fresh
  ) where
import Control.Applicative
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Monad.Reader.Class
import Control.Monad.ST (ST, runST)
import Control.Monad.ST.Class
import Control.Monad.ST.Unsafe
import Data.STRef
import Data.Function (on)
import Data.IntSet
import Data.Monoid
import Data.Traversable
import Data.Word
import Ermine.Syntax
import Ermine.Diagnostic

------------------------------------------------------------------------------
-- MetaEnv
------------------------------------------------------------------------------

data MetaEnv s = MetaEnv { _metaRendering :: Rendering, _metaFresh :: {-# UNPACK #-} !(STRef s Int) }

makeClassy ''MetaEnv

instance HasRendering (MetaEnv s) where
  rendering = metaRendering

------------------------------------------------------------------------------
-- Meta
------------------------------------------------------------------------------

-- | Depth and MacQueen's notion of λ-ranking.
type Depth = Int

-- | This plays the role of infinity.
depthInf :: Depth
depthInf = maxBound

-- | Rank for union-by-rank viewing meta-variables as disjoint set forests
type Rank = Word

bumpRank :: STRef s Rank -> ST s ()
#if MIN_VERSION_base(4,6,0)
bumpRank w = modifySTRef' w (+1)
#else
bumpRank w = do
  n <- readSTRef w
  let n' = n + 1
  n' `seq` writeSTRef w n'
#endif

-- | A meta variable for skolemization and unification
data Meta s f a
  = Meta   { _metaValue :: a, _metaId :: !Int, _metaRef :: !(STRef s (Maybe (f (Meta s f a)))), _metaDepth :: !(STRef s Depth), _metaRank :: !(STRef s Rank) }
  | Skolem { _metaValue :: a, _metaId :: !Int }

makeLenses ''Meta

-- | This 'Prism' matches 'Skolem' variables.
skolem :: Prism' (Meta s f a) (a, Int)
skolem = prism (uncurry Skolem) $ \t -> case t of
  Skolem a i -> Right (a, i)
  _ -> Left t

{-
meta :: Prism (Meta s f a)
              (Meta s g a)
              (a, Int, STRef s (Maybe (f (Meta s f a))), STRef s Depth, STRef s Rank)
              (a, Int, STRef s (Maybe (g (Meta s g a))), STRef s Depth, STRef s Rank)
meta = prism (\(a,i,r,k,u) -> Meta a i r k u) $ \t -> case t of
  Meta a i r k u -> Right (a,i,r,k,u)
  _ -> Left t
-}

instance Show a => Show (Meta s f a) where
  showsPrec d (Meta a i _ _ _) = showParen (d > 10) $
    showString "Meta " . showsPrec 11 a . showChar ' ' . showsPrec 11 i . showString " ..."
  showsPrec d (Skolem a i) = showParen (d > 10) $
    showString "Skolem " . showsPrec 11 a . showChar ' ' . showsPrec 11 i

instance Eq (Meta s f a) where
  (==) = (==) `on` view metaId
  {-# INLINE (==) #-}

instance Ord (Meta s f a) where
  compare = compare `on` view metaId
  {-# INLINE compare #-}

-- | Construct a new meta variable
newMeta :: a -> M s (Meta s f a)
newMeta a = Meta a <$> fresh <*> liftST (newSTRef Nothing) <*> liftST (newSTRef depthInf) <*> liftST (newSTRef 0)
{-# INLINE newMeta #-}

-- | Construct a new Skolem variable that unifies only with itself.
newSkolem :: a -> M s (Meta s f a)
newSkolem a = Skolem a <$> fresh
{-# INLINE newSkolem #-}

-- | Read a meta variable
readMeta :: Meta s f a -> M s (Maybe (f (Meta s f a)))
readMeta (Meta _ _ r _ _) = liftST $ readSTRef r
readMeta (Skolem _ _)   = return Nothing
{-# INLINE readMeta #-}

-- | Write to a meta variable
writeMeta :: Meta s f a -> f (Meta s f a) -> M s ()
writeMeta (Meta _ _ r _ _) a = liftST $ writeSTRef r (Just a)
writeMeta (Skolem _ _) _   = fail "writeMeta: skolem"
{-# INLINE writeMeta #-}

-- | Path-compression
semiprune :: (Variable f, Monad f) => f (Meta s f a) -> M s (f (Meta s f a))
semiprune t0 = case preview var t0 of
  Just v0 -> loop t0 v0
  Nothing -> return t0
  where
    loop t1 v1 = readMeta v1 >>= \mb -> case mb of
      Nothing -> return t1
      Just t  -> case preview var t of
        Nothing -> return t -- t1?
        Just v  -> do
          fv <- loop t v
          writeMeta v1 fv
          return fv
{-# INLINE semiprune #-}

-- | Expand meta variables recursively
zonk :: (Monad f, Traversable f) => IntSet -> f (Meta s f a) -> M s (f (Meta s f a))
zonk is fs = fmap join . for fs $ \m -> readMeta m >>= \mv -> case mv of
  Nothing  -> return (return m)
  Just fmf
    | is^.ix (m^.metaId) -> fail "zonk: occurs"
    | otherwise -> do
    r <- zonk (is & ix (m^.metaId) .~ True) fmf
    r <$ writeMeta m r

------------------------------------------------------------------------------
-- Result
------------------------------------------------------------------------------

-- | The internal result type used by 'M'.
data Result a
  = Error !Diagnostic
  | OK !Int a

instance Functor Result where
  fmap f (OK n a) = OK n (f a)
  fmap _ (Error d) = Error d
  {-# INLINE fmap #-}

------------------------------------------------------------------------------
-- M
------------------------------------------------------------------------------

-- | The unification monad provides a 'fresh' variable supply and tracks a current
-- 'Rendering' to blame for any unification errors.
newtype M s a = M { unM :: MetaEnv s -> ST s a }

instance Functor (M s) where
  fmap f (M m) = M (fmap f . m)
  {-# INLINE fmap #-}

instance Applicative (M s) where
  pure = return
  {-# INLINE pure #-}
  (<*>) = ap
  {-# INLINE (<*>) #-}

instance Monad (M s) where
  return = M . const . return
  {-# INLINE return #-}
  M m >>= k = M $ \ e -> do
    a <- m e
    unM (k a) e
  {-# INLINE (>>=) #-}
  fail s = M $ \e -> unsafeIOToST $ throwIO $! die e s

instance MonadST (M s) where
  type World (M s) = s
  liftST m = M $ \_ -> m
  {-# INLINE liftST #-}

instance MonadReader (MetaEnv s) (M s) where
  ask = M $ \e -> return e
  {-# INLINE ask #-}
  local f (M m) = M (m . f)
  {-# INLINE local #-}

catchingST :: Getting (Endo (Maybe a)) SomeException t a b -> ST s r -> (a -> ST s r) -> ST s r
catchingST l m h = unsafeIOToST $ catchJust (preview l) (unsafeSTToIO m) (unsafeSTToIO . h)
{-# INLINE catchingST #-}

-- | Evaluate an expression in the 'M' 'Monad' with a fresh variable supply.
runM :: Rendering -> (forall s. M s a) -> Either Diagnostic a
runM r m = runST $ do
  i <- newSTRef 0
  catchingST diagnostic (Right <$> unM m (MetaEnv r i)) (return . Left)
{-# INLINE runM #-}

-- | Evaluate an expression in the 'M' 'Monad' with a fresh variable supply, throwing any errors returned.
runM_ :: Rendering -> (forall s. M s a) -> a
runM_ r m = runST $ do
  i <- newSTRef 0
  unM m (MetaEnv r i)

-- | Generate a 'fresh' variable
fresh :: M s Int
fresh = do
  s <- view metaFresh
  liftST $ do
    i <- readSTRef s
    writeSTRef s $! i + 1
    return i
{-# INLINE fresh #-}
