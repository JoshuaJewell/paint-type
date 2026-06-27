#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# RSR Standard E2E Test Template
#
# End-to-end tests validate the full pipeline: build → run → verify output.
# Customise this file for your project. Delete the examples that don't apply.
#
# Usage:
#   bash tests/e2e.sh
#   just e2e
#
# Merge requirements (STANDING): All 6 test categories must pass before merge:
#   P2P, E2E (this file), aspect, execution, lifecycle, benchmarks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

# ─── Colour helpers ──────────────────────────────────────────────────
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# ─── Assertion helpers ───────────────────────────────────────────────

# check <label> <expected-substring> <actual>
check() {
    local name="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        green "  PASS: $name"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $name (expected '$expected', got '${actual:0:120}')"
        FAIL=$((FAIL + 1))
    fi
}

# check_status <label> <expected-http-status> <actual-http-status>
check_status() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        green "  PASS: $name (HTTP $actual)"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $name (expected HTTP $expected, got HTTP $actual)"
        FAIL=$((FAIL + 1))
    fi
}

# skip <label> <reason>
skip_test() {
    yellow "  SKIP: $1 ($2)"
    SKIP=$((SKIP + 1))
}

echo "═══════════════════════════════════════════════════════════════"
echo "  paint-type — End-to-End Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── Preflight ───────────────────────────────────────────────────────
bold "Preflight checks"

# TODO: Check that your binary/server is built
# Example:
# BINARY="$PROJECT_DIR/target/release/my-tool"
# if [ ! -f "$BINARY" ]; then
#     red "Binary not found at $BINARY — run 'just build' first"
#     exit 1
# fi
# green "  Binary found: $BINARY"

# TODO: Check dependencies
# command -v curl >/dev/null 2>&1 || { red "curl not found"; exit 1; }
# command -v jq >/dev/null 2>&1   || { red "jq not found"; exit 1; }

echo ""

# ═══════════════════════════════════════════════════════════════════════
# Section 1: Desktop shell (WebKitGTK) — open app, empty canvas, quit clean
# ═══════════════════════════════════════════════════════════════════════
# Builds the v0.3.0 webview shell (src/shell/, a GTK3 + WebKitGTK host on the
# same stack as gossamer/webview_gtk) and launches it headlessly under Xvfb in
# smoke mode. The shell creates the window + web view, loads the empty-canvas
# page, then auto-quits — emitting two markers the harness asserts. Skips
# cleanly where the webview toolkit or a headless display is unavailable (e.g.
# the macOS/Windows matrix legs), so it never produces a false failure.
bold "Section 1: Desktop shell — launch, empty canvas, quit clean"

SHELL_DIR="$PROJECT_DIR/src/shell"

if ! command -v zig >/dev/null 2>&1; then
    skip_test "desktop shell launch" "zig not found"
elif ! pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
    skip_test "desktop shell launch" "webkit2gtk-4.1 not installed (webview toolkit absent)"
elif ! command -v xvfb-run >/dev/null 2>&1; then
    skip_test "desktop shell launch" "xvfb-run not found (no headless display)"
else
    if ( cd "$SHELL_DIR" && zig build ) >/tmp/pt-shell-build.log 2>&1; then
        green "  PASS: shell builds (GTK3 + WebKitGTK)"
        PASS=$((PASS + 1))
        SHELL_BIN="$SHELL_DIR/zig-out/bin/paint-type-shell"
        SHELL_OUT=$(timeout 40 xvfb-run -a -s "-screen 0 1280x1024x24" \
            env PT_SHELL_SMOKE=1 \
                WEBKIT_DISABLE_COMPOSITING_MODE=1 \
                WEBKIT_DISABLE_DMABUF_RENDERER=1 \
                LIBGL_ALWAYS_SOFTWARE=1 \
                GDK_BACKEND=x11 \
            "$SHELL_BIN" 2>&1) || true
        check "shell opens window + empty canvas" "PT_SHELL: canvas-ready" "$SHELL_OUT"
        check "shell quits cleanly" "PT_SHELL: quit-clean" "$SHELL_OUT"
    else
        fail "shell build failed (see /tmp/pt-shell-build.log)"
        tail -5 /tmp/pt-shell-build.log || true
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "  Results: "
green "PASS=$PASS" | tr -d '\n'
echo -n "  "
if [ "$FAIL" -gt 0 ]; then red "FAIL=$FAIL" | tr -d '\n'; else echo -n "FAIL=0"; fi
echo -n "  "
if [ "$SKIP" -gt 0 ]; then yellow "SKIP=$SKIP"; else echo "SKIP=0"; fi
echo "═══════════════════════════════════════════════════════════════"

exit "$FAIL"
