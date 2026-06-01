# TEST-NEEDS: paint-type

## CRG Grade: D — current

## Current State (Updated 2026-06-01)

| Category | Count | Details |
|----------|-------|---------|
| **Source modules** | 11 | 3 Idris2 ABI (Foreign, Layout, Types) + 3 verification proof modules (ABI/Platform, ABI/Compliance, Pixel), 2 Zig FFI (build, main), 1 Zig integration test, 1 Rust Ephapax crate with 5 modules (lib, composite, undo, layer, brush) |
| **Unit tests** | 98 + 29 | 98 Rust unit tests across lib/composite/undo/layer/brush; 29 Zig inline + integration tests (incl. 11 pt_layer_* integration tests) |
| **Integration tests** | 1 | `src/interface/ffi/test/integration_test.zig` — lifecycle, blit, memory safety, version checks |
| **E2E tests** | 4 | `tests/e2e.sh` (full pipeline orchestrator); `src/ephapax/tests/e2e_pipeline.rs` (2 Rust scenarios driving the full Tile→composite→UndoGraph→pt_layer_*→Brush stack); `tests/e2e/scenario_libpt_artifacts.sh` (artifact + symbol probe); `tests/e2e/scenario_pipeline_dogfood.sh` (verbose cargo replay); `tests/e2e/template_instantiation_test.sh` (structure validation) |
| **Aspect tests** | 1 | `tests/aspect_tests.sh` — 7 aspects, 0 fail (SPDX, dangerous-pattern, ABI/FFI contract, Rust panic-safety, RGBA16F constants, Idris2 ABI check, file-I/O deferred) |
| **Workflow tests** | 1 | `tests/workflows/validate_workflows_test.sh` (validates CI workflow presence and structure) |
| **Coverage tooling** | 1 | `.github/workflows/coverage.yml` + `tests/coverage.sh` — Rust `cargo-llvm-cov` (LCOV + console report, gated on `src/ephapax/`); Zig `kcov` over the integration-test binary (best-effort, non-blocking). Reporting only — no threshold gate. |
| **Bench harnesses** | 1 | `src/ephapax/benches/undo.rs` — 88 ns/commit, 2 ns/checkout (hand-rolled `Instant` timer) |
| **Fuzz tests** | 3 | `src/ephapax/fuzz/fuzz_targets/{pt_tile_blit,pt_tile_write_pixel,pt_layer_opacity}.rs` — WIRED; 30 s smoke-test per target in CI (`.github/workflows/fuzz-smoke.yml`) |

## What Exists and Passes

### Zig FFI Integration Tests (PASSING)

`src/interface/ffi/test/integration_test.zig`:

- Tile lifecycle tests: `pt_tile_alloc` → `pt_tile_free` round-trip
- Blit operation tests: src → dst tile copy, bounds checking
- Memory safety tests: double-free detection, null pointer handling
- Version checks: `pt_version()` returns expected semver string
- Threading: concurrent alloc/free stress test scaffold

Run with: `zig build test` from `src/interface/ffi/`

### Rust Ephapax Unit Tests (PASSING — 98/98 + 1 doctest)

`src/ephapax/src/{lib,composite,undo,layer,brush}.rs`:

