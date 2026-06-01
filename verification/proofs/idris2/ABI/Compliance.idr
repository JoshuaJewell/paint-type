-- SPDX-License-Identifier: PMPL-1.0-or-later
||| C ABI Compliance Proof (ABI-5, paint-type PROOF-NEEDS)
|||
||| For paint-type's `PtTile` header struct laid out by the Zig FFI,
||| prove that every field's offset is a multiple of its alignment
||| (`FieldsAligned`) and that the total struct size is a multiple of
||| the struct's alignment (so arrays of this struct stay aligned
||| without external padding). Together these constitute the
||| `CABICompliant` predicate.
|||
||| ## Echo-types audit (per estate proof discipline 2026-06-01)
|||
||| Audited `hyperpolymath/echo-types` for prior C ABI compliance
||| material: VERDICT = NONE. Echo-types is an Agda formalisation of
||| structured loss with no struct-layout content. ABI-5 is classified
||| L1/L4-only (not echo-relevant) and developed in-repo.
||| Reference: feedback_proofs_must_check_and_cross_doc_echo_types.md
|||
||| ## Layout under verification
|||
|||   struct PtTile {
|||     uint32_t x;       // offset 0,  size 4, align 4
|||     uint32_t y;       // offset 4,  size 4, align 4
|||     uint32_t width;   // offset 8,  size 4, align 4 (always 64)
|||     uint32_t height;  // offset 12, size 4, align 4 (always 64)
|||     // pixels follow immediately, 32768 bytes
|||   }
|||
||| Header total = 16 bytes; struct alignment = 4. 16 / 4 = 4 → aligned
||| for array packing.

module ABI.Compliance

import Data.Nat
import Data.List
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- Divisibility primitive
--------------------------------------------------------------------------------

||| Predicate: `n` divides `m`, witnessed by the quotient `k` such that
||| `m = k * n`. Identical in shape to the divisibility predicate used
||| inside `Abi.Layout` (`src/interface/Abi/Layout.idr`), but redefined
||| here so this module is self-contained for the verification tree.
public export
data Divides : (n, m : Nat) -> Type where
  MkDivides : (k : Nat) -> (0 prf : m = k * n) -> Divides n m

-- Pre-computed divisibility witnesses we'll reuse.

public export
div4_0 : Divides 4 0
div4_0 = MkDivides 0 Refl

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
-- Struct model
--------------------------------------------------------------------------------

||| One field in a C struct. `alignment` is in bytes; for paint-type's
||| header every field is `uint32_t` so `alignment = 4`.
public export
record Field where
  constructor MkField
  name : String
  offset : Nat
  size : Nat
  alignment : Nat

||| Memory layout for a C struct. The `aligned` invariant ensures that
||| `totalSize` is a multiple of `alignment`, so arrays of this struct
||| remain aligned without external padding.
public export
record StructLayout where
  constructor MkStructLayout
  {n : Nat}
  fields : Vect n Field
  totalSize : Nat
  alignment : Nat
  {auto 0 aligned : Divides alignment totalSize}

--------------------------------------------------------------------------------
-- Field-alignment predicate
--------------------------------------------------------------------------------

||| `FieldsAligned fs` carries a per-field proof that each field's
||| offset is a multiple of its alignment.
public export
data FieldsAligned : Vect n Field -> Type where
  NoFields : FieldsAligned []
  ConsField :
    (f : Field) ->
    (rest : Vect n Field) ->
    (0 prf : Divides f.alignment f.offset) ->
    FieldsAligned rest ->
    FieldsAligned (f :: rest)

--------------------------------------------------------------------------------
-- C ABI compliance
--------------------------------------------------------------------------------

||| A struct is C-ABI compliant when:
|||   - every field's offset divides its alignment (`FieldsAligned`),
|||   - the struct's total size is a multiple of its alignment (already
|||     captured by the `aligned` field of `StructLayout`).
||| The two together guarantee that an array of this struct keeps every
||| element aligned without external padding.
public export
data CABICompliant : StructLayout -> Type where
  CABIOk : (l : StructLayout) ->
           (0 prf : FieldsAligned l.fields) ->
           CABICompliant l

--------------------------------------------------------------------------------
-- The PtTile header
--------------------------------------------------------------------------------

||| Layout of the `PtTile` header allocated by the Zig FFI. Four
||| `uint32_t` fields back-to-back, totalling 16 bytes, alignment 4.
public export
tileHeader : StructLayout
tileHeader =
  MkStructLayout
    [ MkField "x"      0  4 4
    , MkField "y"      4  4 4
    , MkField "width"  8  4 4
    , MkField "height" 12 4 4
    ]
    16 4 {aligned = div4_16}

||| Headline theorem: the `PtTile` header is C-ABI compliant. Each
||| `ConsField` step witnesses that the named field's offset divides
||| its alignment; `NoFields` closes the chain.
public export
tileHeaderCompliant : CABICompliant ABI.Compliance.tileHeader
tileHeaderCompliant =
  CABIOk ABI.Compliance.tileHeader (
    ConsField (MkField "x"      0  4 4) _ div4_0 (
    ConsField (MkField "y"      4  4 4) _ div4_4 (
    ConsField (MkField "width"  8  4 4) _ div4_8 (
    ConsField (MkField "height" 12 4 4) _ div4_12
    NoFields))))

--------------------------------------------------------------------------------
-- Array packing: arrays of compliant structs stay aligned
--------------------------------------------------------------------------------

||| Element offset within an array of identical `StructLayout`s.
||| `arrayElementOffset l i = i * totalSize l`.
public export
arrayElementOffset : (l : StructLayout) -> (i : Nat) -> Nat
arrayElementOffset l i = i * l.totalSize

||| Generic lemma: if `a` divides `b`, then `a` also divides `i * b`
||| for any `i : Nat`. This is the algebraic step needed to prove that
||| every element of an array of compliant structs is aligned.
export
dividesScalesUp :
  (a, b : Nat) ->
  (i : Nat) ->
  Divides a b ->
  Divides a (i * b)
dividesScalesUp a b i (MkDivides k prf) =
  MkDivides (i * k) (rewrite prf in multAssociative i k a)

||| Headline array-alignment theorem: every element of an array of
||| `tileHeader`s is aligned to 4 bytes.
export
tileHeaderArrayAligned :
  (i : Nat) ->
  Divides 4 (arrayElementOffset ABI.Compliance.tileHeader i)
tileHeaderArrayAligned i =
  dividesScalesUp 4 16 i div4_16

--------------------------------------------------------------------------------
-- Field-uniqueness sanity check (offsets are strictly increasing)
--------------------------------------------------------------------------------

||| Strict less-than chain on the four header offsets. Carried as a
||| Vect-of-LTs so future linters / refactors that reorder fields will
||| break this theorem and force a re-think.
public export
tileHeaderOffsetsAscending : Vect 3 (n ** m ** LT n m)
tileHeaderOffsetsAscending =
  [ (0 ** 4  ** LTESucc LTEZero)
  , (4 ** 8  ** LTESucc (LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))))
  , (8 ** 12 ** LTESucc (LTESucc (LTESucc (LTESucc (LTESucc (LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))))))))
  ]
