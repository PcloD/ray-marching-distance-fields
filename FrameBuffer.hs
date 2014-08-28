
{-# LANGUAGE RecordWildCards, FlexibleContexts, LambdaCase #-}

module FrameBuffer ( withFrameBuffer
                   , fillFrameBuffer
                   , drawFrameBuffer
                   , saveFrameBufferToPNG
                   , resizeFrameBuffer
                   , getFrameBufferDim
                   , drawIntoFrameBuffer
                   , FrameBuffer
                   , Downscaling(..)
                   ) where

import Control.Monad
import Control.Applicative
import Control.Exception
import Control.Monad.Trans
import Control.Monad.Trans.Control
import qualified Graphics.Rendering.OpenGL as GL
import qualified Graphics.Rendering.OpenGL.Raw as GLR
import Data.Word
import Data.IORef
import qualified Data.Vector.Storable.Mutable as VSM
import qualified Data.Vector.Storable as VS
import Text.Printf
import Foreign.Storable
import Foreign.Ptr
import Foreign.ForeignPtr
import qualified Codec.Picture as JP

import GLHelpers
import QuadRendering
import Trace

-- Simple 'frame buffer' interface where we can either directly write into an RGBA8 vector CPU
-- side or render into a texture with the GPU and have it appear on screen, optionally with
-- super sampling

data FrameBuffer = FrameBuffer { fbTex         :: !GL.TextureObject
                               , fbPBO         :: !GL.BufferObject
                               , fbDim         :: IORef (Int, Int)
                               , fbFBO         :: !GL.FramebufferObject
                               , fbDownscaling :: !Downscaling
                               }

data Downscaling = HighQualityDownscaling | LowQualityDownscaling
                   deriving (Show, Eq)

withFrameBuffer :: Int -> Int -> Downscaling -> (FrameBuffer -> IO a) -> IO a
withFrameBuffer w h fbDownscaling f = do
    traceOnGLError $ Just "withFrameBuffer begin"
    r <- bracket GL.genObjectName GL.deleteObjectName $ \fbTex ->
         bracket GL.genObjectName GL.deleteObjectName $ \fbPBO ->
         bracket GL.genObjectName GL.deleteObjectName $ \fbFBO -> do
             -- Setup texture
             GL.textureBinding GL.Texture2D GL.$= Just fbTex
             setTextureFiltering GL.Texture2D $
                 if   fbDownscaling == HighQualityDownscaling
                 then TFMinMag -- Need to generate MIP-maps after every change
                 else TFMagOnly
             setTextureClampST GL.Texture2D -- No wrap-around artifacts at the FB borders
             -- Setup FBO
             GL.bindFramebuffer GL.Framebuffer GL.$= fbFBO
             GL.framebufferTexture2D GL.Framebuffer (GL.ColorAttachment 0) GL.Texture2D fbTex 0
             GL.drawBuffer GL.$= GL.FBOColorAttachment 0
             GL.bindFramebuffer GL.Framebuffer GL.$= GL.defaultFramebufferObject
             -- Inner
             traceOnGLError $ Just "withFrameBuffer begin inner"
             fbDim <- newIORef (w, h)
             f FrameBuffer { .. }
    traceOnGLError $ Just "withFrameBuffer after cleanup"
    return r

resizeFrameBuffer :: FrameBuffer -> Int -> Int -> IO ()
resizeFrameBuffer fb w h = do
    writeIORef (fbDim fb) (w, h)
    -- Clear contents to black
    void . drawIntoFrameBuffer fb $ \_ _ -> do
        GL.clearColor GL.$= (GL.Color4 0 0 0 1 :: GL.Color4 GL.GLclampf)
        GL.clear [GL.ColorBuffer]

getFrameBufferDim :: FrameBuffer -> IO (Int, Int)
getFrameBufferDim fb = readIORef $ fbDim fb

-- Specify the frame buffer contents by filling a mutable vector
fillFrameBuffer :: (MonadBaseControl IO m, MonadIO m)
                => FrameBuffer
                -> (Int -> Int -> VSM.MVector s Word32 -> m a) -- Run inner inside the base monad
                -> m (Maybe a)                                 -- Return Nothing if mapping fails
fillFrameBuffer fb@(FrameBuffer { .. }) f = do
    -- Map. If this function is nested inside another fillFrameBuffer with the same FrameBuffer,
    -- the mapping operation will fail as OpenGL does not allow two concurrent mappings. Hence,
    -- no need to check for this explicitly
    (w, h) <- liftIO $ readIORef fbDim
    r <- control $ \run -> liftIO $ do
      let bindPBO = GL.bindBuffer GL.PixelUnpackBuffer GL.$= Just fbPBO
          -- Prevent stalls by just allocating new PBO storage every time
       in bindPBO >> allocPBO fb >> GL.withMappedBuffer
            GL.PixelUnpackBuffer
            GL.WriteOnly
            ( \ptrPBO -> newForeignPtr_ ptrPBO >>= \fpPBO ->
                finally
                  -- Run in outer base monad
                  ( run $ Just <$> f w h (VSM.unsafeFromForeignPtr0 fpPBO $ fbSizeB w h) )
                  bindPBO -- Make sure we rebind our PBO, otherwise
                          -- unmapping might fail if the inner
                          -- modified the bound buffer objects
            )
            ( \mf -> do traceS TLError $ "fillFrameBuffer - PBO mapping failure: " ++ show mf
                        run $ return Nothing
            )
    liftIO $ do
      -- Update frame buffer texture from the PBO data
      GL.textureBinding GL.Texture2D GL.$= Just fbTex
      texImage2DNullPtr w h
      when (fbDownscaling == HighQualityDownscaling) $
          GLR.glGenerateMipmap GLR.gl_TEXTURE_2D
      -- Done
      GL.bindBuffer GL.PixelUnpackBuffer GL.$= Nothing
      GL.textureBinding GL.Texture2D GL.$= Nothing
    return r

-- TODO: Could use immutable textures through glTexStorage + glTexSubImage
texImage2DNullPtr :: Int -> Int -> IO ()
texImage2DNullPtr w h =
    GL.texImage2D GL.Texture2D
                  GL.NoProxy
                  0
                  GL.RGBA8
                  (GL.TextureSize2D (fromIntegral w) (fromIntegral h))
                  0
                  (GL.PixelData GL.RGBA GL.UnsignedByte nullPtr)

-- Specify the frame buffer contents by rendering into it
-- http://www.opengl-tutorial.org/intermediate-tutorials/tutorial-14-render-to-texture/
drawIntoFrameBuffer :: (MonadBaseControl IO m, MonadIO m)
                    => FrameBuffer
                    -> (Int -> Int -> m a)
                    -> m (Maybe a)
drawIntoFrameBuffer FrameBuffer { .. } f = do
    oldVP <- liftIO $ GL.get GL.viewport
    control $ \run -> finally
        ( do GL.bindFramebuffer GL.Framebuffer GL.$= fbFBO
             GL.textureBinding  GL.Texture2D   GL.$= Just fbTex
             (w, h) <- readIORef fbDim
             texImage2DNullPtr w h
             setupViewport w h
             -- GL.framebufferStatus is unfortunately broken in OpenGL 2.9.2.0
             -- (see https://github.com/haskell-opengl/OpenGL/issues/51), so
             -- we're using the raw APIs as a backup
             GLR.glCheckFramebufferStatus GLR.gl_FRAMEBUFFER >>= \case
                 r | r == GLR.gl_FRAMEBUFFER_COMPLETE -> run $ Just <$> f w h
                   | otherwise                        -> do
                         traceS TLError $ printf
                             "drawIntoFrameBuffer, glCheckFramebufferStatus: 0x%x"
                             (fromIntegral r :: Int)
                         run $ return Nothing
        )
        ( do GL.bindFramebuffer GL.Framebuffer GL.$= GL.defaultFramebufferObject
             GL.viewport                       GL.$= oldVP
             when (fbDownscaling == HighQualityDownscaling) $ do
                 GL.textureBinding GL.Texture2D GL.$= Just fbTex
                 GLR.glGenerateMipmap GLR.gl_TEXTURE_2D
                 GL.textureBinding GL.Texture2D GL.$= Nothing
        )

-- Draw quad with frame buffer texture
drawFrameBuffer :: FrameBuffer -> QuadRenderBuffer -> Float -> Float -> Float -> Float -> IO ()
drawFrameBuffer FrameBuffer { .. } qb x1 y1 x2 y2 =
    drawQuad qb x1 y1 x2 y2 10 FCWhite TRNone (Just fbTex) QuadUVDefault

fbSizeB :: Integral a => Int -> Int -> a
fbSizeB w h = fromIntegral $ w * h * sizeOf (0 :: Word32)

-- Allocate new frame buffer sized backing storage for the bound PBO
allocPBO :: FrameBuffer -> IO ()
allocPBO FrameBuffer { .. } = do
    (w, h) <- readIORef fbDim
    GL.bufferData GL.PixelUnpackBuffer GL.$= ( fbSizeB w h   -- In bytes
                                             , nullPtr       -- Just allocate
                                             , GL.StreamDraw -- Dynamic
                                             )

saveFrameBufferToPNG :: FrameBuffer -> FilePath -> IO ()
saveFrameBufferToPNG FrameBuffer { .. } fn = do
    GL.textureBinding GL.Texture2D GL.$= Just fbTex
    (w, h) <- getCurTex2DSize
    img    <- VSM.new $ fbSizeB w h :: IO (VSM.IOVector JP.Pixel8)
    VSM.unsafeWith img $ GL.getTexImage GL.Texture2D 0 . GL.PixelData GL.RGBA GL.UnsignedByte
    GL.textureBinding GL.Texture2D GL.$= Nothing
    let flipAndFixA img' =
          JP.generateImage
            ( \x y -> case JP.pixelAt img' x (h - 1 - y) of
                          JP.PixelRGBA8 r g b _ -> JP.PixelRGBA8 r g b 0xFF
            ) w h
     in JP.savePngImage fn . JP.ImageRGBA8 . flipAndFixA . JP.Image w h =<< VS.freeze img
    traceS TLInfo $ "Saved screenshot of framebuffer to " ++ fn

