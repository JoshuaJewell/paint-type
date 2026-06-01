#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# paint-type — End-to-End Test Orchestrator.
#
# This script walks the full editing pipeline that v0.2.0 ships:
#
#   1. Build the Zig FFI library (libpt) — `zig build` in
#      src/interface/ffi/. Produces both static (libpt.a, linked into
#      ephapax) and shared (libpt.so / .dylib / .dll, used by other
#      embedders) artifacts.
#   2. Run the existing Zig integration-test target (`zig build test`)
#      as a smoke check that the FFI exports we are about to drive
#      from Rust really do work.
#   3. Run the Rust e2e_pipeline integration test
#      (`cargo test --test e2e_pipeline`). That binary exercises:
#        - Tile alloc / fill / read / write / drop via the safe Tile API
#        - Tile::composite_over (Porter-Duff "over" pixel-by-pixel)
#        - UndoGraph snapshots between edit stages
#        - pt_layer_stack_new / pt_layer_push / pt_layer_reorder_to /
#          pt_layer_get_name / pt_layer_count / pt_layer_get_id_at /
#          pt_layer_stack_free
#        - BrushTip::hard_round + Brush::stamp driven by a Stroke that
#          emits at least five stamps; pixel values verified before and
#          after the stroke.
#   4. Run any extra scenario scripts in tests/e2e/scenario_*.sh.
#
# Exits 0 only if every stage succeeds. Any failure prints a clear
# diagnostic and exits non-zero.
#
# Usage:
#   bash tests/e2e.sh        # from repo root
#   just e2e

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

# ─── Colour helpers (no-op outside a TTY) ────────────────────────────
if [ -t 1 ]; then
    green() { printf '\033[32m%s\033[0m\n' "$*"; }
    red()   { printf '\033[31m%s\033[0m\n' "$*"; }
    yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
    bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
else
    green() { printf '%s\n' "$*"; }
    red()   { printf '%s\n' "$*"; }
    yellow(){ printf '%s\n' "$*"; }
    bold()  { printf '%s\n' "$*"; }
fi

stage_pass() {
    green "  PASS: $1"
    PASS=$((PASS + 1))
}

stage_fail() {
    red "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

echo "==============================================================="
echo "  paint-type — End-to-End Pipeline Tests"
echo "==============================================================="
echo ""

# ─── Preflight ───────────────────────────────────────────────────────
bold "Preflight"

if ! command -v zig >/dev/null 2>&1; then
    red "  zig not found on PATH; install Zig 0.15+ before running this test."
    exit 2
fi
stage_pass "zig present ($(zig version))"

if ! command -v cargo >/dev/null 2>&1; then
    red "  cargo not found on PATH; install Rust before running this test."
    exit 2
fi
stage_pass "cargo present ($(cargo --version))"

if [ ! -d "$PROJECT_DIR/src/interface/ffi" ]; then
    red "  src/interface/ffi missing — repo layout broken?"
    exit 2
fi
if [ ! -d "$PROJECT_DIR/src/ephapax" ]; then
    red "  src/ephapax missing — repo layout broken?"
    exit 2
fi
stage_pass "source tree layout intact"
echo ""

# ─── Stage 1: build libpt ────────────────────────────────────────────
bold "Stage 1: build libpt"

if (cd "$PROJECT_DIR/src/interface/ffi" && zig build -Doptimize=ReleaseSafe) >/tmp/pt-e2e-zig-build.log 2>&1; then
    stage_pass "zig build (static + shared libpt)"
else
    stage_fail "zig build"
    yellow "    --- zig build log (last 40 lines) ---"
    tail -40 /tmp/pt-e2e-zig-build.log || true
    yellow "    -------------------------------------"
    exit 1
fi

if [ ! -f "$PROJECT_DIR/src/interface/ffi/zig-out/lib/libpt.a" ] \
   && [ ! -f "$PROJECT_DIR/src/interface/ffi/zig-out/lib/pt.lib" ]; then
    stage_fail "libpt.a / pt.lib not present in zig-out/lib/"
    exit 1
fi
stage_pass "libpt static artifact present"
echo ""

# ─── Stage 2: Zig integration tests ──────────────────────────────────
bold "Stage 2: Zig integration smoke (zig build test)"

if (cd "$PROJECT_DIR/src/interface/ffi" && zig build test) >/tmp/pt-e2e-zig-test.log 2>&1; then
    stage_pass "zig build test"
else
    stage_fail "zig build test"
    yellow "    --- zig build test log (last 40 lines) ---"
    tail -40 /tmp/pt-e2e-zig-test.log || true
    yellow "    ------------------------------------------"
    exit 1
fi

# `zig build test` rebuilds the static library at default (Debug) optimize,
# which emits `__zig_probe_stack` references that Rust's lld cannot resolve
# when linking the cargo test binary. Re-emit the static artifact at
# ReleaseSafe so Stage 3's cargo link finds a stripped libpt.a.
if (cd "$PROJECT_DIR/src/interface/ffi" && zig build -Doptimize=ReleaseSafe) \
        >>/tmp/pt-e2e-zig-build.log 2>&1; then
    :  # silent — Stage 1 already announced "zig build (static + shared)"
else
    stage_fail "zig build (rebuild ReleaseSafe after zig test)"
    yellow "    --- zig build log (last 40 lines) ---"
    tail -40 /tmp/pt-e2e-zig-build.log || true
    yellow "    ------------------------------------------"
    exit 1
fi
echo ""

# ─── Stage 3: Rust e2e_pipeline integration test ─────────────────────
bold "Stage 3: cargo test --test e2e_pipeline (full pipeline scenario)"

if (cd "$PROJECT_DIR/src/ephapax" && cargo test --test e2e_pipeline -- --test-threads=1) \
        >/tmp/pt-e2e-cargo.log 2>&1; then
    stage_pass "cargo test --test e2e_pipeline"
    yellow "    --- last 10 lines of cargo output ---"
    tail -10 /tmp/pt-e2e-cargo.log || true
    yellow "    -------------------------------------"
else
    stage_fail "cargo test --test e2e_pipeline"
    yellow "    --- cargo log (last 60 lines) ---"
    tail -60 /tmp/pt-e2e-cargo.log || true
    yellow "    --------------------------------"
    exit 1
fi
echo ""

# ─── Stage 4: extra scenarios ────────────────────────────────────────
bold "Stage 4: tests/e2e/scenario_*.sh"

SCENARIO_COUNT=0
SCENARIO_FAIL=0
for scenario in "$SCRIPT_DIR"/e2e/scenario_*.sh; do
    [ -e "$scenario" ] || continue
    SCENARIO_COUNT=$((SCENARIO_COUNT + 1))
    name="$(basename "$scenario")"
    if bash "$scenario" "$PROJECT_DIR" >/tmp/pt-e2e-scenario.log 2>&1; then
        stage_pass "scenario: $name"
    else
        stage_fail "scenario: $name"
        SCENARIO_FAIL=$((SCENARIO_FAIL + 1))
        yellow "    --- $name log (last 40 lines) ---"
        tail -40 /tmp/pt-e2e-scenario.log || true
        yellow "    ---------------------------------"
    fi
done
if [ "$SCENARIO_COUNT" -eq 0 ]; then
    yellow "  (no scenario_*.sh files found — Rust integration test covers the pipeline)"
fi
if [ "$SCENARIO_FAIL" -gt 0 ]; then
    exit 1
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo "==============================================================="
bold  "Results: PASS=$PASS  FAIL=$FAIL"
echo "==============================================================="

exit "$FAIL"
