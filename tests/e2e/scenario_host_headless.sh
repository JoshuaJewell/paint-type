#!/usr/bin/env bash
# Headless boot-and-save smoke for the desktop host seam. Drives the
# host_core dispatch path (new_doc -> stroke -> save_png) with no window
# and asserts a non-empty PNG is produced. The GUI itself is smoke-tested
# manually; this proves the seam logic end to end without a display.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)/headless.png"

PT_HEADLESS_OUT="$OUT" cargo test --manifest-path "$ROOT/src/host_core/Cargo.toml" \
    --test headless_save -- --nocapture

if [ ! -s "$OUT" ]; then
    echo "FAIL: headless save produced no PNG at $OUT"
    exit 1
fi
echo "PASS: headless host wrote $OUT ($(wc -c < "$OUT") bytes)"
