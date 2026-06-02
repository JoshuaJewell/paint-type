#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# E2E Scenario: pipeline dogfood.
#
# Re-runs the Rust e2e_pipeline test with --nocapture in case the parent
# orchestrator suppressed the per-stage probe output, and verifies that
# both scenarios advertised by the binary actually executed. This is the
# "did the v0.2.0 pipeline really run end-to-end" attestation row.

set -eu

PROJECT_DIR="${1:-.}"
EPHAPAX_DIR="$PROJECT_DIR/src/paint_core"

if [ ! -f "$EPHAPAX_DIR/Cargo.toml" ]; then
    echo "FAIL: $EPHAPAX_DIR/Cargo.toml missing — repo layout broken."
    exit 1
fi

# Invoke cargo with --nocapture so test stdout / stderr is preserved.
# Test paths use `expect()` for failure-clarity, so the only stdout
# noise we expect is the standard `test result:` line.
# PT_TMPDIR overrides the log location for sandboxed or read-only-/tmp/
# environments (closes the panic-attack PathTraversal medium finding).
PT_TMPDIR="${PT_TMPDIR:-/tmp}"
LOG="${PT_TMPDIR}/pt-e2e-scenario-pipeline.log"
if ! (cd "$EPHAPAX_DIR" && cargo test --test e2e_pipeline -- --nocapture --test-threads=1) \
        >"$LOG" 2>&1; then
    echo "FAIL: cargo test --test e2e_pipeline failed."
    tail -60 "$LOG" || true
    exit 1
fi

# Both scenarios must appear in the output and both must pass.
EXPECT_TESTS="end_to_end_tile_layer_brush_undo_pipeline end_to_end_layer_stack_flatten_pipeline"
for tname in $EXPECT_TESTS; do
    if ! grep -q "test $tname \\.\\.\\. ok" "$LOG"; then
        echo "FAIL: integration test '$tname' did not pass (or did not run)."
        tail -60 "$LOG" || true
        exit 1
    fi
    echo "OK: $tname passed"
done

# Final test-result line must report 2 passed / 0 failed.
if ! grep -q "test result: ok\\. 2 passed; 0 failed" "$LOG"; then
    echo "FAIL: expected '2 passed; 0 failed' in cargo summary."
    tail -20 "$LOG" || true
    exit 1
fi
echo "OK: cargo summary line reports 2 passed / 0 failed"

exit 0
