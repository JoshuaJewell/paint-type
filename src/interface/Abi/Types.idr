-- SPDX-License-Identifier: PMPL-1.0-or-later
||| paint.type ABI Type Definitions
|||
||| This module defines the Application Binary Interface (ABI) for libpt,
||| the paint.type native image core. All type definitions include formal
||| proofs of correctness where the property is non-trivial.
|||
||| The operation surface this file types is the tile primitive: a
||| 64x64 RGBA16F (linear-light) buffer that is the unit of allocation,
||| processing, and ownership in paint.type.

module Abi.Types

import Data.Bits
import Data.So
import Data.Vect
import Decidable.Equality

%default total

--------------------------------------------------------------------------------
-- Platform Model
--------------------------------------------------------------------------------

||| Target platforms for the FFI bridge.
public export
data Platform = Linux | MacOS | Windows | WASM | RISCV

||| Pointer size in bits per platform.
public export
ptrSize : Platform -> Nat
ptrSize Linux = 64
ptrSize MacOS = 64
ptrSize Windows = 64
ptrSize WASM = 32
ptrSize RISCV = 64

||| Current target platform.
||| TODO upstream: detect from %cg / target triple at compile time.
public export
thisPlatform : Platform
thisPlatform = Linux

--------------------------------------------------------------------------------
-- Core Result Type
--------------------------------------------------------------------------------

||| Return codes for FFI calls. Mirrors the Zig `Result` enum in
||| `src/interface/ffi/src/main.zig`. Numeric encoding (when crossing the
||| C boundary as u32): Ok = 0, Error = 1, InvalidParam = 2, Busy = 3.
public export
data Result = Ok | Error | InvalidParam | Busy

||| Results are decidably equal.
public export
implementation DecEq Result where
  decEq Ok Ok = Yes Refl
  decEq Error Error = Yes Refl
  decEq InvalidParam InvalidParam = Yes Refl
  decEq Busy Busy = Yes Refl
  decEq Ok Error = No (\case Refl impossible)
  decEq Ok InvalidParam = No (\case Refl impossible)
  decEq Ok Busy = No (\case Refl impossible)
  decEq Error Ok = No (\case Refl impossible)
  decEq Error InvalidParam = No (\case Refl impossible)
  decEq Error Busy = No (\case Refl impossible)
  decEq InvalidParam Ok = No (\case Refl impossible)
  decEq InvalidParam Error = No (\case Refl impossible)
  decEq InvalidParam Busy = No (\case Refl impossible)
  decEq Busy Ok = No (\case Refl impossible)
  decEq Busy Error = No (\case Refl impossible)
  decEq Busy InvalidParam = No (\case Refl impossible)

||| Decode a Bits32 returned across the FFI boundary into a Result.
||| Any unknown code is mapped to `Error` rather than crashing.
public export
resultFromCode : Bits32 -> Result
resultFromCode 0 = Ok
resultFromCode 2 = InvalidParam
resultFromCode 3 = Busy
resultFromCode _ = Error

--------------------------------------------------------------------------------
-- Generic Library Handle
--------------------------------------------------------------------------------

||| Opaque handle for library resources.
||| Invariant: Handle pointer must be non-null.
public export
record Handle where
  constructor MkHandle
  ptr : Bits64
  0 prf : So (ptr /= 0)

||| Smart constructor: returns Nothing if pointer is null.
public export
createHandle : Bits64 -> Maybe Handle
createHandle 0 = Nothing
createHandle ptr = case decSo (ptr /= 0) of
  Yes p => Just (MkHandle ptr p)
  No _ => Nothing

--------------------------------------------------------------------------------
-- C-Types Mapping
--------------------------------------------------------------------------------

||| Tagged types for the C FFI boundary.
public export
data CType = CInt | CUInt | CLong | CULong | CPtrType

||| Pointer type for a platform. paint.type only targets 64-bit hosts in
||| the native build; WASM is handled by a separate adapter.
public export
CPtr : Platform -> CType -> Type
CPtr p _ = Bits64

||| Size of C types in bytes (platform-specific).
public export
cSizeOf : (p : Platform) -> (t : CType) -> Nat
cSizeOf p CInt = 4
cSizeOf p CUInt = 4
cSizeOf p CLong = 8
cSizeOf p CULong = 8
cSizeOf p CPtrType = 8

