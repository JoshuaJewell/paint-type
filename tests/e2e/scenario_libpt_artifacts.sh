#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# E2E Scenario: libpt artifacts.
#
# Verifies that after a successful build the static + shared libpt
# artifacts are present and contain the expected pt_* exports. Driven
# from tests/e2e.sh, which has already run `zig build` by the time we
# get here; this script is the "shape of the deliverable" check.

set -eu

PROJECT_DIR="${1:-.}"
LIB_DIR="$PROJECT_DIR/src/interface/ffi/zig-out/lib"

if [ ! -d "$LIB_DIR" ]; then
    echo "FAIL: $LIB_DIR is missing — zig build did not run, or installArtifact step is broken."
    exit 1
fi

# Static library is mandatory — the Rust crate links against it.
STATIC=""
if [ -f "$LIB_DIR/libpt.a" ]; then
    STATIC="$LIB_DIR/libpt.a"
elif [ -f "$LIB_DIR/pt.lib" ]; then
    STATIC="$LIB_DIR/pt.lib"
else
    echo "FAIL: no libpt.a / pt.lib in $LIB_DIR"
    exit 1
fi
echo "OK: static library at $STATIC"

# Shared library is target-dependent: .so / .dylib / .dll. We don't
# require all three, only that at least one is present.
SHARED=""
for candidate in libpt.so libpt.dylib pt.dll; do
    if [ -f "$LIB_DIR/$candidate" ]; then
        SHARED="$LIB_DIR/$candidate"
        break
    fi
done
if [ -z "$SHARED" ]; then
    echo "FAIL: no shared library (libpt.so / libpt.dylib / pt.dll) in $LIB_DIR"
    exit 1
fi
echo "OK: shared library at $SHARED"

# Symbol probes — every pt_tile_* and pt_layer_* export we drive from
# the Rust integration test must be present in the static archive.
# Use `nm` (POSIX-ish — also on most BusyBoxes) or fall back to `strings`.
EXPECT_SYMBOLS="pt_tile_alloc pt_tile_free pt_tile_fill pt_tile_read_pixel pt_tile_write_pixel pt_layer_stack_new pt_layer_stack_free pt_layer_push pt_layer_reorder_to pt_layer_get_name pt_layer_get_id_at pt_layer_count"
SYMBOL_TOOL=""
if command -v nm >/dev/null 2>&1; then
    SYMBOL_TOOL="nm"
elif command -v strings >/dev/null 2>&1; then
    SYMBOL_TOOL="strings"
fi
if [ -n "$SYMBOL_TOOL" ]; then
    MISSING=""
    SYMBOL_DUMP="$($SYMBOL_TOOL "$STATIC" 2>/dev/null || true)"
    for sym in $EXPECT_SYMBOLS; do
        if ! printf '%s' "$SYMBOL_DUMP" | grep -q "$sym"; then
            MISSING="$MISSING $sym"
        fi
    done
    if [ -n "$MISSING" ]; then
        echo "FAIL: missing pt_* symbols from $STATIC:$MISSING"
        exit 1
    fi
    echo "OK: every expected pt_tile_* / pt_layer_* symbol present in $(basename "$STATIC")"
else
    echo "WARN: neither nm nor strings on PATH — skipped symbol probe."
fi

# File-size sanity: an empty / stub static lib would be < 1KB; the
# real libpt is comfortably > 10KB.
SIZE_BYTES=$(wc -c < "$STATIC")
if [ "$SIZE_BYTES" -lt 1024 ]; then
    echo "FAIL: $STATIC is only $SIZE_BYTES bytes — suspiciously small."
    exit 1
fi
echo "OK: $STATIC is $SIZE_BYTES bytes"

exit 0