- `lib.rs` — Tile header construction, RGBA16F arithmetic, tile buffer
  alloc/dealloc, f16↔f32 round-trip, `pt_tile_write_pixel`, pt_layer_*
  FFI smoke (3 tests with /// SAFETY: comments).
- `composite.rs` — Porter-Duff `over_premultiplied` / `over_unpremultiplied`,
  `masked_blend`, `flatten_layer_stack`, `Tile::composite_over`, plus
  `lerp`, `multiply`, `screen`, `in_op`, `out_op`, `atop`, `xor`.
- `undo.rs` — `UndoGraph<T>` commit / branch / checkout / parent_of /
  children_of / is_ancestor / monotonic-RevId invariant.
- `layer.rs` — `Layer`, `LayerStack`, `LayerId`, push/delete/reorder_to/
  get/iter/flatten; stable IDs across reorderings.
- `brush.rs` — `BrushTip` (soft_round, hard_round), `Brush::stamp` with
  mask-modulated blend + tile-boundary clipping, `Stroke` point
  interpolation with spacing carry-over.

### Zig FFI Tests (PASSING — 29/29)

`src/interface/ffi/src/main.zig` + `test/integration_test.zig`:

- pt_tile_* — lifecycle, fill, read, write, version, double-free
  detection, magic-word safety, null-pointer safety, blit operations.
- pt_layer_* — stack lifecycle, push id-issuance + dense ordering,
  delete-then-stable-siblings, reorder top↔bottom, opacity clamp +
  NaN handling, visibility round-trip, post-free safety, null-stack
  uniform errors.

Run with: `cargo test` from `src/ephapax/`. Benches via `cargo bench`.

### Workflow Validation Tests (PASSING)

`tests/workflows/validate_workflows_test.sh`:

- Validates all expected CI workflows are present
- Checks SPDX headers on workflow files
- Verifies required `name:` field in each workflow

### Coverage Reporting (WIRED — reporting only, no gate)

`.github/workflows/coverage.yml` + `tests/coverage.sh`:

- **Rust**: `cargo llvm-cov --all-features --workspace --lcov` from
  `src/ephapax/`. Console summary printed to the job log and to
  `$GITHUB_STEP_SUMMARY`. LCOV file uploaded as artifact
  `rust-coverage-lcov` (30-day retention).
- **Zig**: `kcov --include-path=src/interface/ffi` over the integration
  test binary built via `zig test --test-no-exec`. Best-effort and
  non-blocking — Zig 0.15 test runners are awkward for kcov; uploaded
  as artifact `zig-coverage` whenever output exists.
- **Codecov**: opt-in. Upload step only runs when a `CODECOV_TOKEN`
  secret is configured; forks and unconfigured repos see no failure.
- **No threshold enforced** — this is reporting infrastructure, not a
  gate. Locally: `bash tests/coverage.sh` (`rust` | `zig` | `all`).

## What Is Missing (Priority Order)

### P1 — Required for CRG Grade C

- [x] Aspect tests populated — `tests/aspect_tests.sh` covers 7 aspects (SPDX, dangerous-pattern, ABI/FFI contract, Rust panic-safety, RGBA16F constants, Idris2 ABI check, file-I/O deferred). PR #9 (2026-06-01).
- [x] Idris2 ABI proof check integrated into CI — `.github/workflows/idris-ci.yml`. PR #8 (2026-06-01). Verified modules: `src/interface/Abi/{Types,Layout,Foreign}.idr` + `verification/proofs/idris2/{ABI/Platform.idr, Pixel.idr}`.
- [ ] File I/O round-trip aspect — deferred to v0.3.0 (native RGBA16F save/load surface needed first).
- [x] E2E test: end-to-end tile alloc → composite → free pipeline via the Zig FFI — `tests/e2e.sh` orchestrates `zig build` + `zig build test` + `cargo test --test e2e_pipeline` (Rust integration scenarios driving Tile lifecycle + `Tile::composite_over` + `UndoGraph` snapshots + `pt_layer_*` push/reorder + `Brush::stamp`) + `tests/e2e/scenario_*.sh`. CI wired via `.github/workflows/e2e.yml`. PR #33 (2026-06-01).
- [x] Coverage reporting wired into CI for both Zig and Rust — `.github/workflows/coverage.yml` + `tests/coverage.sh` land Rust LCOV via `cargo-llvm-cov` (hard requirement) plus best-effort Zig kcov; both artifacts uploaded each run. Reporting only — no threshold gate. PR #32 (2026-06-01).

### P2 — Required for CRG Grade B

- [x] Fuzz harness for `pt_tile_blit` (inputs: arbitrary src/dst dimensions, offsets) — `src/ephapax/fuzz/fuzz_targets/pt_tile_blit.rs` plus `pt_tile_write_pixel.rs` and `pt_layer_opacity.rs`; 30 s smoke per target in CI via `.github/workflows/fuzz-smoke.yml` (PR: feat/fuzz-harness-pt-tile).
- [ ] Property-based tests for RGBA16F arithmetic (Rust + `proptest`)
- [ ] Performance regression tests: tile alloc throughput baseline, blit throughput baseline

### P3 — Planned for v0.3.0+ (after Gossamer shell integration)

- [ ] UI integration tests: canvas gesture → tile mutation round-trip
- [ ] Plugin sandbox isolation tests: plugin cannot escape to Ephapax memory
- [ ] Collaboration session tests: two peers, tile mutation, CRDT merge verification

## Test Results Summary

```
Zig FFI Integration Tests:    PASS (zig build test — 29/29)
Rust Ephapax Unit Tests:      PASS (cargo test — 98/98 + 1 doctest)
Workflow Validation:          PASS (validate_workflows_test.sh)
Aspect Tests:                 PASS (7 aspects, 0 fail; 7 Idris2 imports ⊆ 23 Zig exports)
Idris2 ABI Check (CI):        WIRED (.github/workflows/idris-ci.yml; 3 modules + 3 verification modules)
Coverage Reporting (CI):      WIRED (.github/workflows/coverage.yml — Rust cargo-llvm-cov LCOV + Zig kcov best-effort; artifacts uploaded; reporting only, no gate)
Undo-graph benches:           PASS (88 ns/commit, 2 ns/checkout)
panic-attack scan:            3 weak points, all pre-existing false-positive heuristics
E2E Tests:                    PASS (`bash tests/e2e.sh` — 9 stages: zig build + zig test + cargo e2e_pipeline (2 scenarios) + 2 scenario_*.sh probes)
Fuzz Tests:                   WIRED (3 targets — pt_tile_blit / pt_tile_write_pixel / pt_layer_opacity; 30 s smoke per target in CI)
```

## Next Steps

- [x] Add fuzz harness for `pt_tile_blit` / `pt_tile_write_pixel` — 3 cargo-fuzz targets wired with 30 s CI smoke (PR #35).
- [x] Set up coverage reporting for Zig (kcov) and Rust (cargo-llvm-cov) — `.github/workflows/coverage.yml` + `tests/coverage.sh`; reporting only (no threshold). Zig side is best-effort and a follow-up may switch from kcov to Zig 0.15 native `-fprofile-instr-generate` once stable. (PR #32 + #34)
- [x] Populate E2E test with a real tile-alloc → composite_over → free flow now that compositing has landed — DONE in PR #33 (extends to Tile→composite→UndoGraph→pt_layer_*→Brush::stamp).
- [ ] Layer-model property tests (e.g. proptest for reorder commutativity)