||| Alignment of C types in bytes (platform-specific).
public export
cAlignOf : (p : Platform) -> (t : CType) -> Nat
cAlignOf p CInt = 4
cAlignOf p CUInt = 4
cAlignOf p CLong = 8
cAlignOf p CULong = 8
cAlignOf p CPtrType = 8

--------------------------------------------------------------------------------
-- Pixel Format
--------------------------------------------------------------------------------

||| Supported pixel formats. paint.type currently supports exactly one
||| format end-to-end: RGBA16F (linear light, IEEE 754 binary16 per channel,
||| not gamma-encoded).
public export
data PixelFormat = RGBA16F

||| Channel count per pixel for a given format.
public export
channelCount : PixelFormat -> Nat
channelCount RGBA16F = 4

||| Byte width per pixel for a given format.
||| For RGBA16F: 4 channels x 2 bytes = 8 bytes.
public export
bytesPerPixel : PixelFormat -> Nat
bytesPerPixel RGBA16F = 8

||| Proof that RGBA16F has exactly 4 channels.
public export
rgba16fChannels : channelCount RGBA16F = 4
rgba16fChannels = Refl

||| Proof that RGBA16F is exactly 8 bytes per pixel.
public export
rgba16fBytesPerPixel : bytesPerPixel RGBA16F = 8
rgba16fBytesPerPixel = Refl

--------------------------------------------------------------------------------
-- Tile Geometry
--------------------------------------------------------------------------------

||| Compile-time edge length of a tile, in pixels. Paint.type uses a single
||| fixed tile size to make hot-loop bookkeeping branch-free.
public export
TileSize : Nat
TileSize = 64

||| Total pixel count in a tile (TileSize * TileSize).
public export
tilePixelCount : Nat
tilePixelCount = TileSize * TileSize

||| Total byte count in a tile's pixel buffer for a given format.
public export
tileByteCount : PixelFormat -> Nat
tileByteCount fmt = tilePixelCount * bytesPerPixel fmt

||| Proof that the RGBA16F tile buffer is exactly 32768 bytes.
||| 64 * 64 * 4 channels * 2 bytes = 32768.
public export
tileBufferSizeRGBA16F : tileByteCount RGBA16F = 32768
tileBufferSizeRGBA16F = Refl

||| Re-statement of the key invariant in the requested form:
||| TileSize * TileSize * 8 = 32768.
public export
tileSizeProof : TileSize * TileSize * 8 = 32768
tileSizeProof = Refl

--------------------------------------------------------------------------------
-- Tile Coordinates
--------------------------------------------------------------------------------

||| Position of a tile in the canvas grid. Coordinates are in tile-units,
||| not pixel-units (i.e. tile (1,0) starts at pixel (64,0)).
public export
record TileCoord where
  constructor MkTileCoord
  x : Bits32
  y : Bits32

--------------------------------------------------------------------------------
-- Tile Handle
--------------------------------------------------------------------------------

||| Opaque handle to an allocated tile buffer. Semantically distinct from
||| `Handle`: a TileHandle owns a 32-byte-aligned, header-prefixed pixel
||| buffer of size `tileByteCount RGBA16F`. Linear ownership: every
||| TileHandle returned by `allocTile` must be passed to exactly one
||| `freeTile`.
public export
record TileHandle where
  constructor MkTileHandle
  ptr : Bits64
  0 prf : So (ptr /= 0)

||| Smart constructor for TileHandle, refusing null pointers.
public export
createTileHandle : Bits64 -> Maybe TileHandle
createTileHandle 0 = Nothing
createTileHandle ptr = case decSo (ptr /= 0) of
  Yes p => Just (MkTileHandle ptr p)
  No _ => Nothing

--------------------------------------------------------------------------------
-- Channel Values
--------------------------------------------------------------------------------

||| Bit pattern of a single IEEE 754 binary16 (f16) channel value.
||| Idris2's FFI does not have a native f16 type, so we transport the
||| bit pattern as a Bits16 across the boundary. Both sides agree to
||| reinterpret the bits as f16 at the consumer's discretion.
public export
ChannelValue : Type
ChannelValue = Bits16
