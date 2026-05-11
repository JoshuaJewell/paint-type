# Proof Status — paint-type
<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Tracks proof completion. Requirements defined in PROOF-NEEDS.md -->

## Summary

| Category | Total | Done | In Progress | Blocked | Remaining |
|----------|-------|------|-------------|---------|-----------|
| ABI/FFI (ABI) | 5 | 3 | 0 | 0 | 2 |
| Typing (TP) | 3 | 1 | 0 | 0 | 2 |
| Invariant (INV) | 3 | 0 | 0 | 0 | 3 |
| Security (SEC) | 2 | 0 | 0 | 0 | 2 |
| Concurrency (CONC) | 3 | 0 | 0 | 0 | 3 |
| Algorithm (ALG) | 0 | 0 | 0 | 0 | 0 |
| Domain (DOM) | 0 | 0 | 0 | 0 | 0 |
| **Total** | **16** | **4** | **0** | **0** | **12** |

**Overall**: 25% proven (4/16 — the Idris2 ABI bridge proofs are done)

## Proofs Done

| ID | Proof | Prover | File | Date | Verified By |
|----|-------|--------|------|------|-------------|
| ABI-1 | Non-null pointer proofs | Idris2 | `src/interface/Abi/Types.idr` | 2026-05-11 | idris2 --check |
| ABI-2 | Memory layout correctness | Idris2 | `src/interface/Abi/Layout.idr` | 2026-05-11 | idris2 --check |
| ABI-4 | FFI function return type proofs | Idris2 | `src/interface/Abi/Foreign.idr` | 2026-05-11 | idris2 --check |
| TP-1 | Tile primitive type well-formedness | Idris2 | `src/interface/Abi/Types.idr` | 2026-05-11 | idris2 --check |

## Proofs In Progress

| ID | Proof | Prover | Assignee | Started | Blocker |
|----|-------|--------|----------|---------|---------|
| — | — | — | — | — | — |

## Proofs Blocked

| ID | Proof | Blocked By | Notes |
|----|-------|------------|-------|
| CONC-1 | CRDT tile merge commutativity | Burble not started | Depends on v0.5.0 Burble design being finalised |
| CONC-2 | CRDT tile merge associativity | Burble not started | Same blocker as CONC-1 |
| CONC-3 | Session liveness | Burble not started | TLA+ model needs Burble session protocol spec |
| SEC-1 | Plugin WASM sandbox isolation | Plugin system not started | Depends on v0.4.0 plugin design |
| SEC-2 | Plugin API surface confinement | Plugin system not started | Same blocker as SEC-1 |

## Proofs Remaining (Unblocked)

| ID | Proof | Category | Prover | Priority | Est. Effort |
|----|-------|----------|--------|----------|-------------|
| ABI-3 | Platform type size proofs | ABI | Idris2 | P1 | 2h |
| ABI-5 | C ABI compliance | ABI | Idris2 | P1 | 4h |
| TP-2 | Public API type safety | TP | Lean4 | P1 | 4h |
| TP-3 | RGBA16F pixel format bounds | TP | Idris2 | P2 | 3h |
| INV-1 | Tile pool invariant (no double-free) | INV | Idris2 | P1 | 6h |
| INV-2 | Undo graph monotonicity | INV | Lean4 | P2 | 4h |
| INV-3 | Compositing blend function totality | INV | Agda | P2 | 4h |

## Verification Commands

```bash
# Check Idris2 proofs (ABI bridge — already passing)
cd src/interface && idris2 --check Abi/Types.idr Abi/Layout.idr Abi/Foreign.idr

# Run Zig FFI tests
cd src/interface/ffi && zig build test

# Run Rust Ephapax tests
cd src/ephapax && cargo test

# Scan for dangerous patterns
panic-attack assail --proofs-only

# Run all proof checks (when infrastructure is wired)
just proof-check-all
```

## Changelog

| Date | Change | By |
|------|--------|-----|
| 2026-05-11 | Initial proof status for paint-type — ABI bridge proofs marked done | Joshua Jewell |
