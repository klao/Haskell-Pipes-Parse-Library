{-| Parsing utilities for proxies

    This module also provides an orphan 'S.MonadState' instance for 'StateP':

> instance (Monad m, Proxy p) => MonadState s (StateP s p a' a b' b m) where ...
-}

{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}

module Control.Proxy.Parse (
    -- * Leftovers
    draw,
    unDraw,

    -- * Utilities
    peek,
    isEndOfInput,
    skipAll,
    passUpToN,
    passWhile,

    -- * Adapters
    wrap,
    unwrap,
    fmapPull,
    returnPull,
    bindPull,

    -- * Lenses
    zoom,
    _fst,
    _snd,
    (/\),

    -- * Re-exports
    module Control.Proxy.Trans.State
    ) where

import Control.Monad (forever)
import qualified Control.Monad.State.Class as S
import Control.Proxy ((>->), (\>\), (//>), (>\\), (?>=))
import qualified Control.Proxy as P
import Control.Proxy.Trans.State (
    StateP(StateP, unStateP),
    state,
    stateT,
    runStateP,
    runStateK,
    evalStateP,
    evalStateK,
    execStateP,
    execStateK,
    get,
    put,
    modify,
    gets )

instance (Monad m, P.Proxy p) => S.MonadState s (StateP s p a' a b' b m) where
    get = get
    put = put

-- | Like @request ()@, except try to use the leftovers buffer first
draw :: (Monad m, P.Proxy p) => StateP [a] p () (Maybe a) y' y m (Maybe a)
draw = do
    s <- get
    case s of
        []   -> P.request ()
        a:as -> do
            put as
            return (Just a)

-- | Push an element back onto the leftovers buffer
unDraw :: (Monad m, P.Proxy p) => a -> StateP [a] p x' x y' y m ()
unDraw a = modify (a:)

-- | Peek at the next element without consuming it
peek :: (Monad m, P.Proxy p) => StateP [a] p () (Maybe a) y' y m (Maybe a)
peek = do
    ma <- draw
    case ma of
        Nothing -> return ()
        Just a  -> unDraw a
    return ma

-- | Check if at end of stream
isEndOfInput :: (Monad m, P.Proxy p) => StateP [a] p () (Maybe a) y' y m Bool
isEndOfInput = do
    ma <- peek
    case ma of
        Nothing -> return True
        Just _  -> return False

-- | Drain all input
skipAll :: (Monad m, P.Proxy p) => () -> StateP [a] p () (Maybe a) y' y m ()
skipAll () = loop
  where
    loop = do
        ma <- draw
        case ma of
            Nothing -> return ()
            Just _  -> loop

-- | Pass up to the specified number of elements
passUpToN
    :: (Monad m, P.Proxy p)
    => Int -> () -> StateP [a] p () (Maybe a) () (Maybe a) m r
passUpToN n0 () = go n0
  where
    go n0 =
        if (n0 <= 0)
        then forever $ P.respond Nothing
        else do
            ma <- draw
            P.respond ma
            case ma of
                Nothing -> forever $ P.respond Nothing
                Just _  -> go (n0 - 1)

-- | Pass as many consecutive elements satisfying a predicate as possible
passWhile
    :: (Monad m, P.Proxy p)
    => (a -> Bool) -> () -> StateP [a] p () (Maybe a) () (Maybe a) m r
passWhile pred () = go
  where
    go = do
        ma <- draw
        case ma of
            Nothing -> forever $ P.respond Nothing
            Just a  ->
                if (pred a)
                then do
                    P.respond ma
                    go
                else do
                    unDraw a
                    forever $ P.respond Nothing

{-| Guard a pipe from terminating by wrapping every output in 'Just' and ending
    with a never-ending stream of 'Nothing's
-}
wrap :: (Monad m, P.Proxy p) => p a' a b' b m r -> p a' a b' (Maybe b) m s
wrap p = P.runIdentityP $ do
    P.IdentityP p //> \b -> P.respond (Just b)
    forever $ P.respond Nothing

{-| Compose 'unwrap' downstream of a guarded pipe to unwrap all 'Just's and
    terminate on the first 'Nothing'
-}
unwrap :: (Monad m, P.Proxy p) => x -> p x (Maybe a) x a m ()
unwrap x = P.runIdentityP (go x)
  where
    go x = do
        ma <- P.request x
        case ma of
            Nothing -> return ()
            Just a  -> do
                x2 <- P.respond a
                go x2

{-| Lift a 'Maybe'-oblivious pipe to a 'Maybe'-aware pipe by auto-forwarding
    all 'Nothing's

> fmapPull f >-> fmapPull g = fmapPull (f >-> g)
>
> fmapPull pull = pull
-}
fmapPull
    :: (Monad m, P.Proxy p)
    => (x -> p x        a  x        b  m r)
    -> (x -> p x (Maybe a) x (Maybe b) m r)
fmapPull f = bindPull (f >-> returnPull)

-- | Wrap all values in 'Just'
returnPull :: (Monad m, P.Proxy p) => x -> p x a x (Maybe a) m r
returnPull = P.mapD Just

{-| Lift a 'Maybe'-generating pipe to a 'Maybe'-transforming pipe by
    auto-forwarding all 'Nothing's

> -- Using: f >>> g = f >-> bindPull g
>
> returnPull >>> f = f
>
> f >>> returnPull = f
>
> (f >>> g) >>> h = f >>> (g >>> h)

Or equivalently:

> returnPull >-> bindPull f = f
>
> bindPull returnPull = pull
>
> bindPull (f >-> bindPull g) = bindPull f >-> bindPull g
-}
bindPull
    :: (Monad m, P.Proxy p)
    => (x -> p x        a  x (Maybe b) m r)
    -> (x -> p x (Maybe a) x (Maybe b) m r)
bindPull f = P.runIdentityP . (up \>\ P.IdentityP . f)
  where
    up a' = do
        ma <- P.request a'
        case ma of
            Nothing -> do
                a'2 <- P.respond Nothing
                up a'2
            Just a  -> return a

{-| 'zoom' in on a sub-state using a @Lens@

> zoom :: Lens' s1 s2 -> StateP s2 p a' a b' b m r -> StateP s1 p a' a b' b m r

> zoom (f . g) = zoom f . zoom g
>
> zoom id = id
-}
zoom
    :: (Monad m, P.Proxy p)
    => ((s2 -> (s2, s2)) -> (s1 -> (s2, s1)))
    -- ^ Lens' s1 s2
    -> StateP s2 p a' a b' b m r
    -- ^ Local state
    -> StateP s1 p a' a b' b m r
    -- ^ Global state
zoom lens p = StateP $ \s2_0 ->
    let (s1_0, s2_0') = lens (\x -> (x, x)) s2_0
    in  (up >\\ P.thread_P (unStateP p s1_0) s2_0' //> dn) ?>= nx
  where
    up ((a', s1), s2) =
        let (_, s2') = lens (\x -> (x, s1)) s2
        in  P.request (a', s2') ?>= \(a, s2'') ->
            let (s1', s2''') = lens (\x -> (x, x)) s2''
            in  P.return_P ((a, s1'), s2''')
    dn ((b, s1), s2) =
        let (_, s2') = lens (\x -> (x, s1)) s2
        in  P.respond (b, s2') ?>= \(b', s2'') ->
            let (s1', s2''') = lens (\x -> (x, x)) s2''
            in  P.return_P ((b', s1'), s2''')
    nx ((r, s1), s2) =
        let (_, s2') = lens (\x -> (x, s1)) s2
        in  P.return_P (r, s2')

{-| A lens to the first element of a pair

    Like @_1@, but more monomorphic

> _fst :: Lens' (a, b) a
-}
_fst :: (Functor f) => (a -> f b) -> ((a, x) -> f (b, x))
_fst f (a, x) = fmap (\b -> (b, x)) (f a)

{-| A lens to the second element of a pair

    Like @_2@, but more monomorphic

> _snd :: Lens' (a, b) b
-}
_snd :: (Functor f) => (a -> f b) -> ((x, a) -> f (x, b))
_snd f (x, a) = fmap (\b -> (x, b)) (f a)

{-| Pair up two lenses

> (/\) :: Lens' c a -> Lens' c b -> Lens' c (a, b)

> _fst /\ _snd = id
-}
(/\)
    :: (Functor f)
    => ((a -> (a, a)) -> (c -> (a, c)))
    -- ^ Lens' c a
    -> ((b -> (b, b)) -> (c -> (b, c)))
    -- ^ Lens' c b
    -> (((a, b) -> f (a, b)) -> (c -> f c))
    -- ^ Lens' c (a, b)
(lens1 /\ lens2) f c0 =
    let (a, _) = lens1 (\a_ -> (a_, a_)) c0
        (b, _) = lens2 (\b_ -> (b_, b_)) c0
        fab = f (a, b)
    in  fmap (\(a, b) ->
            let (_, c1) = lens1 (\a_ -> (a_, a)) c0
                (_, c2) = lens2 (\b_ -> (b_, b)) c1
            in  c2
            ) fab

infixl 7 /\
