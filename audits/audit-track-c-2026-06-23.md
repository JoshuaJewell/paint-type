<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Audit: Track C — outstanding panic-attack Critical/High findings

**Date:** 2026-06-23
**Scanner:** `panic-attack 2.5.5` (`assail . --headless`), built from source.
**Registry:** `audits/assail-classifications.a2ml`.
**Scope:** every active (`suppressed != true`) Critical/High finding on `main`
that was **not** already covered by the existing registry (which predates this
pass and covers `src/host`, `src/paint_core`, `src/interface/ffi`, scripts).

## Result

**36 active Critical/High findings; 0 real bugs.** All are legitimate
FFI-boundary patterns or scanner false positives, now classified. The split:

| Where | Count | Disposition |
|---|---|---|
| `third_party/gossamer/` (vendored) | 32 | vendored third-party — classified; source of truth is the gossamer repo |
| paint-type own code | 4 | legitimate FFI boundary (3 files; `ephapax/lib.rs` carries two) |

> **gossamer is vendored.** `third_party/gossamer/` is a 501-file *copy* of
> `JoshuaJewell/gossamer` (its own public repo), not paint-type source. Per the
> "fix upstream, at source" principle these findings are **not** patched in the
> vendored copy; they are classified so paint-type's own scans are clean, and any
> real fix belongs in the gossamer repo. None of the 32 is a real defect (below),
> so no upstream issue is filed at this time.

## paint-type own code — legitimate FFI (audited)

- **`examples/undo_demo.zig`** (UnsafeCode) — `@ptrCast` of `&stackBuf[0]`
  (`[256]u8`) to `[*:0]const u8` for a stdlib `fopen`; the NUL terminator is set
  explicitly first. No untrusted data.
- **`src/backends/storage/verisimdb.zig`** (UnsafeCode) —
  `@constCast(@ptrCast(&dummy))` builds an opaque `*anyopaque` vtable context to
  a program-lifetime static; the stub `Transport` never dereferences `ctx`, so
  the const-removal is sound.
- **`src/ephapax/src/lib.rs`** (UnsafeCode ×2: 5 unsafe blocks + a raw pointer
  cast) — five `extern "C"` calls into the Zig `libpt` C ABI
  (`pt_tile_alloc` / `pt_is_initialized` / `pt_tile_fill` / `pt_tile_read_pixel`
  / `pt_tile_free`), each with a `// SAFETY:` comment. Handles are uniquely owned
  (freed exactly once in `Drop`); the `read_pixel` output pointers are live
  stack locals across the call; `libpt` validates null + a magic word internally.
  No UB hazard.

## Vendored gossamer — classifications

- **`benchmarks/startup-bench.sh`** (CommandInjection, Critical) — *false
  positive*. The flagged `eval` is the gossamer binary's `--eval` **command-line
  flag** with a hardcoded literal argument (`window.close()`), not the shell
  `eval` builtin. No injection vector. → `false-positive-cli-flag`.
- **`src/abi/PanelIsolation.idr`, `src/interface/abi/PanelIsolation.idr`,
  `src/interface/Gossamer/ABI/PanelIsolation.idr`** (ProofDrift, Critical;
  byte-identical copies) — `believe_me ()` asserts commutativity of String
  inequality over the backend primitive `prim__eq_String`. This is a documented
  class-J FFI-boundary axiom (the file carries the note + property-test
  rationale), **not** a soundness hole: panel isolation is enforced by the
  phantom panel-tag *types*, which the type checker keeps distinct regardless of
  this lemma. → `vendored-documented-axiom` (reducible upstream if/when a
  `prim__eq_String` symmetry harness exists).
- **`src/interface/ffi/src/*.zig`, `cli/launcher/src/*.zig`** (UnsafeCode ×18,
  UnsafeFFI ×10) — webview / native-platform bindings (webview_gtk/cocoa/win32/
  ios, IPC, tray, dialog, clipboard, CSP, …). Zig unsafe pointer casts and
  `@cImport`/extern-C declarations at the OS FFI boundary. →
  `legitimate-vendored-ffi`.

## Scanner-mechanism note (panic-attack 2.5.5)

As with `proven`, this registry is verified to be an **audit trail, not an active
suppression input** under panic-attack 2.5.5: the scanner suppresses via its
context-aware `kanren` engine and inline `// panic-attack: accepted` markers, and
does not read `assail-classifications.a2ml`. The registry's header line about
being "consumed by panic-attack's suppression engine" reflects an earlier scanner
version. Entries are retained as the reviewable, estate-canonical record of these
dispositions.

## Anti-gameability

The registry is a separate file from any scanned source; adding a new unsafe
block / `believe_me` / `eval` cannot self-suppress — a reviewable registry edit
plus this audit entry is required. No paint-type own-code finding was a real bug,
so nothing was code-fixed in this pass; the dispositions are classifications.
