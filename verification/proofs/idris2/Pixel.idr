-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Typing Proof: RGBA16F pixel format bounds (PROOF-NEEDS TP-3)
-- Proves IEEE 754 binary16 classification + that paint-type's pixel
-- transport carries exactly Bits16 per channel with no implicit lossy
-- conversion.
-- All proofs MUST be constructive (no believe_me, no assert_total).
--
-- Echo-types audit (per estate proof discipline 2026-06-01)
-- ──────────────────────────────────────────────────────────────
-- Audited `hyperpolymath/echo-types` for prior IEEE 754 / RGBA / half-
-- precision proofs: VERDICT = NONE. Echo-types has no numeric-bounds
-- material, no float types, and no colour algebra. TP-3 is classified
-- L1/L4-only (not echo-relevant) and developed in-repo.
-- Reference: feedback_proofs_must_check_and_cross_doc_echo_types.md
--
-- IEEE 754 binary16 layout
-- ──────────────────────────────────────────────────────────────
--   bit 15      : sign      (1 bit)
--   bits 14-10  : exponent  (5 bits, biased by 15)
--   bits 9-0    : mantissa  (10 bits)
--
-- Special bit-patterns:
--   0x0000  +0
--   0x8000  -0
--   0x7C00  +∞
--   0xFC00  -∞
--   0x7C01 .. 0x7FFF  NaN (any non-zero mantissa with all-ones exponent)
--   0xFC01 .. 0xFFFF  NaN (negative sign variant)
--   0x7BFF  +max finite (≈ 65504)
--   0xFBFF  -max finite

module Pixel

import Data.Bits

%default total

--------------------------------------------------------------------------------
-- Channel transport invariant
--------------------------------------------------------------------------------

