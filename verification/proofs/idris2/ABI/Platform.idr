-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- ABI Proof: Platform-specific type size proofs (PROOF-NEEDS ABI-3)
-- Proves that C type sizes are correct per platform.
-- All proofs MUST be constructive (no believe_me, no assert_total).
--
-- Echo-types audit (per estate proof discipline 2026-06-01)
-- ──────────────────────────────────────────────────────────────
-- Audited `hyperpolymath/echo-types` for prior platform-size proofs:
-- VERDICT = NONE. Echo-types is an Agda formalisation of structured loss;
-- it has zero material on platform-specific C ABIs, byte-width axioms,
-- or pointer-size proofs. ABI-3 is classified L1/L4-only (not echo-
-- relevant) and developed in-repo.
-- Reference: feedback_proofs_must_check_and_cross_doc_echo_types.md

module ABI.Platform

import Data.Nat

%default total

||| Supported target platforms for ABI verification.
public export
data Platform = Linux64 | LinuxARM64 | MacOS64 | MacOSARM64
              | Windows64 | FreeBSD64 | WASM32

||| Pointer size in bytes for each platform.
public export
ptrSize : Platform -> Nat
ptrSize WASM32 = 4
ptrSize _ = 8

||| C `int` size in bytes. ILP32 / LP64 / LLP64 all agree on this.
public export
cIntSize : Platform -> Nat
cIntSize _ = 4

||| C `unsigned int` size in bytes.
public export
cUIntSize : Platform -> Nat
cUIntSize _ = 4

||| C `int16_t` / `uint16_t` size in bytes.
public export
cInt16Size : Platform -> Nat
cInt16Size _ = 2

||| C `int32_t` / `uint32_t` size in bytes.
public export
cInt32Size : Platform -> Nat
cInt32Size _ = 4

||| C `int64_t` / `uint64_t` size in bytes.
public export
cInt64Size : Platform -> Nat
cInt64Size _ = 8

||| C `long` size in bytes — model-dependent.
||| LP64 (Linux/macOS/FreeBSD): 8.  LLP64 (Windows): 4.  ILP32 (WASM32): 4.
public export
cLongSize : Platform -> Nat
cLongSize Linux64 = 8
cLongSize LinuxARM64 = 8
cLongSize MacOS64 = 8
cLongSize MacOSARM64 = 8
cLongSize FreeBSD64 = 8
cLongSize Windows64 = 4
cLongSize WASM32 = 4

||| C `size_t` size in bytes (matches pointer size on every supported
||| platform — this is required by the C standard).
public export
cSizeT : Platform -> Nat
cSizeT = ptrSize

||| Proof that size_t always equals pointer size on all platforms.
export
sizeTEqPtrSize : (p : Platform) -> cSizeT p = ptrSize p
sizeTEqPtrSize _ = Refl

||| Proof that pointer size is always 4 or 8 bytes.
export
ptrSizeValid : (p : Platform) -> Either (ptrSize p = 4) (ptrSize p = 8)
ptrSizeValid WASM32 = Left Refl
ptrSizeValid Linux64 = Right Refl
ptrSizeValid LinuxARM64 = Right Refl
ptrSizeValid MacOS64 = Right Refl
ptrSizeValid MacOSARM64 = Right Refl
ptrSizeValid Windows64 = Right Refl
ptrSizeValid FreeBSD64 = Right Refl

||| Proof that C int is always 4 bytes on all platforms.
export
cIntAlways4 : (p : Platform) -> cIntSize p = 4
cIntAlways4 _ = Refl

||| Proof that uint32_t is always 4 bytes on all platforms (standard).
export
cInt32Always4 : (p : Platform) -> cInt32Size p = 4
cInt32Always4 _ = Refl

||| Proof that uint16_t is always 2 bytes (standard).
export
cInt16Always2 : (p : Platform) -> cInt16Size p = 2
cInt16Always2 _ = Refl

||| Proof that uint64_t is always 8 bytes (standard).
export
cInt64Always8 : (p : Platform) -> cInt64Size p = 8
cInt64Always8 _ = Refl

||| Proof that pointer size is always at least 4 bytes.
||| Built with explicit `LTESucc`/`LTEZero` so it does not depend on
||| any stdlib-named helpers whose naming has shifted between Idris2
||| releases. Each branch reduces to `LTE 4 (ptrSize p)`.
export
ptrSizeAtLeast4 : (p : Platform) -> LTE 4 (ptrSize p)
ptrSizeAtLeast4 WASM32     = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))
ptrSizeAtLeast4 Linux64    = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))
ptrSizeAtLeast4 LinuxARM64 = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))
ptrSizeAtLeast4 MacOS64    = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))
ptrSizeAtLeast4 MacOSARM64 = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))
ptrSizeAtLeast4 Windows64  = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))
ptrSizeAtLeast4 FreeBSD64  = LTESucc (LTESucc (LTESucc (LTESucc LTEZero)))

--------------------------------------------------------------------------------
-- Tile-header layout proofs (paint-type-specific, ties Platform → bytes)
--------------------------------------------------------------------------------

||| The tile-header struct on the FFI boundary is
|||   struct PtTile {
|||     uint32_t x;       // offset 0,  size 4
|||     uint32_t y;       // offset 4,  size 4
|||     uint32_t width;   // offset 8,  size 4
|||     uint32_t height;  // offset 12, size 4
|||   }
||| Total = 4 * sizeof(uint32_t) = 16 bytes, on every supported platform.
||| Phrased over `cInt32Size` so it generalises automatically if the
||| sizing model is ever extended.
export
tileHeaderSize : (p : Platform) -> 4 * cInt32Size p = 16
tileHeaderSize Linux64 = Refl
tileHeaderSize LinuxARM64 = Refl
tileHeaderSize MacOS64 = Refl
tileHeaderSize MacOSARM64 = Refl
tileHeaderSize Windows64 = Refl
tileHeaderSize FreeBSD64 = Refl
tileHeaderSize WASM32 = Refl

||| The tile pixel buffer is `64 * 64 * 4 channels * 2 bytes` on every
||| platform (RGBA16F is the only format paint-type currently supports).
||| Independent of platform because the format is fixed.
export
tilePixelBufferSize : (p : Platform) -> 64 * 64 * (4 * cInt16Size p) = 32768
tilePixelBufferSize Linux64 = Refl
tilePixelBufferSize LinuxARM64 = Refl
tilePixelBufferSize MacOS64 = Refl
tilePixelBufferSize MacOSARM64 = Refl
tilePixelBufferSize Windows64 = Refl
tilePixelBufferSize FreeBSD64 = Refl
tilePixelBufferSize WASM32 = Refl

||| Total tile allocation (header + pixel buffer) = 32784 bytes everywhere.
export
tileTotalSize : (p : Platform) -> 4 * cInt32Size p + 64 * 64 * (4 * cInt16Size p) = 32784
tileTotalSize Linux64 = Refl
tileTotalSize LinuxARM64 = Refl
tileTotalSize MacOS64 = Refl
tileTotalSize MacOSARM64 = Refl
tileTotalSize Windows64 = Refl
tileTotalSize FreeBSD64 = Refl
tileTotalSize WASM32 = Refl
