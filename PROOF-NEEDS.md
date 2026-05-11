# Proof Requirements — paint-type
<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->

## Proof Tier

**Tier**: T1 — Critical (image editor with formally-verified ABI bridge; linear type safety is load-bearing)

## Proof Categories

| Code | Meaning | Applies? |
|------|---------|----------|
| **TP** | Typing Proofs (type soundness, type safety) | Yes |
| **INV** | Invariant Proofs (state machines, monotonicity, bounds) | Yes |
| **SEC** | Security Proofs (crypto, injection freedom, access control) | Yes (plugin sandbox) |
| **CONC** | Concurrency Proofs (linearizability, deadlock freedom) | Yes (Burble collaboration) |
| **ALG** | Algorithm Proofs (termination, correctness, bounds) | Yes (compositing, undo graph) |
| **ABI** | ABI/FFI Proofs (memory layout, pointer safety, platform compat) | Yes — primary |
| **DOM** | Domain-Specific Proofs (bespoke to this project) | Yes (tile compositing correctness) |

## ABI/FFI Boundary Proofs (Idris2) — Partially Complete

| # | Proof | Status | File |
|---|-------|--------|------|
| ABI-1 | Non-null pointer proofs (`So (ptr /= 0)`) | **Done** | `src/interface/Abi/Types.idr` |
| ABI-2 | Memory layout correctness (`HasSize`, `HasAlignment`) | **Done** | `src/interface/Abi/Layout.idr` |
| ABI-3 | Platform type size proofs (per platform) | Needed | `verification/proofs/idris2/ABI/Platform.idr` |
| ABI-4 | FFI function return type proofs | **Done** | `src/interface/Abi/Foreign.idr` |
| ABI-5 | C ABI compliance (`CABICompliant`, `FieldsAligned`) | Needed | `verification/proofs/idris2/ABI/Compliance.idr` |

## Typing Proofs

| # | Proof | Status | File |
|---|-------|--------|------|
| TP-1 | Tile primitive type well-formedness | **Done** | `src/interface/Abi/Types.idr` |
| TP-2 | Public API type safety (exported pt_ functions) | Needed | `verification/proofs/lean4/ApiTypes.lean` |
| TP-3 | RGBA16F pixel format bounds (no overflow, no NaN propagation) | Needed | `verification/proofs/idris2/Pixel.idr` |

## Invariant Proofs

| # | Proof | Status | File |
|---|-------|--------|------|
| INV-1 | Tile pool invariant (no double-free, no use-after-free) | Needed | `verification/proofs/idris2/TilePool.idr` |
| INV-2 | Undo graph monotonicity (history only grows; no silent discard) | Needed | `verification/proofs/lean4/UndoGraph.lean` |
| INV-3 | Compositing blend function totality (terminates on all inputs) | Needed | `verification/proofs/agda/Compositing.agda` |

## Security Proofs (Plugin Sandbox)

| # | Proof | Status | File |
|---|-------|--------|------|
| SEC-1 | Plugin WASM sandbox isolation (no escape to Ephapax memory) | Needed | `verification/proofs/tlaplus/PluginSandbox.tla` |
| SEC-2 | Plugin API surface confinement (only typed-wasm API, no raw FFI) | Needed | `verification/proofs/lean4/PluginConfinement.lean` |

## Concurrency Proofs (Burble Collaboration)

| # | Proof | Status | File |
|---|-------|--------|------|
| CONC-1 | CRDT tile merge commutativity (A⊕B = B⊕A) | Needed | `verification/proofs/agda/TileCRDT.agda` |
| CONC-2 | CRDT tile merge associativity (A⊕(B⊕C) = (A⊕B)⊕C) | Needed | `verification/proofs/agda/TileCRDT.agda` |
| CONC-3 | Session liveness (every committed tile mutation is eventually visible) | Needed | `verification/proofs/tlaplus/BurbleSession.tla` |

## Dangerous Patterns (BANNED)

| Pattern | Language | Meaning |
|---------|----------|---------|
| `believe_me` | Idris2 | Unsafe cast / trust-me |
| `assert_total` | Idris2 | Skip totality check |
| `postulate` | Idris2/Agda | Unproven axiom |
| `sorry` | Lean4 | Incomplete proof |
| `Admitted` | Coq | Incomplete proof |
| `unsafeCoerce` | Haskell | Unsafe type cast |
| `Obj.magic` | OCaml/ReScript | Unsafe type cast |
| `unsafe` (unaudited) | Rust | Unsafe block without safety comment |

CI rejects any PR introducing these patterns (enforced by `panic-attack assail`).

## Prover Selection Guide

| Use Case | Recommended Prover | Why |
|----------|-------------------|-----|
| ABI/FFI boundaries | **Idris2** | Dependent types model layouts precisely |
| Tile pool invariants | **Idris2** | Linear types match the Rust ownership model |
| Type system proofs | **Lean4** | Good mathlib support for API surface proofs |
| CRDT properties | **Agda** | Native support for algebraic structures |
| Plugin sandbox / protocols | **TLA+** | Model checking for isolation and liveness |
| Compositing bounds | **Agda** | Inductive proofs on pixel value ranges |

## Proof File Locations

```
verification/proofs/
├── idris2/          # Idris2 proofs (ABI, tile pool, pixel bounds)
│   ├── ABI/         # ABI-specific proofs
│   ├── TilePool.idr # Tile pool invariants
│   └── Pixel.idr    # RGBA16F bounds
├── lean4/           # Lean4 proofs (API types, undo graph, plugin confinement)
│   ├── ApiTypes.lean
│   ├── UndoGraph.lean
│   └── PluginConfinement.lean
├── agda/            # Agda proofs (compositing, CRDT properties)
│   ├── Compositing.agda
│   └── TileCRDT.agda
├── coq/             # Coq proofs (type safety scaffold)
│   └── TypeSafety.v
└── tlaplus/         # TLA+ specs (plugin sandbox, Burble session)
    ├── StateMachine.tla
    ├── PluginSandbox.tla
    └── BurbleSession.tla
```

## References

- Proof status tracking: `PROOF-STATUS.md` (this repo)
- Proven library: `proven` repo (Idris2 verified foundations)
- ABI definitions: `src/interface/Abi/` (Idris2, already verified)
