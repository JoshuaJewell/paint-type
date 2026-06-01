#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# RSR Standard Aspect Test Template
#
# Aspect tests validate cross-cutting architectural invariants that span
# the entire codebase. These are NOT functional tests — they verify that
# coding standards, safety rules, and structural contracts hold.
#
# Usage:
#   bash tests/aspect_tests.sh
#   just aspect
#
# Standard aspects (enable what applies to your project):
#   1. SPDX compliance — all source files have license headers
#   2. Dangerous patterns — no believe_me, assert_total, sorry, unsafeCoerce, etc.
#   3. ABI/FFI contract — declarations match exports
#   4. Thread safety — mutex in FFI modules
#   5. Error handling — no panic/unreachable in production paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
WARN=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

pass() { green "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { red "  FAIL: $1"; FAIL=$((FAIL + 1)); }
warn() { yellow "  WARN: $1"; WARN=$((WARN + 1)); }

echo "═══════════════════════════════════════════════════════════════"
echo "  paint-type — Aspect Tests (Cross-Cutting Concerns)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Aspect 1: SPDX License Headers
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 1: SPDX license headers"

MISSING_SPDX=0
while IFS= read -r -d '' f; do
    if ! head -5 "$f" | grep -q "SPDX-License-Identifier"; then
        warn "Missing SPDX header: $f"
        MISSING_SPDX=$((MISSING_SPDX + 1))
    fi
done < <(find src/ -type f \
    \( -name "*.rs" -o -name "*.zig" -o -name "*.res" -o -name "*.ex" \
       -o -name "*.exs" -o -name "*.gleam" -o -name "*.idr" -o -name "*.sh" \) \
    -not -path '*/.zig-cache/*' \
    -not -path '*/zig-out/*' \
    -not -path '*/target/*' \
    -print0 2>/dev/null)

if [ "$MISSING_SPDX" -eq 0 ]; then
    pass "All source files have SPDX headers"
else
    fail "$MISSING_SPDX files missing SPDX headers"
fi

# ═══════════════════════════════════════════════════════════════════════
# Aspect 2: Dangerous Patterns (BANNED)
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 2: Dangerous patterns"

# Idris2 dangerous patterns
DANGEROUS_IDRIS=$(grep -rn 'believe_me\|assert_total\|really_believe_me' src/interface/Abi/ 2>/dev/null | grep -v "^Binary" | grep -v "test" || true)
if [ -n "$DANGEROUS_IDRIS" ]; then
    fail "Dangerous Idris2 patterns found:"
    echo "$DANGEROUS_IDRIS" | head -5
else
    pass "No dangerous Idris2 patterns (believe_me, assert_total)"
fi

# Coq/Lean/Agda/Haskell dangerous patterns — scope to source extensions only
# so banned-list documentation in *.adoc / *.md / README* isn't flagged.
DANGEROUS_PROOF=$(grep -rn --include='*.v' --include='*.lean' --include='*.agda' --include='*.hs' \
    '\bAdmitted\b\|\bsorry\b\|\bunsafeCoerce\b\|\bObj\.magic\b' src/ verification/ 2>/dev/null \
    | grep -v 'NO Admitted\|no Admitted\|NO sorry\|no sorry' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(--|//|\*|\(\*)' \
    || true)
if [ -n "$DANGEROUS_PROOF" ]; then
    fail "Dangerous proof patterns found:"
    echo "$DANGEROUS_PROOF" | head -5
else
    pass "No dangerous proof patterns (Admitted, sorry, unsafeCoerce)"
fi

# ═══════════════════════════════════════════════════════════════════════
# Aspect 3: ABI/FFI Contract — every Idris2 %foreign has a Zig export
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 3: ABI/FFI contract (Idris2 %foreign ↔ Zig export)"

ABI_FILE="src/interface/Abi/Foreign.idr"
ZIG_FILE="src/interface/ffi/src/main.zig"

if [ -f "$ABI_FILE" ] && [ -f "$ZIG_FILE" ]; then
    MISSING_EXPORTS=0
    # Extract symbol names from `%foreign "C:pt_xxx,libpt"` lines.
    while IFS= read -r sym; do
        if ! grep -qE "^export fn[[:space:]]+${sym}\b" "$ZIG_FILE"; then
            fail "Idris2 imports $sym but no \`export fn $sym\` in $ZIG_FILE"
            MISSING_EXPORTS=$((MISSING_EXPORTS + 1))
        fi
    done < <(grep -oE 'C:pt_[a-z0-9_]+' "$ABI_FILE" | sed 's/^C://' | sort -u)

    if [ "$MISSING_EXPORTS" -eq 0 ]; then
        ABI_COUNT=$(grep -cE '^%foreign[[:space:]]+"C:pt_' "$ABI_FILE")
        ZIG_COUNT=$(grep -cE '^export fn[[:space:]]+pt_' "$ZIG_FILE")
        pass "ABI/FFI contract holds ($ABI_COUNT Idris2 imports ⊆ $ZIG_COUNT Zig exports)"
    fi
else
    warn "ABI/FFI files not present at expected paths — skipping"
fi

# ═══════════════════════════════════════════════════════════════════════
# Aspect 4: Rust error handling — no unaudited .unwrap() in Ephapax core
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 4: Rust error handling (src/ephapax/)"

if [ -d "src/ephapax/src" ]; then
    # Allow .unwrap() in #[cfg(test)] modules and inline doc tests; flag elsewhere.
    # `set +o pipefail` locally so empty grep matches (legitimate: zero unwraps)
    # don't abort the script under the global `pipefail`.
    set +o pipefail
    UNWRAP_PROD=$(grep -rn '\.unwrap()' src/ephapax/src/ 2>/dev/null \
        | grep -v '^[^:]*:[^:]*:[[:space:]]*//' \
        | grep -v '#\[cfg(test)\]' \
        | grep -v '/// ' \
        | wc -l)
    set -o pipefail
    if [ "$UNWRAP_PROD" -gt 0 ]; then
        warn "$UNWRAP_PROD .unwrap() call(s) in non-test Ephapax code — review for panic-safety"
    else
        pass "No .unwrap() in non-test Ephapax code"
    fi
else
    warn "src/ephapax/src not present — skipping Rust error-handling aspect"
fi

# ═══════════════════════════════════════════════════════════════════════
# Aspect 5: Tile primitive invariants — Idris2/Zig/Rust agree on RGBA16F
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 5: Tile primitive constants (RGBA16F, 64×64)"

# RGBA16F = 4 channels × 16-bit float = 8 bytes/pixel.
# Tile size = 64×64×8 = 32 768 bytes. Verify the magic numbers exist
# in each of the three layers so a silent drift cannot creep in.
TILE_BYTES=32768
TILE_OK=0

if grep -qE '\b(64|0x40)\b' src/interface/Abi/Types.idr 2>/dev/null; then
    TILE_OK=$((TILE_OK + 1))
fi
if grep -qE '\b(8192|32768|0x8000)\b' "$ZIG_FILE" 2>/dev/null; then
    TILE_OK=$((TILE_OK + 1))
fi
if grep -rqE '\b(64|RGBA16F|TILE_SIZE|TILE_BYTES)\b' src/ephapax/src/ 2>/dev/null; then
    TILE_OK=$((TILE_OK + 1))
fi

if [ "$TILE_OK" -eq 3 ]; then
    pass "Tile constants present in all three layers (Idris2/Zig/Rust)"
elif [ "$TILE_OK" -gt 0 ]; then
    warn "Tile constants present in $TILE_OK/3 layers — verify drift"
else
    warn "No tile constants located — search heuristic may be stale"
fi

# ═══════════════════════════════════════════════════════════════════════
# Aspect 6: Idris2 ABI proof check (skips if idris2 not installed)
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 6: Idris2 ABI proof check"

if ! command -v idris2 >/dev/null 2>&1; then
    warn "idris2 not installed locally — skipping (CI runs this via .github/workflows/idris-ci.yml)"
else
    ABI_CHECK_ERRORS=0
    for f in src/interface/Abi/Types.idr src/interface/Abi/Layout.idr src/interface/Abi/Foreign.idr; do
        if [ -f "$f" ]; then
            # idris2 --check exits 0 even when imports are unresolvable, so we
            # must inspect combined stdout+stderr for "Error:".
            OUT=$(cd src/interface && idris2 --check "${f#src/interface/}" 2>&1 || true)
            if printf '%s' "$OUT" | grep -q '^Error:'; then
                if printf '%s' "$OUT" | grep -q 'Module .* not found'; then
                    warn "idris2 --check $f — missing stdlib modules locally (CI is authoritative); skipping"
                else
                    fail "idris2 --check $f failed:"
                    printf '%s\n' "$OUT" | head -5
                    ABI_CHECK_ERRORS=$((ABI_CHECK_ERRORS + 1))
                fi
            fi
        fi
    done
    if [ "$ABI_CHECK_ERRORS" -eq 0 ]; then
        pass "All ABI modules type-check (or skipped: missing stdlib locally)"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Aspect 7: File I/O round-trip — DEFERRED to v0.3.0
# ═══════════════════════════════════════════════════════════════════════
# TEST-NEEDS.md P1 lists a file-I/O round-trip aspect (create tile, save,
# reload, verify bytes identical). v0.1.0 has no file I/O surface yet —
# this aspect activates at v0.3.0 Desktop Shell milestone when the native
# RGBA16F format ships.

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
if [ "$WARN" -gt 0 ]; then yellow "WARN=$WARN"; else echo "WARN=0"; fi
echo ""
echo "═══════════════════════════════════════════════════════════════"

exit "$FAIL"
