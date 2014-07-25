
{-# LANGUAGE TemplateHaskell, FlexibleContexts #-}

module LensTest where

import Control.Lens
import Control.Applicative
import Control.Monad.State hiding (State)
import Control.Monad.Reader
import Control.Monad

import qualified Data.Vector.Unboxed.Mutable as VUM

data State = State { _stSomeInt :: Int
                   , _stFloatPair :: (Float, Float)
                   , _stIntList :: [Int]
                   }

data Env = Env { _envConstInt :: Int
               , _envVUM :: VUM.IOVector Int
               }

makeLenses ''State
makeLenses ''Env

zoomTest :: StateT (Float, Float) (ReaderT Env IO) ()
zoomTest = do
    a <- use _1
    _1 += 5
    _2 += 5

zoomTest2 :: (MonadState (Float, Float) m, Applicative m) => m Float
zoomTest2 = do
    _1 += 5
    _2 += 5
    (+) <$> use _1 <*> use _2

-- (1, 2) ^. _1
-- ((1, 2, 3) :: (Int, Int, Int)) & _1 +~ 1
-- (1, 2) & _1 .~ 0
-- (1, 2) & _1 %~ (+ 1) == over _1 (+ 1) $ (1, 2)
-- (0, [1, 2]) & _2.mapped %~ (+ 1)
-- (0, [1, 2]) & _2.traversed +~ 1
-- ([4, 5, 6], [1, 2]) & both.mapped %~ (+ 1)
-- [Just 10, Nothing, Just 3, Nothing] & mapped.mapped %~ succ
-- (5, 6) & both *~ 2 == over both (*2) (5, 6)
-- (fromList [("one", 1), ("two", 2), ("three", 3)] :: Map String Int) & mapped %~ succ
-- (Data.Set.fromList ["one", "two", "three"]) ^. contains "one"
-- (Left 2) & _Left %~ succ
-- flip runState (Left (10 :: Int)) $ _Left %= succ

evenPrism :: (Integral a) => Prism' a a
evenPrism = prism id $ \i -> if even i then Right i else Left i
-- [0, 1, 2, 3, 4, 5] & mapped.evenPrism .~ 0
-- [0, 1, 2, 3, 4, 5] ^.. traversed.evenPrism

runLensTest :: IO ()
runLensTest = do
    newVec <- VUM.new 100
    void . flip runReaderT (Env 0 newVec) . flip runStateT (State 0 (0, 0) []) $ do
        --envVUM ^! act (\v -> VUM.write v 0 0)
        view envVUM >>= (\v -> liftIO $ VUM.write v 0 0)
        ci <- view envConstInt
        stSomeInt .= 5
        stFloatPair._1 += 1
        tmp <- stFloatPair._1 <+= 1
        stIntList.mapped %= (+ 1)
        modify' (\s -> s & stFloatPair._1 +~ 1)
        sint <- use stSomeInt
        liftIO $ print (sint + 10)
        zoom stFloatPair $ do
            _1 += 5
            _2 += 5
            both += 1
            zoomTest
            _1 <~ zoomTest2
        return ()

