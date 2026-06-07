<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
<!-- Last updated: 2026-05-13 -->

# paint-type Architecture Topology

This document follows [ADR-0002](docs/decisions/0002-foundation-cross-platform.adoc) — Foundation: Universal Cross-Platform, Unified Backend/Kernel Surface. Read that first.

## System overview

paint-type is universally cross-platform from moment one. Its architecture is built around a single abstract operation surface (defined in Idris2), many concrete kernel backends (written in Zig), an application written in AffineScript, and a unified Zig-based API surface — all converging on typed-wasm for portable distribution and an OCI multi-arch container for canonical packaging.

The pattern is taken from [hyperpolymath/Axiom.jl](https://github.com/hyperpolymath/Axiom.jl): one operation surface, many backends, capability-driven dispatch, transparent fallback to a reference implementation.

## Layer overview

| Layer | Language | Purpose |
|-------|----------|---------|
| Application | AffineScript | The paint.type app proper — tools, layers, undo, sessions. Calls the abstract operation surface only. |
| Abstract operation surface | Idris2 | The `Backend` interface, capability descriptor, dispatch totality proofs, ABI layout proofs. The single source of truth for what an operation is. |
| Kernel backends | Zig | One module per backend (CpuReference, NvidiaCuda, AppleMetal, AmdRocm, Vulkan, WebGPU, NEON, AVX-512, RVV, FPGA, DSP, crypto cores, I/O, network, peripherals). Each implements the C ABI generated from Idris2. |
| Dispatcher | Zig | Runtime backend selection, hot-plug events, transparent fallback, self-healing diagnostics. |
| Unified API surface | Zig | One server, many adapters: REST, GraphQL, gRPC, SSE, Bebop. Shared schema from Idris2. |
| Portable compile target | typed-wasm | The application compiles to a typed-wasm module; backends register as typed imports verified at the module boundary. |
| Canonical distribution | OCI multi-arch container | Buildable, runnable, testable from day one. Native binaries are extracted from the container, not parallel build paths. |
| Collaboration transport | Burble (WebRTC) | One specific network backend, registered alongside the others. |
| Service discovery | Groove | mDNS/.well-known announcement; another network backend. |

## Backend pattern

A *backend* is a Zig module that:

1. Exports the operation set declared by Idris2's `Backend` interface, via the generated C ABI.
2. Declares a structured **capability descriptor**: which kernel classes (DSP, FPGA, audio, math, GPU, physics, crypto, I/O, vector, tensor) it serves, at which precisions, with which memory characteristics.
3. Registers itself with the dispatcher at runtime.
4. Hot-plug-aware: appears / disappears as the underlying capability comes and goes (GPU plugged in, USB tablet attached, network reachable).

Kernel classes are not directories. They are *capability flags on a backend*. `AppleSiliconBackend` is one module that reports `{ gpu: metal, npu: ane, vector: neon+sme, crypto: armce, audio: coreaudio }`. The dispatcher picks the best backend per operation.

`CpuReferenceBackend` is mandatory and always loaded. It is the oracle for numerical-equivalence tests of every other backend.

## Data flow

```
[User gesture / canvas event / network message / plugin call]
        ↓
[Unified API surface — REST / GraphQL / gRPC / SSE / Bebop adapter]
        ↓
[AffineScript application — algebraic-effect-typed call to the abstract operation surface]
        ↓
[Dispatcher (Zig) — capability lookup, backend selection, optional fallback]
        ↓
[Concrete backend (Zig) — CpuReference / NvidiaCuda / AppleMetal / AmdRocm / Vulkan / WebGPU / FPGA / DSP / Crypto / IO / Net / Peripheral]
        ↓
[Hardware — CPU+vector / VRAM+compute / NPU / FPGA fabric / audio DSP / printer queue / network socket / display surface]
```

Collaboration path (a specific network backend):

```
[Local canvas mutation]
        ↓
[Operation surface call (Idris2-typed)]
        ↓
[Burble WebRTC backend — CRDT-compatible tile merge]
        ↓
[Remote peers, discovered via Groove (mDNS / .well-known)]
```

## Directory structure

```
paint-type/
├── src/
│   ├── paint_core/       # Rust image core crate
│   ├── interface/
│   │   ├── Abi/          # Idris2 ABI definitions (Types, Layout, Foreign)
│   │   └── ffi/          # Zig FFI implementation and tests
│   ├── aspects/          # Cross-cutting concerns (integrity, observability, security)
│   ├── bridges/          # AffineScript → typed-wasm bridge (draft .twasm)
│   ├── contracts/        # API contracts
│   ├── core/             # Core abstractions (placeholder)
│   ├── definitions/      # Shared type definitions
│   └── errors/           # Error taxonomy
├── docs/                 # Human-readable documentation
├── .machine_readable/    # Machine-readable metadata (STATE, META, contractiles)
├── .github/              # GitHub Actions workflows, issue templates
├── container/            # Container build definitions (Stapeln)
└── verification/         # Formal proofs (Agda, Coq, Lean4, TLA+)
```

## Integration points

- **Build tools**: Zig 0.15+, Idris2, AffineScript, typed-wasm toolchain. Rust toolchain present for the legacy `src/ephapax/` only.
- **Container**: OCI buildx multi-arch (linux/amd64, linux/arm64, linux/arm/v7, linux/riscv64, linux/ppc64le); native artifacts extracted from container builds.
- **Hardware optional dependencies**: CUDA, ROCm, Metal, Vulkan, WebGPU runtime, FPGA vendor toolchains, OS audio servers. All conditional — present-and-loaded or absent-and-fallback.
- **Collaboration**: Burble (WebRTC) and Groove (service discovery) — separate hyperpolymath repos; registered as the `net/webrtc` and `net/mdns` backends respectively.
- **CI / governance**: GitHub Actions → Hypatia neurosymbolic scan → eclexiaiser energy scoring → mirror.

## Deployment

- **Canonical**: OCI multi-arch container, addressed by digest, built and published per CI run.
- **Native**: extracted from a container build for the target `(os, arch)`. Not a separate build system.
- **Web**: typed-wasm module + browser-side backends (WebGPU, WebGL2, WebTransport, WebRTC, Wasm SIMD128).
- **Headless / batch**: same container, no display backend loaded.

## Key invariants

- All cross-language boundaries go through the Idris2-defined operation surface.
- `CpuReferenceBackend` is the numerical oracle. Every other backend's output is verified against it for every operation.
- A backend may declare itself unavailable on a target. **No top-level decision is permitted to declare a target unsupported.**
- Adding a kernel class never restructures the source tree; it adds a capability flag on existing backends and (optionally) new concrete backends.
- The application layer (AffineScript) does not call into any specific backend. It calls the abstract operation surface; the dispatcher routes.

## Legacy notes

The `src/interface/Abi/` Idris2 module and `src/interface/ffi/` Zig FFI were authored before ADR-0002. They define a single tile primitive end-to-end. Under ADR-0002 they are subsumed by:

- The abstract operation surface in `src/backends/Abstract.idr` (which the existing `Abi/` material informs).
- One concrete backend's tile-allocation kernel in `src/backends/cpu/` (which the existing `ffi/` material informs).

They remain in tree as a worked example and will be migrated, not deleted, as the v0.1.0 foundation milestones land.

The `src/ephapax/` Rust crate is similarly retained — it is a useful reference Rust client of the C ABI and a candidate component of one specific backend, not the project's main code path.
