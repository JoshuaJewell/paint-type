<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Last updated: 2026-06-01 -->

# paint-type Component Readiness Assessment

**Standard:** [Component Readiness Grades (CRG) v2.2](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)
**Current Grade:** D (approaching C — proof + test prerequisites mostly closed; see Promotion Path)
**Assessed:** 2026-06-01
**Assessor:** Joshua Jewell

---

## Summary

| Component           | Grade | Release Stage | Evidence Summary                                          |
|---------------------|-------|---------------|-----------------------------------------------------------|
| Idris2 ABI (Types, Layout, Foreign) | C | Pre-alpha | Compiles + CI-checked; ABI category fully proven (ABI-1..5 done) |
| Zig FFI (libpt)     | C-    | Pre-alpha     | 18/18 tests pass; 11 exports (alloc/free/fill/read/write/version/…) |
| Ephapax (Rust core) | C-    | Pre-alpha     | Tile API + Porter-Duff compositing + UndoGraph + layer model + benches (cargo test 56/56) |
| AffineScript bridge | D     | Pre-alpha     | Stubs only; gated on typed-wasm emitter stability         |
| Gossamer shell integration | D | Pre-alpha  | Not started; architecture specified                       |
| Burble / Groove     | D     | Pre-alpha     | Not started; architecture specified                       |

**Overall:** Grade D (approaching C) — substantial v0.2.0 work landed in 6 PRs on 2026-06-01: compositing primitives, non-uniform `Tile::composite_over`, persistent UndoGraph + benches, basic Layer / LayerStack model, ABI-3/ABI-5/TP-3 proofs. ABI category is now fully proven; cargo test 56/56; zig build test 18/18; aspect tests 7 PASS. Outstanding for Grade C: brush engine wired into stroke handling, AffineScript bridge generated, Gossamer integration.

---

## Grade D Evidence

- Repository follows RSR standards (CI/CD, SPDX, machine-readable metadata, CRG structure)
- `src/interface/Abi/` — Idris2 types and layout proofs compile and typecheck
- `src/interface/ffi/` — Zig libpt builds and integration tests pass
- `src/ephapax/` — Rust crate builds with `cargo test`
- dogfood-gate, hypatia-scan, and static-analysis-gate workflows all green
- TOPOLOGY.md, TEST-NEEDS.md, PROOF-NEEDS.md, and ROADMAP.adoc reflect actual project state

---

## Promotion Path to Grade C

Grade C requires: **deep code and folder annotation; CI passing; dogfooded on own project**.

To reach C:
1. ~~Complete Ephapax compositing primitives~~ — DONE (PR #20)
2. ~~Tile-level non-uniform composite~~ — DONE (PR #21)
3. ~~Non-destructive undo graph~~ — DONE (PR #21)
4. ~~Basic layer model~~ — DONE (PR #23)
5. Wire compositing into a real brush engine (stroke handling, kernel sampling) — v0.2.0 remaining
6. Generate AffineScript → typed-wasm bridge from Idris2 ABI (gated on typed-wasm emitter stability)
7. Integrate with Gossamer shell for a runnable application (v0.3.0, issue #13)
8. ~~Wire integration tests into CI~~ — DONE (idris-ci.yml + aspect tests + reused tile tests)
9. Update this file with evidence

### Closed prerequisites (2026-06-01)
- Idris2 `--check` runs in CI for the ABI bridge + the 3 verified proof modules
  (`ABI/Platform.idr`, `ABI/Compliance.idr`, `Pixel.idr`).
- Aspect tests cover 7 cross-cutting concerns and pass locally + CI.
- **ABI category fully proven**: ABI-1/2/3/4/5 all done. TP-1/TP-3 done.
- `cargo test` 56/56 + 1 doctest pass (lib + composite + undo + layer
  modules) after the f16→f32 underflow fix (PR #11).
- `zig build && zig build test` 18/18 pass after the libc-linking fix
  (PR #11) and the `pt_tile_write_pixel` addition (PR #21).
- Undo-graph benchmark baseline: 88 ns/commit, 2 ns/checkout.
- panic-attack scan: 3 weak points, all pre-existing false-positive
  heuristics (5 audited `unsafe` blocks + 1 commented-out `/tmp` ref).

---

## Promotion Path to Grade B

Grade B requires: **6+ diverse external targets tested, issues fed back**.

This follows after reaching Grade C. Target: after v0.3.0 Desktop Shell milestone.

---

## Concerns and Maintenance Notes

- Ephapax is architecturally specified but not yet feature-complete — compositing, brush engine, and undo graph are all v0.2.0 work
- AffineScript bridge is stub-only; the code generator is not yet integrated
- Gossamer shell integration has not started; depends on Gossamer reaching a usable API surface
- Burble and Groove collaboration layers are future work (v0.5.0)
