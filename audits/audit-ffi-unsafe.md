# Audit: Legitimate FFI Unsafe Code

**Date:** 2026-06-07  
**Severity:** High (legitimate)  
**Files:** 
- `src/paint_core/src/lib.rs` (Rust FFI declarations and wrappers)
- `src/interface/ffi/src/main.zig` (Zig FFI implementation)
**Status:** Legitimate - Required for cross-language ABI

## Finding

Panic-attack reports multiple `UnsafeCode` findings in FFI-related files.

## Analysis

### Rust Side (`src/paint_core/src/lib.rs`)

This file contains:
1. **`unsafe extern "C"` block** (lines 51-108): FFI function declarations matching the Zig libpt ABI
2. **Multiple `unsafe` blocks** in Tile implementation methods that call FFI functions

**Why this is legitimate:**
- Cross-language FFI **requires** unsafe code in Rust
- The extern "C" declarations exactly match `src/interface/ffi/src/main.zig`
- All unsafe blocks are **wrapped in safe Rust APIs** with proper validation
- Each unsafe call includes SAFETY comments explaining the preconditions

**Safety mechanisms:**
- Null pointer checks before dereferencing
- Bounds checking on all pixel coordinates
- Magic word validation to prevent use-after-free
- Proper error handling via Result types

### Zig Side (`src/interface/ffi/src/main.zig`)

This file contains the **canonical FFI implementation** for the paint-type C ABI.

**Why this is legitimate:**
- C ABI requires pointer manipulation that Zig marks as unsafe
- All functions include comprehensive safety checks:
  - Null pointer validation (`if (tile_ptr == 0)`)
  - Magic word verification (`tile.isLive()`)
  - Bounds checking (`px >= TILE_SIZE`)
  - Double-free prevention (magic word poisoning)

**Safety mechanisms:**
```zig
// Example from pt_tile_free:
if (tile_ptr == 0) return;
const tile: *PtTile = @ptrFromInt(tile_ptr);
if (tile.magic != PT_TILE_MAGIC) {
    setError("pt_tile_free: invalid or already-freed tile");
    return;
}
tile.magic = PT_TILE_DEAD_MAGIC; // poison to prevent double-free
```

## Contract Compliance

The FFI code implements the **paint-type ABI contract** defined in:
- `src/interface/Abi/Foreign.idr` (Idris2 type declarations)
- `src/interface/Abi/Types.idr` (type definitions)

All three language implementations (Rust, Zig, Idris2) must agree on:
- Memory layout of data structures
- Function signatures and calling conventions
- Error codes and return values

## Recommendation

These findings should be **suppressed** as legitimate FFI code. The unsafe blocks are:
1. **Necessary** - Cannot be eliminated without breaking cross-language interoperability
2. **Bounded** - All pointer operations include validation
3. **Documented** - Extensive SAFETY comments explain each unsafe operation
4. **Audited** - The ABI contract is formalized in Idris2 with layout proofs

## Evidence

```bash
# Verify the ABI contract matches across implementations
$ grep -n "pt_tile_alloc\|pt_tile_free\|pt_tile_fill" src/interface/Abi/Foreign.idr
$ grep -n "export fn pt_tile_alloc\|export fn pt_tile_free\|export fn pt_tile_fill" src/interface/ffi/src/main.zig
$ grep -n "pt_tile_alloc\|pt_tile_free\|pt_tile_fill" src/paint_core/src/lib.rs
```

All three files show matching function signatures, confirming the contract is properly implemented.
