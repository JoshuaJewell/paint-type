# Security Review — CPU reference backend, FFI stroke ABI, and CI

**Date:** 2026-06-15
**Scope:** `src/backends/cpu/main.zig`, `src/backends/dispatcher.zig`, the
`pt_tool_stroke_*` C ABI, GitHub Actions workflows, shell/container setup, the
network connectors / API layer, and the new `www/` static site.
**Branch:** `fix/security-hardening`
**Status:** HIGH items fixed in-branch; MEDIUM/LOW triaged below.

This review complements the two earlier audits, which it does **not** contradict:

- `audit-ffi-unsafe.md` — covers the *tile-level* FFI in
  `src/interface/ffi/src/main.zig`; that layer's bounds/magic-word checks remain
  legitimate. The findings here are in the **CPU backend** (`backends/cpu`) and
  **dispatcher**, which the earlier audit did not cover.
- `audit-unbounded-allocation.md` — covers `src/host/src/main.rs` (UI file read,
  correctly bounded). Unrelated to the canvas-dimension allocation path below.

The connectors (`src/interface/ffi/src/connectors/*.zig`), `src/api/**`, and
`verisimdb.zig` transport are currently 15-line stubs with no live parsing, so
they carry no exploitable surface yet — but they also inherit no input
validation. The Rust render/composite/codec path (`render.rs`, `codec.rs`,
`dispatch.rs`) is solid (saturating casts, `MAX_DIM`-bounded decode).

---

## HIGH — fixed

### H1. `@intFromFloat` on untrusted caller floats → illegal behaviour / UB
`src/backends/cpu/main.zig` — pencil stroke, `stampBrush` bbox, brush
stamp-count, and `quantizeU8`.

`@intFromFloat` is illegal behaviour for NaN, ±Inf, or out-of-range values: a
safety-check panic in Debug (DoS) and **undefined behaviour in ReleaseFast**
(the build supports `ReleaseFast`/`ReleaseSmall`). Stroke coordinates, brush
geometry, and colour channels are caller-supplied `f64`/`f32` across the FFI.
Only `px < 0` was checked before the cast — which is *false* for NaN, so NaN
flowed straight through.

**Fix (commit `b32442d`):** added `finiteFloorU32` / `finiteToI64Clamped`
guards, a NaN guard in `quantizeU8`, and a `MAX_STROKE_STAMPS` cap on the
per-segment stamp loop so far-apart points can't drive an unbounded loop.

### H2. Unbounded canvas dimensions → integer-overflow heap overflow / alloc-DoS
`src/backends/cpu/main.zig` — `cpu_canvas_new`, `cpu_canvas_resize`.

`width`/`height` arrived as raw `u32` with no cap and fed `width*height*4`
(`cpu_io_save`) and the PNG encoder's `(row_bytes+1)*height`. On a 32-bit target
those products overflow `usize`, yielding a buffer too small for the full-size
write that follows — a heap overflow. On any target, unbounded dimensions are an
allocation-DoS.

**Fix (commit `b32442d`):** clamp to `MAX_CANVAS_DIM = 16384` (mirrors the Rust
codec's `MAX_DIM`) at both entry points; reject zero/over-large dimensions with
`invalid_param`.

### H3. GitHub Actions script injection + `workflow_run` trust in `rhodibot.yml`
`.github/workflows/rhodibot.yml`.

The "Create PR with fixes" step interpolated `${{ steps.fix.outputs.FIXES /
ISSUES / DANGEROUS }}` directly into a `run:` shell. Those outputs embed repo
*filenames* matched by globs (`*-STATUS-*.md`, etc.); a committed file whose name
contains `$(...)` or backticks would execute as a command in a job holding
`contents: write` + `pull-requests: write`. The job also triggers on
`workflow_run` with no same-repo gate.

**Fix (commit `b32442d`):** pass outputs via `env:` and emit with `printf '%s'`
(inert data); add a job-level `if:` so the `workflow_run` path only runs on this
repo's own successful runs, never a fork's.

### H4. Stroke FFI took `point_count` with no buffer length → out-of-bounds read
`pt_tool_stroke_{pencil,brush,eraser}` (dispatcher + CPU backend).

The ABI trusted a caller `n` (`point_count`) with no companion buffer length, so
an `n` larger than the real `points` buffer was an out-of-bounds read the
backend could not detect.

**Fix (commit `b4bb6be`, BREAKING ABI):** added a `points_len: usize` parameter
(element count of the `points` buffer) after `points` in the vtable types, the
export wrappers, the CPU impls, and the three example demos. Pencil validates
`2*n <= points_len` (checked multiply); brush validates `n <= points_len`. No
in-tree Rust callers exist; the Idris `Abstract` spec lists op names only.

**Verification:** `zig build test` and `zig build demo/brush/undo` all pass.

---

## MEDIUM — triaged

| ID | Issue | Disposition |
|----|-------|-------------|
| M1 | `trufflehog@main` unpinned; `hypatia.git` / `gitbot-fleet.git` cloned with no ref and executed in CI | **Pinned to SHAs** in this branch |
| M2 | `pt_io_save(path)` / Rust `save_png(path)` write to a fully caller-controlled path with no validation | Documented as trusted-local-caller precondition; empty-path guard added. **Full sandboxing intentionally deferred** — hard-restricting paths would break the desktop app's legitimate "Save As anywhere"; the sandbox belongs at the (future) network-facing dispatch boundary, not the local FFI |
| M3 | `Containerfile` / `.devcontainer/Containerfile` ship placeholder digests (`sha256:abc123…`) that look real but are invalid | Placeholder made explicitly invalid + commented; real digests to be pinned when the (currently all-`TODO`) build is completed |
| M4 | Other unpinned actions: `host.yml` (`checkout@v4`, `setup-zig@v2`, `rust-toolchain@stable`), `coverage.yml` (`taiki-e/install-action@v2`, `codecov-action@v4`), `verify-manifests.yml` | **Follow-up** — left for a deliberate pinning pass (pinning toolchain actions can be disruptive); listed here so it isn't lost |
| M5 | No mutex on global `global_registry` / canvas `State` behind a multi-backend C ABI — data race if ever called concurrently | **Follow-up** — enforce single-threaded use at the ABI boundary or add a mutex before any concurrent host wires in |
| M6 | `mirror.yml` writes `RADICLE_KEY` via `echo` then `chmod 600` (brief world-readable window); push-only trigger limits exposure | **Follow-up** — write with `umask 077` / `install -m600` |

## LOW — noted

- `www/` static site ships no CSP / security headers and depends on an unpinned
  `casket-ssg`; pin the SSG and add a CSP `<meta>` + host headers.
- `.pre-commit-config.yaml` has a broken/truncated secret-detection stanza
  (missing `repo:`) — the local secret hook does not run.
- Predictable `$$` temp paths in `hypatia-scan.yml` and
  `tests/e2e/template_instantiation_test.sh`; prefer `mktemp -d`.
- History snapshots are full-canvas deep copies with `budget_bytes` never
  enforced (`used_bytes` uses wrapping add) — memory-growth DoS over many ops.

## Excluded

- `third_party/gossamer/**` (vendored dependency).
- Licence/SPDX content (owner-managed).
</content>
</invoke>
