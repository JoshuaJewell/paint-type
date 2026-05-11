<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Last updated: 2026-05-11 -->

# paint-type Architecture Topology

## System Overview

paint-type is a cross-platform open-source image editor in the spirit of Paint.NET —
capable enough for real work, simple enough to reach for without thinking.

The system has four distinct tiers: a native image core (Ephapax), a formally-verified
ABI bridge (Idris2/Zig), a linearly-typed desktop shell (Gossamer), and a collaboration
layer (Burble + Groove).

## Component Overview

| Component | Language | Purpose |
|-----------|----------|---------|
| Ephapax | Rust (linear types) | Native image core — RGBA16F tile compositing, brush engine, undo graph |
| Abi | Idris2 | Formally verified ABI definitions — tile layout proofs, FFI type safety |
| ffi | Zig | C ABI bridge — zero-cost bindings between Ephapax and the web layer |
| AffineScript bridge | AffineScript → typed-wasm | High-level API surface for UI and plugins |
| Gossamer shell | Linearly-typed webview | Desktop shell hosting the web UI |
| Web UI | HTML/CSS/JS (in Gossamer) | Layer panel, tool bar, canvas viewport |
| Plugin sandbox | typed-wasm | Isolated WASM environment for third-party plugins |
| Burble | WebRTC (Rust) | Sub-10ms real-time collaboration layer |
| Groove | Service discovery | `.well-known/groove/` peer announcement for collaborative sessions |

## Data Flow

```
[User gesture / canvas event]
        ↓
[Gossamer shell — linearly-typed webview]
        ↓
[Web UI — layer panel, tool bar, canvas viewport]
        ↓
[AffineScript → typed-wasm bridge]
        ↓
[Zig FFI (libpt C ABI)]
        ↓
[Ephapax — RGBA16F tile engine (Rust)]
        ↓
[VRAM / system memory — 64×64 RGBA16F tile pool]
```

Collaboration path:

```
[Local canvas mutation]
        ↓
[Burble WebRTC session (CRDT tile merge)]
        ↓
[Remote peers via Groove service discovery]
```

## Directory Structure

```
paint-type/
├── src/
│   ├── ephapax/          # Rust image core crate
│   ├── interface/
│   │   ├── Abi/          # Idris2 ABI definitions (Types, Layout, Foreign)
│   │   └── ffi/          # Zig FFI implementation and tests
│   ├── aspects/          # Cross-cutting concerns (integrity, observability, security)
│   ├── bridges/          # AffineScript → typed-wasm bridge stubs
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

## Integration Points

- **Upstream build tools**: Zig 0.15+, Rust stable, Idris2 (for ABI proofs)
- **Desktop shell**: Gossamer (linearly-typed webview, separate repo)
- **Collaboration**: Burble WebRTC (separate repo), Groove service discovery
- **Plugin ecosystem**: typed-wasm sandbox, cerro-torre package signing
- **CI/CD**: GitHub Actions → Hypatia neurosymbolic scan → eclexiaiser energy scoring → mirror

## Deployment

- Native binary: built by Gossamer embedding Ephapax via the Zig FFI bridge
- Container: Stapeln Six ecosystem (Chainguard Wolfi base, signed with ML-DSA-87)
- Service discovery: Groove protocol (`.well-known/groove/manifest.json`)

## Key Invariants

- All cross-language boundaries go through the Idris2 ABI definitions and Zig FFI — no direct Rust↔JS calls
- Tile memory is linearly typed — no aliased mutable references to tile data
- Plugin code never touches Ephapax directly — always through the typed-wasm API surface
- Collaboration state merges are CRDT-compatible — no last-write-wins for tile data
