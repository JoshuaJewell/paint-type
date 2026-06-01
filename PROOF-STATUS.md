# Proof Status — paint-type
<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Tracks proof completion. Requirements defined in PROOF-NEEDS.md -->

## Summary

| Category | Total | Done | In Progress | Blocked | Remaining |
|----------|-------|------|-------------|---------|-----------|
| ABI/FFI (ABI) | 5 | 4 | 0 | 0 | 1 |
| Typing (TP) | 3 | 2 | 0 | 0 | 1 |
| Invariant (INV) | 3 | 0 | 0 | 0 | 3 |
| Security (SEC) | 2 | 0 | 0 | 0 | 2 |
| Concurrency (CONC) | 3 | 0 | 0 | 0 | 3 |
| Algorithm (ALG) | 0 | 0 | 0 | 0 | 0 |
| Domain (DOM) | 0 | 0 | 0 | 0 | 0 |
| **Total** | **16** | **6** | **0** | **0** | **10** |

**Overall**: 38% proven (6/16) — ABI bridge + per-platform sizes + RGBA16F bit-pattern classifier. `idris2 --check` runs in CI per `.github/workflows/idris-ci.yml` (added in PR #8).

## Proofs Done

| ID | Proof | Prover | File | Date | Verified By |
|----|-------|--------|------|------|-------------|
| ABI-1 | Non-null pointer proofs | Idris2 | `src/interface/Abi/Types.idr` | 2026-05-11 | idris2 --check |
| ABI-2 | Memory layout correctness | Idris2 | `src/interface/Abi/Layout.idr` | 2026-05-11 | idris2 --check |
| ABI-3 | Platform type size proofs (per platform) | Idris2 | `verification/proofs/idris2/ABI/Platform.idr` | 2026-06-01 | idris2 --check + CI |
| ABI-4 | FFI function return type proofs | Idris2 | `src/interface/Abi/Foreign.idr` | 2026-05-11 | idris2 --check |
| TP-1 | Tile primitive type well-formedness | Idris2 | `src/interface/Abi/Types.idr` | 2026-05-11 | idris2 --check |
| TP-3 | RGBA16F pixel format bounds + classifier | Idris2 | `verification/proofs/idris2/Pixel.idr` | 2026-06-01 | idris2 --check + CI |

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
| ABI-5 | C ABI compliance | ABI | Idris2 | P1 | 4h |
| TP-2 | Public API type safety | TP | Lean4 | P1 | 4h |
| INV-1 | Tile pool invariant (no double-free) | INV | Idris2 | P1 | 6h |
| INV-2 | Undo graph monotonicity | INV | Lean4 | P2 | 4h |
| INV-3 | Compositing blend function totality | INV | Agda | P2 | 4h |

## Echo-types audit log

Per estate proof discipline (memory: `feedback_proofs_must_check_and_cross_doc_echo_types`), every paint-type proof must first audit `hyperpolymath/echo-types` for prior art before being developed in-repo.

| Proof | Audit Date | Echo-types Verdict | Classification |
|-------|------------|--------------------|---------------|
| ABI-3 | 2026-06-01 | NONE — no platform-size material upstream | L1/L4-only (not echo-relevant) |
| TP-3  | 2026-06-01 | NONE — no IEEE 754 / RGBA / float material upstream | L1/L4-only (not echo-relevant) |

## Verification Commands

```bash
# Check Idris2 proofs (ABI bridge in src/interface, verified modules in verification/)
cd src/interface && idris2 --check Abi/Types.idr Abi/Layout.idr Abi/Foreign.idr
cd ../../verification/proofs/idris2 && idris2 --check ABI/Platform.idr Pixel.idr

# Run Zig FFI tests
cd src/interface/ffi && zig build test

# Run Rust Ephapax tests
cd src/ephapax && cargo test

# Run aspect tests (SPDX, dangerous-pattern, ABI/FFI contract, RGBA16F constants, …)
bash tests/aspect_tests.sh

# Scan for dangerous patterns
panic-attack assail --proofs-only

# Run all proof checks (when infrastructure is wired)
just proof-check-all
```

## Changelog

| Date | Change | By |
|------|--------|-----|
| 2026-05-11 | Initial proof status for paint-type — ABI bridge proofs marked done | Joshua Jewell |
| 2026-06-01 | ABI-3 + TP-3 landed (PR #10); CI proof-check wired (PR #8); 38% proven | hyperpolymath |
