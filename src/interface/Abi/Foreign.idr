-- SPDX-License-Identifier: PMPL-1.0-or-later
||| Foreign Function Interface Bridge for libpt
|||
||| Raw FFI primitives and total safe wrappers for the paint.type tile
||| primitive. The C library is `libpt`; symbols are prefixed `pt_`.
||| Each safe wrapper validates its inputs (notably non-null pointers)
||| and translates raw C return codes into the algebraic `Result` type
||| from `Abi.Types`.

module Abi.Foreign

import Abi.Types
import Abi.Layout

%default total

--------------------------------------------------------------------------------
-- Raw FFI Primitives
--------------------------------------------------------------------------------

||| Allocate a 64x64 RGBA16F tile at grid position (x, y).
||| Returns a non-null pointer on success, 0 on out-of-memory.
%foreign "C:pt_tile_alloc,libpt"
prim__tileAlloc : Bits32 -> Bits32 -> PrimIO Bits64

||| Free a tile previously returned by `pt_tile_alloc`.
||| Calling with 0 is a documented no-op.
%foreign "C:pt_tile_free,libpt"
prim__tileFree : Bits64 -> PrimIO ()

||| Fill every pixel of the tile with one RGBA16F colour.
||| The four channel arguments are the bit patterns of f16 values.
||| Returns 0 on success, non-zero on error (per `Result` encoding).
%foreign "C:pt_tile_fill,libpt"
prim__tileFill : Bits64 -> Bits16 -> Bits16 -> Bits16 -> Bits16 -> PrimIO Bits32

||| Read one pixel from inside a tile. The four out-pointers are u64
||| addresses of u16 destinations into which f16 bit patterns are written.
||| Returns 0 on success, non-zero if any pointer is null or the pixel
||| coordinates are out of bounds.
%foreign "C:pt_tile_read_pixel,libpt"
prim__tileReadPixel : Bits64 -> Bits32 -> Bits32 ->
                      Bits64 -> Bits64 -> Bits64 -> Bits64 ->
                      PrimIO Bits32

||| Write a single u16 to a host address. Used by the readPixel wrapper
||| to materialise the four out-parameters of pt_tile_read_pixel.
%foreign "C:pt_alloc_u16_slot,libpt"
prim__allocU16Slot : PrimIO Bits64

%foreign "C:pt_read_u16_slot,libpt"
prim__readU16Slot : Bits64 -> PrimIO Bits16

%foreign "C:pt_free_u16_slot,libpt"
prim__freeU16Slot : Bits64 -> PrimIO ()

--------------------------------------------------------------------------------
-- Safe Wrappers: Tile Lifecycle
--------------------------------------------------------------------------------

||| Allocate a 64x64 RGBA16F tile at the given grid position.
||| Returns Nothing on out-of-memory.
export
allocTile : Bits32 -> Bits32 -> IO (Maybe TileHandle)
allocTile x y = do
  ptr <- primIO (prim__tileAlloc x y)
  pure (createTileHandle ptr)

||| Free a tile. The caller must not use the handle afterwards;
||| this is a linear-ownership API.
export
freeTile : TileHandle -> IO ()
freeTile h = primIO (prim__tileFree h.ptr)

--------------------------------------------------------------------------------
-- Safe Wrappers: Tile Operations
--------------------------------------------------------------------------------

||| Fill every pixel of a tile with one colour.
||| Channels are the bit patterns of f16 values, in (r, g, b, a) order.
export
fillTile : TileHandle -> (Bits16, Bits16, Bits16, Bits16) -> IO Result
fillTile h (r, g, b, a) = do
  code <- primIO (prim__tileFill h.ptr r g b a)
  pure (resultFromCode code)

||| Read a single pixel from a tile at (px, py) within its 64x64 grid.
||| Returns Nothing if the pixel is out of bounds or the FFI call
||| reports any other error.
|||
||| Implementation detail: pt_tile_read_pixel writes its outputs through
||| u64 host addresses, so we allocate four small slots, pass their
||| addresses, then read them back. The slot allocator is provided by
||| libpt to avoid pulling host-allocator concerns into Idris2.
export
readPixel : TileHandle -> (Bits32, Bits32) -> IO (Maybe (Bits16, Bits16, Bits16, Bits16))
readPixel h (px, py) = do
  rSlot <- primIO prim__allocU16Slot
  gSlot <- primIO prim__allocU16Slot
  bSlot <- primIO prim__allocU16Slot
  aSlot <- primIO prim__allocU16Slot
  if rSlot == 0 || gSlot == 0 || bSlot == 0 || aSlot == 0
    then do
      primIO (prim__freeU16Slot rSlot)
      primIO (prim__freeU16Slot gSlot)
      primIO (prim__freeU16Slot bSlot)
      primIO (prim__freeU16Slot aSlot)
      pure Nothing
    else do
      code <- primIO (prim__tileReadPixel h.ptr px py rSlot gSlot bSlot aSlot)
      r <- primIO (prim__readU16Slot rSlot)
      g <- primIO (prim__readU16Slot gSlot)
      b <- primIO (prim__readU16Slot bSlot)
      a <- primIO (prim__readU16Slot aSlot)
      primIO (prim__freeU16Slot rSlot)
      primIO (prim__freeU16Slot gSlot)
      primIO (prim__freeU16Slot bSlot)
      primIO (prim__freeU16Slot aSlot)
      case resultFromCode code of
        Ok => pure (Just (r, g, b, a))
        _  => pure Nothing

--------------------------------------------------------------------------------
-- Error Descriptions
--------------------------------------------------------------------------------

||| Human-readable description of a Result code.
export
errorDescription : Result -> String
errorDescription Ok = "Success"
errorDescription Error = "Generic error"
errorDescription InvalidParam = "Invalid parameter"
errorDescription Busy = "Library is busy"
