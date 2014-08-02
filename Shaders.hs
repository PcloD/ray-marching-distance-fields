
{-# LANGUAGE OverloadedStrings #-}

module Shaders ( vsSrcBasic
               , fsSrcBasic
               , fsColOnlySrcBasic
               , mkShaderProgam
               , setAttribArray
               , setTextureShader
               , setOrtho2DProjMatrix
               ) where

import qualified Graphics.Rendering.OpenGL as GL
import qualified Graphics.Rendering.OpenGL.Raw as GLR
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as B
import Data.Either
import Control.Exception
import Control.Monad
import Control.Monad.Except
import Foreign.Ptr
import Foreign.Storable
import Foreign.Marshal.Array

import GLHelpers

-- GLSL shaders and support functions

mkShaderProgam :: B.ByteString -> B.ByteString -> IO (Either String GL.Program)
mkShaderProgam vsSrc fsSrc =
    -- Always delete the shaders (don't need them after linking), only delete the program
    -- on error
    bracket        (GL.createShader GL.VertexShader  ) (GL.deleteObjectName) $ \shdVtx  ->
    bracket        (GL.createShader GL.FragmentShader) (GL.deleteObjectName) $ \shdFrag ->
    bracketOnError (GL.createProgram                 ) (GL.deleteObjectName) $ \shdProg -> do
        r <- runExceptT $ do
                 compile shdVtx  vsSrc
                 compile shdFrag fsSrc
                 liftIO $ GL.attachShader shdProg shdVtx >> GL.attachShader shdProg shdFrag
                 link shdProg
                 liftIO $ GL.detachShader shdProg shdVtx >> GL.detachShader shdProg shdFrag
                 return shdProg
        -- The bracket only deletes in case of an exception, still need to delete manually
        -- in case of a monadic error
        when (null $ rights [r]) $ GL.deleteObjectName shdProg
        traceOnGLError $ Just "mkShaderProgam end"
        return r
    -- Compile and link helpers
    where compile shd src = do
              liftIO $ do GL.shaderSourceBS shd GL.$= src
                          GL.compileShader  shd
              success <- liftIO $ GL.get $ GL.compileStatus shd
              unless success $ do
                  errLog <- liftIO $ GL.get $ GL.shaderInfoLog shd
                  throwError errLog
          link prog = do
              liftIO $ GL.linkProgram prog
              success <- liftIO $ GL.get $ GL.linkStatus prog
              unless success $ do
                  errLog <- liftIO $ GL.get $ GL.programInfoLog prog
                  throwError errLog

setAttribArray :: GL.GLuint
               -> Int
               -> Int
               -> Int
               -> IO GL.AttribLocation
setAttribArray idx attribStride vertexStride offset = do
    -- Specify and enable vertex attribute array
    let attrib = GL.AttribLocation idx
        szf    = sizeOf (0 :: Float)
    GL.vertexAttribPointer attrib GL.$=
        ( GL.ToFloat
        , GL.VertexArrayDescriptor
              (fromIntegral attribStride)
              GL.Float
              (fromIntegral $ vertexStride * szf)
              (nullPtr `plusPtr` (offset * szf))
        )
    GL.vertexAttribArray attrib GL.$= GL.Enabled
    return attrib

setTextureShader :: GL.TextureObject -> Int -> GL.Program -> String -> IO ()
setTextureShader tex tu prog uname = do
    (GL.get $ GL.uniformLocation prog uname) >>= \loc ->
        GL.uniform loc             GL.$= GL.Index1 (fromIntegral tu :: GL.GLint)
    GL.activeTexture               GL.$= GL.TextureUnit (fromIntegral tu)
    GL.textureBinding GL.Texture2D GL.$= Just tex

setOrtho2DProjMatrix :: GL.Program -> String -> Int -> Int -> IO ()
setOrtho2DProjMatrix prog uniform w h = do
    GL.UniformLocation loc <- GL.get $ GL.uniformLocation prog uniform
    let ortho2D = [ 2 / fromIntegral w, 0, 0, -1,
                    0, 2 / fromIntegral h, 0, -1,
                    0, 0, (-2) / 1000, -1, 
                    0, 0, 0, 1
                  ] :: [GL.GLfloat]
    withArray ortho2D $ \ptr -> GLR.glUniformMatrix4fv loc 1 1 ptr

-- Shader source for basic vertex and fragment shaders
vsSrcBasic, fsSrcBasic, fsColOnlySrcBasic :: B.ByteString
vsSrcBasic = TE.encodeUtf8 $ T.unlines
    [ "#version 330 core"
    , "uniform mat4 in_mvp;"
    , "layout(location = 0) in vec3 in_pos;"
    , "layout(location = 1) in vec4 in_col;"
    , "layout(location = 2) in vec2 in_uv;"
    , "out vec4 fs_col;"
    , "out vec2 fs_uv;"
    , "void main()"
    , "{"
    --, "    gl_Position = vec4((in_pos.x / 512.0) * 2.0 - 1.0, (in_pos.y / 512.0) * 2.0 - 1.0, 0, 1);"
    , "    gl_Position = in_mvp * vec4(in_pos, 1.0);"
    --, "    gl_Position.z = 0;"
    --, "    gl_Position.w = 1;"
    , "    fs_col      = in_col;"
    , "    fs_uv       = in_uv;"
    , "}"
    ]
fsSrcBasic = TE.encodeUtf8 $ T.unlines
    [ "#version 150 core"
    , "in vec4 fs_col;"
    , "in vec2 fs_uv;"
    , "uniform sampler2D tex;"
    , "out vec4 frag_color;"
    , "void main()"
    , "{"
    , "   frag_color = fs_col * texture(tex, fs_uv);"
    , "}"
    ]
fsColOnlySrcBasic = TE.encodeUtf8 $ T.unlines
    [ "#version 150 core"
    , "in vec4 fs_col;"
    , "out vec4 frag_color;"
    , "void main()"
    , "{"
    , "   frag_color = fs_col;"
    , "}"
    ]
