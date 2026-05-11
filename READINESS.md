<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Last updated: 2026-05-11 -->

# paint-type Component Readiness Assessment

**Standard:** [Component Readiness Grades (CRG) v2.2](https://github.com/hyperpolymath/standards/tree/main/component-readiness-grades)
**Current Grade:** D
**Assessed:** 2026-05-11
**Assessor:** Joshua Jewell

---

## Summary

| Component           | Grade | Release Stage | Evidence Summary                                          |
|---------------------|-------|---------------|-----------------------------------------------------------|
| Idris2 ABI (Types, Layout, Foreign) | D | Pre-alpha | Compiles, proofs typecheck, no external consumers yet |
| Zig FFI (libpt)     | D     | Pre-alpha     | Integration tests pass; no external consumers             |
| Ephapax (Rust core) | D     | Pre-alpha     | Crate skeleton; tile primitive defined; not feature-complete |
| AffineScript bridge | D     | Pre-alpha     | Stubs only; bridge not yet generated                      |
| Gossamer shell integration | D | Pre-alpha  | Not started; architecture specified                       |
| Burble / Groove     | D     | Pre-alpha     | Not started; architecture specified                       |

**Overall:** Grade D — RSR-compliant structure in place; CI passing; first real code landed (tile primitive and ABI bridge). No feature-complete functionality yet.

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
1. Complete Ephapax brush engine and tile compositing (v0.2.0 milestone)
2. Generate AffineScript → typed-wasm bridge from Idris2 ABI
3. Integrate with Gossamer shell for a runnable application
4. Wire integration tests into CI
5. Update this file with evidence

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
