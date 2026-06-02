# Pareto Surface Reduction: Design

Date: 2026-05-31
Author: Joshua Jewell (with Claude Code)
Status: Draft, awaiting review

## Purpose

Bring the paint-type repository to a Pareto-optimal code surface. We hold
delivered capability fixed and minimise three costs:

1. Build / toolchain footprint
2. Security / supply-chain surface
3. Maintenance / cognitive load

The target state is the Pareto frontier: every remaining element earns its keep,
so that any further removal would be a genuine tradeoff rather than a free win.
Everything that is dominated (redundant, non-functional, or false-signalling) is
removed; the frontier is left intact.

## Frontier decisions (held fixed)

These were settled deliberately and are NOT in scope for reduction:

- The four-language proof-carrying stack stays whole: Rust, Zig, Idris2, and the
  planned typed-wasm / AffineScript bridge. Zig keeps its standalone C ABI
  boundary; all three Idris2 modules remain; the verification roadmap and its
  proof scaffolds (Agda, Lean4, Coq, TLA+) are retained as the seed of the
  twelve outstanding proofs.
- The hyperpolymath / palimpsest governance apparatus stays as ecosystem
  membership: per-directory a2ml manifests, contractile, k9, dogfood-gate, the
  bot directives, well-known conformance, and multi-forge mirroring.

The work below optimises strictly AROUND this fixed frontier.

## What actually delivers capability today

A single 64x64 RGBA16F tile primitive with four operations (alloc, free, fill,
read_pixel), spread across roughly 1,470 lines: Rust owns the f16 maths and the
linear-ownership wrapper; Zig implements the C ABI with bounds checks; Idris2
contributes one non-trivial theorem, tileLayoutValid in Layout.idr. All cost is
measured against this core.

## Scope of change

### A. Unconditional removals (free wins, no tradeoff)

| Target | Reason | Note |
| --- | --- | --- |
| flake.nix | Nix is deprecated for this project; Guix is the chosen environment | guix.scm and .guix-channel stay; confirm guix-nix-policy.yml passes on Guix alone |
| eclexiaiser.toml | Does not belong in this repository | Must also remove the eclexiaiser-manifest check from dogfood-gate.yml, or that kept gate will fail |
| Containerfile (root) | Exact duplicate of container/Containerfile | All recipes already use container/Containerfile |
| .machine_readable/6a2/STATE.a2ml | Duplicates parent .machine_readable/STATE.a2ml in a second syntax | Keep 6a2/AGENTIC, NEUROSYM, PLAYBOOK (unique) |
| .machine_readable/6a2/META.a2ml | Duplicates parent META.a2ml | as above |
| .machine_readable/6a2/ECOSYSTEM.a2ml | Duplicates parent ECOSYSTEM.a2ml | as above |
| .github/workflows/codeql.yml | Scans JavaScript / TypeScript, which the repo bans; a template default, not ecosystem membership | Removes two external actions and one weekly scheduled run |
| .github/workflows/scorecard-enforcer.yml | Re-runs the same ossf/scorecard-action as scorecard.yml | Fold any unique doc-gate logic into scorecard.yml |

### B. Status consolidation (collapse hand-synced duplication)

Project status (completion percentage, CRG grade, milestone state) is currently
restated in four places that must be hand-kept consistent:
.machine_readable/STATE.a2ml, READINESS.md, ROADMAP.adoc, and the README.adoc
badge.

Make STATE.a2ml the single canonical source of the mutable figures. READINESS.md,
ROADMAP.adoc, and README.adoc keep their prose and structure but cite STATE.a2ml
rather than restating the numbers, so a status change touches one file.

### C. Make honest (keep membership, remove false signal)

These are dormant ecosystem tooling kept by choice; the fix removes the false
assurance, not the file.

| Target | Change |
| --- | --- |
| .github/workflows/hypatia-scan.yml | Verify whether it fabricates findings or stub output when Hypatia is absent; if so, make it skip cleanly and report "pending" rather than emit results that read as a completed scan. If it already submits real findings, leave it |
| .github/workflows/static-analysis-gate.yml | Same treatment: when the panic-attack / Patch Bridge binaries are unavailable, skip honestly instead of writing stub JSON |
| .github/workflows/release.yml | Mark clearly as PENDING and guard it so its largely-commented body does not read as an active release pipeline |

### D. Stub pruning (recommended, awaiting confirmation)

The 67 one-line README.adoc stubs (each just a pillar title, e.g. "= src Pillar")
are required by neither validate-template.sh nor dogfood-gate.yml. They add search
noise and directory clutter for zero unique information. Recommendation: remove
them. Flagged separately because they are an RSR convention you may wish to keep
for structural signposting even when empty.

### E. Consistency fix (no deletion)

verification proof docs (PROOF-NEEDS.md, PROOF-STATUS.md) reference scaffold
filenames that do not exist (Compositing.agda, TileCRDT.agda, UndoGraph.lean,
PluginSandbox.tla, BurbleSession.tla, PluginConfinement.lean) while the actual
scaffolds carry different names (Properties.agda, ApiTypes.lean, TypeSafety.v,
StateMachine.tla). Reconcile the docs to the files, or rename the files to the
documented plan. No proof content is added or removed.

## Out of scope

- No language is removed (Dials A and B: keep).
- No governance, mirroring, or well-known apparatus is removed (Dial C: keep).
- No new features, proofs, or product code.
- guix.scm and .guix-channel are retained despite stubbed build phases; honesty
  fixes there are optional and not part of this change.

## Verification

After each removal, the build and the kept gates must still pass:

- cargo test from src/paint_core (links libpt via build.rs)
- zig build test from src/interface/ffi
- idris2 type-check of the ABI modules (proof-check-idris2)
- scripts/validate-template.sh exits clean (the deletions touch no file on its
  required list)
- the kept workflows parse (workflow-linter.yml) and dogfood-gate.yml passes,
  with the eclexiaiser check removed in lockstep with eclexiaiser.toml

A change is complete only when these are green; evidence before assertion.

## Expected impact

- Toolchain footprint: removes a deprecated Nix backend and a foreign tool config.
- Supply-chain surface: removes codeql (two external actions, one scheduled run)
  and a duplicate scorecard workflow; ends fabricated scan output from two more.
- Maintenance load: removes three duplicate manifests, an exact-duplicate
  Containerfile, the four-way status duplication, and (pending confirmation) 67
  empty README stubs.

The frontier (four languages, full governance) is untouched, so by construction
any further reduction from this state is a genuine tradeoff.

## Sequencing

The removals are independent and low-risk; group them into one focused branch
with a verification pass at the end. A detailed step ordering is deferred to the
implementation plan.