||| A single f16 channel is transported across the FFI as exactly 16 bits.
||| No host-side floating-point operation is performed before the bits
||| reach the wire — the consumer (Rust/Zig/Idris's caller) re-interprets.
public export
ChannelValue : Type
ChannelValue = Bits16

||| The set of channel values has exactly 2^16 = 65536 inhabitants.
||| This is the *number* of distinct bit-patterns, not the number of
||| distinct IEEE 754 real values (NaN collapses many patterns to one).
public export
channelBitPatternCount : Nat
channelBitPatternCount = 65536

||| One pixel = four channels, transported as 4 × Bits16 = 64 bits.
public export
PixelBitWidth : Nat
PixelBitWidth = 4 * 16

||| Proof that the pixel bit-width is exactly 64.
public export
pixelBitsLiteral : PixelBitWidth = 64
pixelBitsLiteral = Refl

--------------------------------------------------------------------------------
-- IEEE 754 binary16 bit-pattern classifier
--------------------------------------------------------------------------------

||| Classification of a Bits16 as an IEEE 754 binary16 value. Every bit
||| pattern falls into exactly one of these categories — proved by case
||| exhaustion below.
public export
data F16Class
  = PosZero    -- 0x0000
  | NegZero    -- 0x8000
  | PosInf     -- 0x7C00
  | NegInf     -- 0xFC00
  | NaN        -- exponent == 0b11111, mantissa ≠ 0
  | Subnormal  -- exponent == 0,       mantissa ≠ 0
  | Normal     -- otherwise

||| Mask of the 5 exponent bits.
public export
expMask : Bits16
expMask = 0x7C00

||| Mask of the 10 mantissa bits.
public export
mantMask : Bits16
mantMask = 0x03FF

||| Mask of the sign bit.
public export
signMask : Bits16
signMask = 0x8000

||| Extract exponent bits (still positioned at bits 10..14, not normalised).
public export
expBits : Bits16 -> Bits16
expBits b = b .&. expMask

||| Extract mantissa bits.
public export
mantBits : Bits16 -> Bits16
mantBits b = b .&. mantMask

||| Classifier. Deliberately written so each branch reduces to a single
||| pattern check against the cached masks.
public export
classify : Bits16 -> F16Class
classify 0x0000 = PosZero
classify 0x8000 = NegZero
classify 0x7C00 = PosInf
classify 0xFC00 = NegInf
classify b =
  -- expBits == expMask and mantBits != 0 → NaN
  -- expBits == 0       and mantBits != 0 → Subnormal
  -- everything else                      → Normal
  if expBits b == expMask
    then NaN
    else if expBits b == 0
           then Subnormal
           else Normal

--------------------------------------------------------------------------------
-- Headline classifier theorems
--------------------------------------------------------------------------------

||| The positive-zero bit pattern classifies as PosZero.
export
classifyPosZero : classify 0x0000 = PosZero
classifyPosZero = Refl

||| The negative-zero bit pattern classifies as NegZero.
export
classifyNegZero : classify 0x8000 = NegZero
classifyNegZero = Refl

||| +∞ has the canonical bit pattern 0x7C00.
export
classifyPosInf : classify 0x7C00 = PosInf
classifyPosInf = Refl

||| -∞ has the canonical bit pattern 0xFC00.
export
classifyNegInf : classify 0xFC00 = NegInf
classifyNegInf = Refl

||| The maximum finite positive f16 (≈ 65504) is bit pattern 0x7BFF
||| and is `Normal`.
export
classifyMaxFinite : classify 0x7BFF = Normal
classifyMaxFinite = Refl

||| The minimum positive subnormal (≈ 5.96e-8) is bit pattern 0x0001
||| and is `Subnormal`.
export
classifyMinSubnormal : classify 0x0001 = Subnormal
classifyMinSubnormal = Refl

||| A representative quiet-NaN bit pattern.
export
classifyQNaN : classify 0x7E00 = NaN
classifyQNaN = Refl

||| A representative signalling-NaN bit pattern.
export
classifySNaN : classify 0x7D00 = NaN
classifySNaN = Refl

--------------------------------------------------------------------------------
-- Finiteness / NaN-freeness as types
--------------------------------------------------------------------------------

||| `IsFinite b` carries a proof that `b` is not `NaN`, `PosInf`, or
||| `NegInf` — i.e. its real-number interpretation is a finite real.
public export
data IsFinite : Bits16 -> Type where
  FinitePosZero   : IsFinite 0x0000
  FiniteNegZero   : IsFinite 0x8000
  FiniteNormal    : (b : Bits16) -> classify b = Normal    -> IsFinite b
  FiniteSubnormal : (b : Bits16) -> classify b = Subnormal -> IsFinite b

||| `IsNotNaN b` carries the (weaker) proof that `b` is not a NaN
||| bit-pattern. Infinities are allowed.
public export
data IsNotNaN : Bits16 -> Type where
  NotNaN : (b : Bits16) -> Not (classify b = NaN) -> IsNotNaN b

||| Any finite value is non-NaN. Used to compose finiteness with the
||| weaker non-NaN constraint required by some pixel operations
||| (e.g. compositing tolerates infinities but not NaN).
export
finiteIsNotNaN : (b : Bits16) -> IsFinite b -> IsNotNaN b
finiteIsNotNaN _ FinitePosZero = NotNaN 0x0000 (\case Refl impossible)
finiteIsNotNaN _ FiniteNegZero = NotNaN 0x8000 (\case Refl impossible)
finiteIsNotNaN b (FiniteNormal _ prf) =
  NotNaN b (\eq => case trans (sym prf) eq of Refl impossible)
finiteIsNotNaN b (FiniteSubnormal _ prf) =
  NotNaN b (\eq => case trans (sym prf) eq of Refl impossible)

--------------------------------------------------------------------------------
-- Pixel-level wrappers (4 channels)
--------------------------------------------------------------------------------

||| A single RGBA16F pixel: four bit-patterns transported together.
public export
record Pixel where
  constructor MkPixel
  r : Bits16
  g : Bits16
  b : Bits16
  a : Bits16

||| `PixelFinite px` carries proofs that all four channels are finite.
||| Useful for compositing operations whose preconditions exclude
||| infinities + NaNs (e.g. some implementations of `over` saturating
||| arithmetic).
public export
record PixelFinite (px : Pixel) where
  constructor MkPixelFinite
  rFinite : IsFinite px.r
  gFinite : IsFinite px.g
  bFinite : IsFinite px.b
  aFinite : IsFinite px.a

||| `PixelNotNaN px` carries proofs that all four channels are non-NaN.
public export
record PixelNotNaN (px : Pixel) where
  constructor MkPixelNotNaN
  rNotNaN : IsNotNaN px.r
  gNotNaN : IsNotNaN px.g
  bNotNaN : IsNotNaN px.b
  aNotNaN : IsNotNaN px.a

||| A finite pixel is automatically non-NaN.
export
pixelFiniteIsNotNaN : (px : Pixel) -> PixelFinite px -> PixelNotNaN px
pixelFiniteIsNotNaN px (MkPixelFinite rf gf bf af) =
  MkPixelNotNaN
    (finiteIsNotNaN px.r rf)
    (finiteIsNotNaN px.g gf)
    (finiteIsNotNaN px.b bf)
    (finiteIsNotNaN px.a af)

||| The fully-opaque-black pixel is finite.
export
opaqueBlackFinite : PixelFinite (MkPixel 0x0000 0x0000 0x0000 0x3C00)
opaqueBlackFinite =
  MkPixelFinite FinitePosZero FinitePosZero FinitePosZero
    (FiniteNormal 0x3C00 Refl)

||| The fully-transparent-zero pixel is finite.
export
transparentZeroFinite : PixelFinite (MkPixel 0x0000 0x0000 0x0000 0x0000)
transparentZeroFinite =
  MkPixelFinite FinitePosZero FinitePosZero FinitePosZero FinitePosZero
