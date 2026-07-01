<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Contributing to paint-type

1. Fork the repository at https://github.com/JoshuaJewell/paint-type
2. Create a feature branch (`feat/short-description`, `fix/issue-number`, etc.)
3. Ensure SPDX headers on all new files (`// SPDX-License-Identifier: AGPL-3.0-or-later`)
4. Run `just test` — all tests must pass
5. Run `just lint` — no lint errors
6. Submit a pull request against `main`

**Owner:** Joshua Jewell <paint-type@pm.me>

See `.github/CONTRIBUTING.md` for the full contribution guide.

## Platform support: best-effort macOS / iOS / Windows

paint-type is developed and CI-gated on **Linux**, which is our verified,
first-class platform. We take cross-platform seriously but are honest about
where it stands today:

- **Build/link coverage — all platforms (gated).** Every PR cross-compiles the
  full native vertical (Zig dispatcher + CPU-reference backend + the libpt FFI
  library) to **macOS (aarch64 + x86_64)** and **Windows (x86_64)** from Linux
  via `zig build -Dtarget=…`. If it stops building for a target, CI fails.
- **Native test execution — macOS / Windows is best-effort.** The
  `macos-latest` / `windows-latest` legs of `.github/workflows/cross-platform.yml`
  actually *run* the test suite on each OS, but are marked `continue-on-error`:
  they run and surface their results without blocking `main` while native
  execution (linker/path quirks, the Cocoa/WebView shell backends) is shaken out.
- **iOS — not yet started.** Aspirational; no shell backend exists yet.

### We'd love your help 🍎

If you run **macOS, iOS, or Windows** and want to contribute, this is one of the
highest-leverage places to help — no deep knowledge of the internals required to
start:

- Run the native leg locally (`zig build && zig build test`, then
  `cargo test --all-targets` in `src/paint_core`) and report what breaks.
- Send fixes for native linking / path issues, or a macOS (Cocoa/WebKit) or
  Windows (WebView2) backend for the desktop shell (`src/shell/`).
- Share crash logs, screenshots, and platform notes.

Open or comment on the platform-testing tracking issue (see the issues tab,
label `platform-support` / `help wanted`) and tag your PRs with the OS you
tested on. Best-effort from us, warmly credited from you.
