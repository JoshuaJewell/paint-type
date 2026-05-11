-- SPDX-License-Identifier: PMPL-1.0-or-later
||| paint.type ABI Layout Verification
|||
||| This module provides formal proofs about memory layout, alignment,
||| and padding for the C-compatible structs that cross the Idris2/Zig/Rust
||| boundary. The headline result is `tileLayoutValid`, which proves the
||| `PtTile` header struct laid out by the Zig FFI is C-ABI compliant.

module Abi.Layout

import Abi.Types
import Data.Vect
import Data.So

%default total

--------------------------------------------------------------------------------
-- Alignment Invariants
--------------------------------------------------------------------------------

||| Predicate: n divides m, witnessed by the quotient k.
public export
data Divides : (n, m : Nat) -> Type where
  MkDivides : (k : Nat) -> (0 prf : m = k * n) -> Divides n m

||| Common divisibility witnesses used by the example struct.
public export
div8_24 : Divides 8 24
div8_24 = MkDivides 3 Refl

public export
div4_0 : Divides 4 0
div4_0 = MkDivides 0 Refl

public export
div8_8 : Divides 8 8
div8_8 = MkDivides 1 Refl

public export
div8_16 : Divides 8 16
div8_16 = MkDivides 2 Refl

||| Witnesses needed for the tile layout.
public export
div4_4 : Divides 4 4
div4_4 = MkDivides 1 Refl

public export
div4_8 : Divides 4 8
div4_8 = MkDivides 2 Refl

public export
div4_12 : Divides 4 12
div4_12 = MkDivides 3 Refl

public export
div4_16 : Divides 4 16
div4_16 = MkDivides 4 Refl

--------------------------------------------------------------------------------
-- Padding and Alignment Helpers
--------------------------------------------------------------------------------

||| Calculate padding required for an offset to meet alignment.
public export
paddingFor : (offset : Nat) -> (alignment : Nat) -> Nat
paddingFor offset 0 = 0
paddingFor offset alignment =
  let m = offset `mod` alignment in
  if m == 0 then 0 else alignment `minus` m

||| Align a size up to the next multiple of alignment.
public export
alignUp : (size : Nat) -> (alignment : Nat) -> Nat
alignUp size alignment = size + paddingFor size alignment

--------------------------------------------------------------------------------
-- Struct Model
--------------------------------------------------------------------------------

||| Representation of a single field in a struct.
public export
record Field where
  constructor MkField
  name : String
  offset : Nat
  size : Nat
  alignment : Nat

||| Memory layout for a C struct. The `aligned` invariant ensures the
||| struct's total size is a multiple of its alignment, so arrays of
||| this struct remain aligned without external padding.
public export
record StructLayout where
  constructor MkStructLayout
  {n : Nat}
  fields : Vect n Field
  totalSize : Nat
  alignment : Nat
  {auto 0 aligned : Divides alignment totalSize}

--------------------------------------------------------------------------------
-- Compliance Predicates
--------------------------------------------------------------------------------

||| Proof that all fields in a struct are correctly aligned.
public export
data FieldsAligned : Vect n Field -> Type where
  NoFields : FieldsAligned []
  ConsField :
    (f : Field) ->
    (rest : Vect n Field) ->
    (0 prf : Divides f.alignment f.offset) ->
    FieldsAligned rest ->
    FieldsAligned (f :: rest)

||| Predicate: Struct is C-ABI compliant.
public export
data CABICompliant : StructLayout -> Type where
  CABIOk : (l : StructLayout) ->
           (0 prf : FieldsAligned l.fields) ->
           CABICompliant l

--------------------------------------------------------------------------------
-- Generic Example (kept from template for sanity)
--------------------------------------------------------------------------------

||| Example: struct { int32_t x; int64_t y; double z; }
||| On 64-bit Linux, this should have size 24, alignment 8.
public export
exampleLayout : StructLayout
exampleLayout =
  MkStructLayout
    [ MkField "x" 0 4 4
    , MkField "y" 8 8 8
    , MkField "z" 16 8 8
    ]
    24 8 {aligned = div8_24}

||| Proof that the example layout is valid.
public export
exampleLayoutValid : CABICompliant Abi.Layout.exampleLayout
exampleLayoutValid = CABIOk Abi.Layout.exampleLayout (
  ConsField (MkField "x" 0 4 4) _ div4_0 (
  ConsField (MkField "y" 8 8 8) _ div8_8 (
  ConsField (MkField "z" 16 8 8) _ div8_16 (
  NoFields))))

--------------------------------------------------------------------------------
-- Tile Buffer Size Proof
--------------------------------------------------------------------------------

||| The tile pixel buffer is exactly 32768 bytes for the only currently
||| supported format (RGBA16F):
|||   TileSize x TileSize x channelCount RGBA16F x 2 bytes/channel
||| = 64 x 64 x 4 x 2 = 32768.
public export
tileBufferSize : 64 * 64 * 4 * 2 = 32768
tileBufferSize = Refl

--------------------------------------------------------------------------------
-- Tile Header Layout
--------------------------------------------------------------------------------

||| Layout of the `PtTile` header allocated by the Zig FFI:
|||
|||   struct PtTile {
|||     uint32_t x;       // offset 0,  size 4, align 4
|||     uint32_t y;       // offset 4,  size 4, align 4
|||     uint32_t width;   // offset 8,  size 4, align 4 (always 64)
|||     uint32_t height;  // offset 12, size 4, align 4 (always 64)
|||     // pixels follow immediately, 32768 bytes
|||   }
|||
||| Only the 16-byte header is described here; the trailing pixel buffer
||| is a flat byte array whose size is captured by `tileBufferSize`.
public export
tileLayout : StructLayout
tileLayout =
  MkStructLayout
    [ MkField "x"      0  4 4
    , MkField "y"      4  4 4
    , MkField "width"  8  4 4
    , MkField "height" 12 4 4
    ]
    16 4 {aligned = div4_16}

||| Proof that the tile header is C-ABI compliant: every field's offset
||| is a multiple of its alignment, and the total size is a multiple of
||| the struct alignment.
public export
tileLayoutValid : CABICompliant Abi.Layout.tileLayout
tileLayoutValid = CABIOk Abi.Layout.tileLayout (
  ConsField (MkField "x"      0  4 4) _ div4_0 (
  ConsField (MkField "y"      4  4 4) _ div4_4 (
  ConsField (MkField "width"  8  4 4) _ div4_8 (
  ConsField (MkField "height" 12 4 4) _ div4_12 (
  NoFields)))))
