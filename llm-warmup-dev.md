# LLM Warmup — paint-type (Developer)

## What is paint-type?

paint-type is a cross-platform open-source image editor in the spirit of Paint.NET —
capable enough for real work, simple enough to reach for without thinking.

Status: early development. The tile primitive, Idris2 ABI bridge, Zig FFI, and Rust
Ephapax skeleton are all in place. No user-visible functionality yet.

## Architecture (summary)

- **Ephapax** — Rust image core, RGBA16F tiles, linear types
- **Abi** — Idris2 formally-verified ABI (Types, Layout, Foreign)
- **ffi** — Zig libpt C ABI bridge
- **AffineScript bridge** — typed-wasm bindings (stub, v0.2.0)
- **Gossamer shell** — linearly-typed webview desktop shell (v0.3.0)
- **Burble + Groove** — WebRTC collaboration + service discovery (v0.5.0)

## Key Commands

- `zig build test` from `src/interface/ffi/` — build and run Zig FFI tests
- `cargo test` from `src/ephapax/` — build and run Rust Ephapax tests
- `just build` — build everything
- `just test` — run all tests
- `just doctor` — diagnose issues
- `just lint` — lint and format
- `just panic-scan` — security scan

## What Has Already Been Done (Do Not Redo)

- `src/interface/Abi/Types.idr` — Idris2 ABI types
- `src/interface/Abi/Layout.idr` — Idris2 layout proofs
- `src/interface/Abi/Foreign.idr` — Idris2 FFI wrappers
- `src/interface/ffi/src/main.zig` — Zig libpt implementation
- `src/interface/ffi/build.zig` — Zig build file
- `src/interface/ffi/test/integration_test.zig` — integration tests
- `src/ephapax/` — Rust crate skeleton

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
