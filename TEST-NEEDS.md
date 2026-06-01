# TEST-NEEDS: paint-type

## CRG Grade: D — current

## Current State (Updated 2026-06-01)

| Category | Count | Details |
|----------|-------|---------|
| **Source modules** | 10 | 3 Idris2 ABI (Foreign, Layout, Types) + 3 verification proof modules (ABI/Platform, ABI/Compliance, Pixel), 2 Zig FFI (build, main), 1 Zig integration test, 1 Rust Ephapax crate with 4 modules (lib, composite, undo, layer) |
| **Unit tests** | 56 + 18 | 56 Rust unit tests across lib/composite/undo/layer; 18 Zig inline + integration tests |
| **Integration tests** | 1 | `src/interface/ffi/test/integration_test.zig` — lifecycle, blit, memory safety, version checks |
| **E2E tests** | 1 | `tests/e2e.sh` (scaffold); `tests/e2e/template_instantiation_test.sh` (structure validation) |
| **Aspect tests** | 1 | `tests/aspect_tests.sh` — 7 aspects, 0 fail (SPDX, dangerous-pattern, ABI/FFI contract, Rust panic-safety, RGBA16F constants, Idris2 ABI check, file-I/O deferred) |
| **Workflow tests** | 1 | `tests/workflows/validate_workflows_test.sh` (validates CI workflow presence and structure) |
| **Bench harnesses** | 1 | `src/ephapax/benches/undo.rs` — 88 ns/commit, 2 ns/checkout (hand-rolled `Instant` timer) |
| **Fuzz tests** | 0 | `tests/fuzz/README.adoc` scaffold; harness not yet wired |

## What Exists and Passes

### Zig FFI Integration Tests (PASSING)

`src/interface/ffi/test/integration_test.zig`:

- Tile lifecycle tests: `pt_tile_alloc` → `pt_tile_free` round-trip
- Blit operation tests: src → dst tile copy, bounds checking
- Memory safety tests: double-free detection, null pointer handling
- Version checks: `pt_version()` returns expected semver string
- Threading: concurrent alloc/free stress test scaffold

Run with: `zig build test` from `src/interface/ffi/`

### Rust Ephapax Unit Tests (PASSING — 56/56 + 1 doctest)

`src/ephapax/src/{lib,composite,undo,layer}.rs`:

- `lib.rs` — Tile header construction, RGBA16F arithmetic (add, multiply, clamp),
  tile buffer allocation/deallocation, f16↔f32 round-trip, `pt_tile_write_pixel`.
- `composite.rs` — Porter-Duff `over_premultiplied` / `over_unpremultiplied`,
  `masked_blend`, `flatten_layer_stack`, `Tile::composite_over`.
- `undo.rs` — `UndoGraph<T>` commit / branch / checkout / parent_of / children_of
  / is_ancestor / monotonic-RevId invariant.
- `layer.rs` — `Layer`, `LayerStack`, `LayerId`, push/delete/reorder_to/get/
  iter/flatten; stable IDs across reorderings.

Run with: `cargo test` from `src/ephapax/`. Benches via `cargo bench`.

### Workflow Validation Tests (PASSING)

`tests/workflows/validate_workflows_test.sh`:

- Validates all expected CI workflows are present
- Checks SPDX headers on workflow files
- Verifies required `name:` field in each workflow

## What Is Missing (Priority Order)

### P1 — Required for CRG Grade C

- [x] Aspect tests populated — `tests/aspect_tests.sh` covers 7 aspects (SPDX, dangerous-pattern, ABI/FFI contract, Rust panic-safety, RGBA16F constants, Idris2 ABI check, file-I/O deferred). PR #9 (2026-06-01).
- [x] Idris2 ABI proof check integrated into CI — `.github/workflows/idris-ci.yml`. PR #8 (2026-06-01). Verified modules: `src/interface/Abi/{Types,Layout,Foreign}.idr` + `verification/proofs/idris2/{ABI/Platform.idr, Pixel.idr}`.
- [ ] File I/O round-trip aspect — deferred to v0.3.0 (native RGBA16F save/load surface needed first).
- [ ] E2E test: end-to-end tile alloc → composite → free pipeline via the Zig FFI
- [ ] Coverage reporting wired into CI for both Zig and Rust

### P2 — Required for CRG Grade B

- [ ] Fuzz harness for `pt_tile_blit` (inputs: arbitrary src/dst dimensions, offsets)
- [ ] Property-based tests for RGBA16F arithmetic (Rust + `proptest`)
- [ ] Performance regression tests: tile alloc throughput baseline, blit throughput baseline

### P3 — Planned for v0.3.0+ (after Gossamer shell integration)

- [ ] UI integration tests: canvas gesture → tile mutation round-trip
- [ ] Plugin sandbox isolation tests: plugin cannot escape to Ephapax memory
- [ ] Collaboration session tests: two peers, tile mutation, CRDT merge verification

## Test Results Summary

```
Zig FFI Integration Tests:    PASS (zig build test — 18/18)
Rust Ephapax Unit Tests:      PASS (cargo test — 56/56 + 1 doctest)
Workflow Validation:          PASS (validate_workflows_test.sh)
Aspect Tests:                 PASS (7 aspects, 0 fail)
Idris2 ABI Check (CI):        WIRED (.github/workflows/idris-ci.yml; 3 modules + 3 verification modules)
Undo-graph benches:           PASS (88 ns/commit, 2 ns/checkout)
panic-attack scan:            3 weak points, all pre-existing false-positive heuristics
E2E Tests:                    STUB (compositing primitive E2E available now via Tile::composite_over)
Fuzz Tests:                   NOT STARTED
```

## Next Steps

- [ ] Add fuzz harness for `pt_tile_blit` / `pt_tile_write_pixel` (TEST-NEEDS P2)
- [ ] Set up coverage reporting for Zig (kcov) and Rust (cargo-llvm-cov) (TEST-NEEDS P2)
- [ ] Populate E2E test with a real tile-alloc → composite_over → free flow now that compositing has landed (PR #20/#21)
- [ ] Layer-model property tests (e.g. proptest for reorder commutativity)
