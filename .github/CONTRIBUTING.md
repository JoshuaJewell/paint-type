<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# Contributing to paint-type

Thank you for contributing to paint-type! This file covers how to set up a development
environment, submit changes, and navigate the codebase.

---

## Quick Setup

```bash
# Clone the repository
git clone https://github.com/JoshuaJewell/paint-type.git
cd paint-type

# Using Guix (preferred)
guix shell

# Or using Nix (fallback)
nix develop

# Verify setup
just doctor
just test
```

### Zig FFI (requires Zig 0.15+)

```bash
cd src/interface/ffi
zig build test
```

### Rust Ephapax (requires Rust stable)

```bash
cd src/ephapax
cargo test
```

### Repository Structure

```
paint-type/
├── src/
│   ├── ephapax/          # Rust image core (RGBA16F tiles, compositing)
│   ├── interface/
│   │   ├── Abi/          # Idris2 ABI definitions (Perimeter 1 — formally verified)
│   │   └── ffi/          # Zig FFI bridge (Perimeter 1 — C ABI)
│   ├── bridges/          # AffineScript → typed-wasm bridge stubs
│   └── aspects/          # Cross-cutting: integrity, observability, security
├── docs/                 # Documentation (Perimeter 3)
│   └── architecture/     # ADRs, specs (Perimeter 2)
├── tests/                # Test suite (Perimeter 2-3)
├── verification/         # Formal proofs: Idris2, Lean4, Agda, Coq, TLA+ (Perimeter 1)
├── .machine_readable/    # Machine-readable content (Perimeter 1)
│   ├── *.a2ml            # State files (STATE, META, ECOSYSTEM, etc.)
│   ├── bot_directives/   # Bot configs
│   └── contractiles/     # Policy contracts (k9, dust, lust, must, trust)
├── .well-known/          # Protocol files (Perimeter 1-3)
├── .github/              # GitHub config (Perimeter 1)
├── CHANGELOG.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md       # This file
├── LICENSE
├── README.adoc
├── SECURITY.md
├── flake.nix             # Nix flake — fallback (Perimeter 1)
├── guix.scm              # Guix package — primary (Perimeter 1)
└── Justfile              # Task runner (Perimeter 1)
```

---

## How to Contribute

### Reporting Bugs

**Before reporting**:
1. Search existing issues
2. Check if it's already fixed in `main`
3. Determine which perimeter the bug affects

**When reporting**:

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.yml) and include:

- Clear, descriptive title
- Environment details (OS, versions, toolchain)
- Steps to reproduce
- Expected vs actual behaviour
- Logs, screenshots, or minimal reproduction

### Suggesting Features

**Before suggesting**:
1. Check the [roadmap](../ROADMAP.adoc)
2. Search existing issues and discussions
3. Consider which perimeter the feature belongs to

**When suggesting**:

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.yml) and include:

- Problem statement (what pain point does this solve?)
- Proposed solution
- Alternatives considered
- Which perimeter this affects

### Your First Contribution

Look for issues labelled:

- [`good first issue`](https://github.com/JoshuaJewell/paint-type/labels/good%20first%20issue) — Simple Perimeter 3 tasks
- [`help wanted`](https://github.com/JoshuaJewell/paint-type/labels/help%20wanted) — Community help needed
- [`documentation`](https://github.com/JoshuaJewell/paint-type/labels/documentation) — Docs improvements

---

## Development Workflow

### Branch Naming

```
docs/short-description       # Documentation (P3)
test/what-added              # Test additions (P3)
feat/short-description       # New features (P2)
fix/issue-number-description # Bug fixes (P2)
refactor/what-changed        # Code improvements (P2)
security/what-fixed          # Security fixes (P1-2)
```

### Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `ci`, `chore`

### Before Submitting a PR

```bash
just lint       # Format and lint
just test       # All tests must pass
just panic-scan # No new security issues
```

### Key Invariants (Read Before Touching Core Code)

- All cross-language boundaries go through the Idris2 ABI + Zig FFI — no shortcuts
- Tile memory is linearly typed — no aliased mutable tile references
- `believe_me` count must remain zero in all Idris2 files
- SPDX-License-Identifier header required on every new file
- No new TypeScript or Python files

---

## Contact

- Issue tracker: https://github.com/JoshuaJewell/paint-type/issues
- Security issues: paint-type@pm.me (see SECURITY.md)
