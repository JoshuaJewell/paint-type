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
| Zig FFI (libpt)     | C     | Pre-alpha     | 29/29 tests pass; 23 exports (pt_tile_* + pt_layer_* + slot helpers) |
| Ephapax (Rust core) | C     | Pre-alpha     | Tile API + 11 compositing ops + UndoGraph + layer model + brush engine + benches (cargo test 98/98 + 1 doctest) |
| AffineScript bridge | D     | Pre-alpha     | Draft `.twasm` schemas in `src/bridges/`; gated on `hyperpolymath/typed-wasm#127` + `#130` (paint-type#39) |
| Gossamer shell integration | D | Pre-alpha  | Not started; architecture specified                       |
| Burble / Groove     | D     | Pre-alpha     | Not started; architecture specified                       |

**Overall:** Grade D (closing on C) — 15 PRs of v0.2.0 work landed 2026-06-01: compositing primitives + 7 more operators (lerp/multiply/screen/in/out/atop/xor), non-uniform `Tile::composite_over`, persistent UndoGraph + benches, basic Layer / LayerStack model, brush engine (tip masks + stroke sampling + tile-local stamping), pt_layer_* cross-language FFI, ABI-3/ABI-5/TP-3 proofs, **draft `.twasm` schemas at `src/bridges/`** (PR #40), and the full CI tail — coverage (PR #32 + #34), E2E pipeline (PR #33), fuzz harness (PR #35), Rust CI now green on main (PRs #36/#37/#38). ABI category fully proven; cargo test 98/98 + 1 doctest; zig build test 29/29; aspect tests 7 PASS. Remaining v0.2.0 work: AffineScript → typed-wasm bridge **compilation** (draft `.twasm` exists; `tw build` gated on `hyperpolymath/typed-wasm#127` + `#130`; paint-type#39). Outstanding for Grade C: AffineScript bridge generated and verifier-accepted, Gossamer integration started.

---

## Grade D Evidence

- Repository follows RSR standards (CI/CD, SPDX, machine-readable metadata, CRG structure)
- `src/interface/Abi/` — Idris2 types and layout proofs compile and typecheck
- `src/interface/ffi/` — Zig libpt builds and integration tests pass (29/29)
- `src/paint_core/` — Rust crate builds with `cargo test` (98/98 + 1 doctest); `cargo clippy --all-targets -- -D warnings` clean
- dogfood-gate, hypatia-scan, static-analysis-gate workflows all green
- **Rust CI green on `main` since 2026-06-01** (`.github/workflows/rust.yml` — PRs #36/#37/#38)
- idris-ci, coverage, e2e, and fuzz-smoke workflows wired and exercising the v0.2.0 surface
- TOPOLOGY.md, TEST-NEEDS.md, PROOF-NEEDS.md, and ROADMAP.adoc reflect actual project state

---

## Promotion Path to Grade C

Grade C requires: **deep code and folder annotation; CI passing; dogfooded on own project**.

To reach C:
1. ~~Complete Ephapax compositing primitives~~ — DONE (PR #20)
2. ~~Tile-level non-uniform composite~~ — DONE (PR #21)
3. ~~Non-destructive undo graph~~ — DONE (PR #21)
4. ~~Basic layer model~~ — DONE (PR #23)
5. ~~Wire compositing into a real brush engine (stroke handling, kernel sampling)~~ — DONE (PR #29)
6. Generate AffineScript → typed-wasm bridge from Idris2 ABI (gated on typed-wasm emitter stability)
7. Integrate with Gossamer shell for a runnable application (v0.3.0, issue #13)
8. ~~Wire integration tests into CI~~ — DONE (idris-ci.yml + aspect tests + reused tile tests)
9. ~~Populate E2E test with the full pipeline scenario~~ — DONE (PR #33): `tests/e2e.sh` orchestrator + `src/paint_core/tests/e2e_pipeline.rs` (2 Rust scenarios driving Tile lifecycle + composite_over + UndoGraph + pt_layer_* + Brush::stamp) + `tests/e2e/scenario_*.sh` probes + `.github/workflows/e2e.yml`.
10. Update this file with evidence

### Closed prerequisites (2026-06-01)
- Idris2 `--check` runs in CI for the ABI bridge + the 3 verified proof modules
  (`ABI/Platform.idr`, `ABI/Compliance.idr`, `Pixel.idr`).
- Aspect tests cover 7 cross-cutting concerns and pass locally + CI. The
  ABI/FFI subset relation is now 7 Idris2 imports ⊆ **23** Zig exports
  (pt_tile_* + pt_layer_* + slot helpers).
- **ABI category fully proven**: ABI-1/2/3/4/5 all done. TP-1/TP-3 done.
- `cargo test` **98/98** + 1 doctest pass (lib + composite + undo +
  layer + brush modules) after the f16→f32 underflow fix (PR #11).
- `zig build && zig build test` **29/29** pass — pt_tile_* lifecycle/fill/
  read/write/bounds/version/null-safety plus 11 pt_layer_* integration
  tests (lifecycle/push/delete/reorder/opacity-clamp/visibility/safety).
- Undo-graph benchmark baseline: 88 ns/commit, 2 ns/checkout.
- panic-attack scan: 3 weak points, all pre-existing false-positive
  heuristics (5 audited `unsafe` blocks + 1 commented-out `/tmp` ref).
- Brush engine landed (BrushTip soft/hard round, Brush::stamp with
  mask-modulated blend, Stroke point interpolation) — PR #29.
- 7 additional compositing operators landed (lerp, multiply, screen,
  in_op, out_op, atop, xor) — PR #27.
- pt_layer_* cross-language FFI surface landed — PR #28 (closes #25).
- Coverage reporting wired into CI for both Rust and Zig
  (`.github/workflows/coverage.yml`, local: `bash tests/coverage.sh`).
  Rust side uses `cargo-llvm-cov` → LCOV + console report from
  `src/paint_core/`; Zig side uses `kcov` over the integration-test
  binary as a best-effort, non-blocking step (Zig 0.15 test runners
  are not always kcov-friendly). Both outputs upload as artifacts
  every run; Codecov upload is opt-in via a `CODECOV_TOKEN` secret.
  Reporting only — no threshold gate. PR #32.
- E2E test populated (PR #33): `bash tests/e2e.sh` runs 9 stages
  (preflight + zig build + zig test + cargo `e2e_pipeline` integration
  test with 2 scenarios + 2 `scenario_*.sh` artifact / dogfood probes)
  and exits 0 on the v0.2.0 pipeline. CI wired via `e2e.yml`.

---

## Promotion Path to Grade B

Grade B requires: **6+ diverse external targets tested, issues fed back**.

This follows after reaching Grade C. Target: after v0.3.0 Desktop Shell milestone.

---

## Concerns and Maintenance Notes

- Ephapax is architecturally specified but not yet feature-complete — compositing, brush engine, and undo graph are all v0.2.0 work
- AffineScript bridge has draft `.twasm` schemas at `src/bridges/paint-type-{tile,layer}.twasm`; the AffineScript-ABI → `.twasm` generator + the upstream `tw build` path are not yet integrated (gated on `hyperpolymath/typed-wasm#127` general front-end + `#130` round-trip soundness; tracked in paint-type#39)
- Gossamer shell integration has not started; depends on Gossamer reaching a usable API surface
- Burble and Groove collaboration layers are future work (v0.5.0)
