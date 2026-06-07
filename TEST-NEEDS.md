# TEST-NEEDS: paint-type

## CRG Grade: D — current

## Current State (Updated 2026-05-11)

| Category | Count | Details |
|----------|-------|---------|
| **Source modules** | 7 | 3 Idris2 ABI (Foreign, Layout, Types), 2 Zig FFI (build, main), 1 Zig integration test, 1 Rust Ephapax crate |
| **Unit tests** | ~12 | Zig inline tests in `src/interface/ffi/src/main.zig`; Rust unit tests in `src/ephapax/src/` |
| **Integration tests** | 1 | `src/interface/ffi/test/integration_test.zig` — lifecycle, blit, memory safety, version checks |
| **E2E tests** | 1 | `tests/e2e.sh` (scaffold); `tests/e2e/template_instantiation_test.sh` (structure validation) |
| **Aspect tests** | 1 | `tests/aspect_tests.sh` (scaffold — not yet populated with paint-type assertions) |
| **Workflow tests** | 1 | `tests/workflows/validate_workflows_test.sh` (validates CI workflow presence and structure) |
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

### Rust Ephapax Unit Tests (PASSING)

`src/ephapax/src/lib.rs` and submodules:

- Tile header construction and field access
- RGBA16F pixel arithmetic (add, multiply, clamp)
- Tile buffer allocation and deallocation
- Basic compositing: over operator, alpha premultiplication

Run with: `cargo test` from `src/ephapax/`

### Workflow Validation Tests (PASSING)

`tests/workflows/validate_workflows_test.sh`:

- Validates all expected CI workflows are present
- Checks SPDX headers on workflow files
- Verifies required `name:` field in each workflow

## What Is Missing (Priority Order)

### P1 — Required for CRG Grade C

- [ ] Aspect tests with real paint-type assertions — `tests/aspect_tests.sh` needs population
  - File I/O round-trip: create a tile, save, reload, verify bytes identical
  - Idris2 ABI proof check integrated into CI (`idris2 --check` on ABI modules)
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
Zig FFI Integration Tests:    PASS (zig build test)
Rust Ephapax Unit Tests:      PASS (cargo test)
Workflow Validation:          PASS (validate_workflows_test.sh)
Aspect Tests:                 STUB (not yet populated)
E2E Tests:                    STUB (structure test only)
Fuzz Tests:                   NOT STARTED
```

## Next Steps

- [ ] Populate `tests/aspect_tests.sh` with real paint-type assertions
- [ ] Wire `idris2 --check src/interface/Abi/*.idr` into CI
- [ ] Add fuzz harness for `pt_tile_blit`
- [ ] Set up coverage reporting for Zig (kcov) and Rust (cargo-llvm-cov)
