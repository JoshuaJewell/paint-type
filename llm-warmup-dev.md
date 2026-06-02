# LLM Warmup — paint-type (Developer)

## What is paint-type?

paint-type is a cross-platform open-source image editor in the spirit of Paint.NET —
capable enough for real work, simple enough to reach for without thinking.

Status (2026-06-01): pre-alpha — v0.2.0 Core Image Operations closing. Tile
primitive, Idris2 ABI bridge, Zig FFI (23 exports), and the Rust Ephapax
crate are all in place. v0.2.0 in-repo work complete: 11 compositing ops,
persistent UndoGraph, Layer/LayerStack, brush engine (BrushTip + Brush::stamp
+ Stroke), pt_layer_* FFI, ABI category fully proven. Rust CI green on main.
Only remaining v0.2.0 box: AffineScript → typed-wasm bridge (DRAFT `.twasm`
schemas at `src/bridges/`; compilation gated on hyperpolymath/typed-wasm#127
+ #130, tracked in paint-type#39). No user-visible application yet — that is
v0.3.0 with the Gossamer shell.

## Architecture (summary)

- **Ephapax** — Rust image core, RGBA16F tiles, linear types — 5 modules
  (lib, composite, undo, layer, brush); 11 compositing ops; persistent
  UndoGraph; Layer/LayerStack; Brush engine
- **Abi** — Idris2 formally-verified ABI (Types, Layout, Foreign) — fully
  proven (ABI-1..5 + TP-1/TP-3 done)
- **ffi** — Zig libpt C ABI bridge — 23 exports (pt_tile_* + pt_layer_* + slot helpers)
- **AffineScript bridge** — typed-wasm bindings; DRAFT `.twasm` schemas at
  `src/bridges/paint-type-{tile,layer}.twasm`; compilation gated on
  hyperpolymath/typed-wasm#127 + #130, tracked in paint-type#39
- **Gossamer shell** — linearly-typed webview desktop shell (v0.3.0)
- **Burble + Groove** — WebRTC collaboration + service discovery (v0.5.0)

## Key Commands

- `zig build test` from `src/interface/ffi/` — build and run Zig FFI tests
- `cargo test` from `src/paint_core/` — build and run Rust Ephapax tests
- `just build` — build everything
- `just test` — run all tests
- `just doctor` — diagnose issues
- `just lint` — lint and format
- `just panic-scan` — security scan

## What Has Already Been Done (Do Not Redo)

- `src/interface/Abi/Types.idr` — Idris2 ABI types
- `src/interface/Abi/Layout.idr` — Idris2 layout proofs
- `src/interface/Abi/Foreign.idr` — Idris2 FFI wrappers
- `verification/proofs/idris2/ABI/{Platform,Compliance}.idr` + `Pixel.idr` —
  ABI-3, ABI-5, TP-3 proofs (CI-checked)
- `src/interface/ffi/src/main.zig` — Zig libpt (23 exports)
- `src/interface/ffi/build.zig` — Zig build file
- `src/interface/ffi/test/integration_test.zig` — 29/29 integration tests
- `src/paint_core/src/{lib,composite,undo,layer,brush}.rs` — full v0.2.0
  in-repo image core; cargo test 98/98 + 1 doctest
- `src/bridges/paint-type-{tile,layer}.twasm` — DRAFT typed-wasm schemas
- `tests/aspect_tests.sh` — 7 aspects PASS
- `tests/e2e.sh` + `src/paint_core/tests/e2e_pipeline.rs` — E2E pipeline (PR #33)
- `src/paint_core/fuzz/` — 3 cargo-fuzz targets (PR #35)
- `.github/workflows/{rust,coverage,e2e,fuzz-smoke,idris-ci}.yml` — green CI

## Key Invariants

- All cross-language boundaries go through the Idris2 ABI + Zig FFI
- Tile memory is linearly typed — no aliased mutable tile references
- No new TypeScript, Python, or Go files
- SPDX-License-Identifier on every source file
- No `believe_me`, `assert_total`, `Admitted`, `sorry` in proof files

## Quick Context

- License: PMPL-1.0-or-later
- Owner: Joshua Jewell (JoshuaJewell)
- Part of hyperpolymath/palimpsest ecosystem
- Contact: paint-type@pm.me
- See `EXPLAINME.adoc` for full directory structure guide
- See `TOPOLOGY.md` for architecture topology
- See `ROADMAP.adoc` for milestone plan
- Read `0-AI-MANIFEST.a2ml` and `.machine_readable/MUST.contractile` before making changes
