#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# coverage.sh — Local coverage harness for paint-type.
#
# Mirrors `.github/workflows/coverage.yml`:
#   - Rust:  `cargo llvm-cov` → src/ephapax/lcov.info  +  console report
#   - Zig:   best-effort kcov over the integration-test binary
#
# Usage:
#   bash tests/coverage.sh                # both languages, best effort
#   bash tests/coverage.sh rust           # Rust only
#   bash tests/coverage.sh zig            # Zig only
#
# Exit code reflects the Rust coverage step only. Zig coverage is
# reporting-only and never fails the script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-all}"

# ─── Colour helpers ──────────────────────────────────────────────────
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# ─── Rust coverage ───────────────────────────────────────────────────
run_rust_coverage() {
    bold "Rust coverage (cargo-llvm-cov)"

    if ! command -v cargo >/dev/null 2>&1; then
        red "  cargo not on PATH — install Rust first."
        return 1
    fi

    if ! cargo llvm-cov --version >/dev/null 2>&1; then
        yellow "  cargo-llvm-cov not installed; attempting cargo install…"
        cargo install cargo-llvm-cov --locked
    fi

    cd "$PROJECT_DIR/src/ephapax"
    cargo llvm-cov --all-features --workspace --lcov \
        --output-path lcov.info
    echo ""
    cargo llvm-cov report
    echo ""
    green "  LCOV written to src/ephapax/lcov.info"
}

# ─── Zig coverage ────────────────────────────────────────────────────
run_zig_coverage() {
    bold "Zig coverage (kcov, best-effort)"

    if ! command -v zig >/dev/null 2>&1; then
        yellow "  zig not on PATH — skipping Zig coverage."
        return 0
    fi
    if ! command -v kcov >/dev/null 2>&1; then
        yellow "  kcov not on PATH — skipping Zig coverage."
        yellow "  Install: sudo apt-get install kcov   (or your distro equivalent)"
        return 0
    fi

    cd "$PROJECT_DIR/src/interface/ffi"
    zig build -Doptimize=Debug

    mkdir -p zig-out/test
    if ! zig test test/integration_test.zig \
            -L zig-out/lib \
            -lpt \
            -lc \
            --test-no-exec \
            -femit-bin=zig-out/test/integration_test; then
        yellow "  zig test binary build failed — skipping kcov."
        return 0
    fi

    mkdir -p "$PROJECT_DIR/coverage/zig"
    if ! kcov \
            --include-path="$PROJECT_DIR/src/interface/ffi" \
            "$PROJECT_DIR/coverage/zig" \
            zig-out/test/integration_test; then
        yellow "  kcov reported failure — output (if any) is under coverage/zig/."
        return 0
    fi
    green "  kcov output under coverage/zig/"
}

echo "═══════════════════════════════════════════════════════════════"
echo "  paint-type — Coverage Reporting"
echo "═══════════════════════════════════════════════════════════════"
echo ""

case "$MODE" in
    rust)
        run_rust_coverage
        ;;
    zig)
        run_zig_coverage
        ;;
    all)
        run_rust_coverage
        echo ""
        run_zig_coverage
        ;;
    *)
        red "Unknown mode '$MODE' (use: rust | zig | all)"
        exit 2
        ;;
esac

echo ""
echo "═══════════════════════════════════════════════════════════════"
green "  Coverage run complete."
echo "═══════════════════════════════════════════════════════════════"
