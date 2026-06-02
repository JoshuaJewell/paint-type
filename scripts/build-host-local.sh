#!/usr/bin/env bash
### build-host-local.sh
# Build and run the paint.type desktop host on a Linux box WITHOUT root, by
# assembling a local WebKitGTK sysroot from downloaded .deb packages. This is
# a fallback for environments where `sudo apt-get install libwebkit2gtk-4.1-dev`
# is not available; on a normal dev box, just install those -dev packages and
# use `just build` instead.
#
# Usage:
#   scripts/build-host-local.sh sysroot   # assemble the local WebKitGTK sysroot
#   scripts/build-host-local.sh build     # build libgossamer + the host binary
#   scripts/build-host-local.sh run       # run the windowed app (needs $DISPLAY)
#   scripts/build-host-local.sh all       # sysroot + build
#
# SPDX-License-Identifier: PMPL-1.0-or-later
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYSROOT="${PT_SYSROOT:-$HOME/.cache/pt-wk-sysroot}"
# PT_TMPDIR override (PathTraversal hardening) — switches /tmp/pt-* working
# files to a configurable location. Default /tmp/ preserves the existing
# developer convention; CI sandboxes / read-only-/tmp/ hosts can redirect.
PT_TMPDIR="${PT_TMPDIR:-/tmp}"
DEBS="${PT_DEBS:-${PT_TMPDIR}/pt-debs}"
LIBDIR="$SYSROOT/usr/lib/x86_64-linux-gnu"
SYSLIB="/usr/lib/x86_64-linux-gnu"
GOSS_LIB="$ROOT/third_party/gossamer/src/interface/ffi/zig-out/lib"

export PKG_CONFIG_PATH="$LIBDIR/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export RUSTFLAGS="-L native=$LIBDIR -C link-arg=-Wl,-rpath,$LIBDIR -C link-arg=-Wl,-rpath,$SYSLIB -C link-arg=-Wl,-rpath,$GOSS_LIB"
export LD_LIBRARY_PATH="$GOSS_LIB:$LIBDIR:$SYSLIB"

### Assemble the sysroot: download the dev closure + extract + bridge symlinks
build_sysroot() {
    mkdir -p "$DEBS" "$SYSROOT"
    cd "$DEBS" || exit 1
    echo "Resolving the webkit2gtk-4.1-dev / gtk-3-dev download closure..."
    apt-get install -y --no-install-recommends --print-uris \
        libwebkit2gtk-4.1-dev libgtk-3-dev 2>/dev/null \
        | grep -oE "'http[^']+'" | tr -d "'" \
        | grep -E '_(amd64|all)\.deb$' > "${PT_TMPDIR}/pt-uris.txt"
    # The closure omits -dev packages apt believes are already installed; pull
    # every -dev in the recursive dependency tree so all headers are present.
    apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
        --no-breaks --no-replaces --no-enhances --no-pre-depends \
        libgtk-3-dev libwebkit2gtk-4.1-dev 2>/dev/null \
        | grep -E '^[a-z0-9].*-dev$' | sort -u > "${PT_TMPDIR}/pt-devpkgs.txt"
    echo "Downloading base closure ($(wc -l < "${PT_TMPDIR}/pt-uris.txt") urls)..."
    xargs -P8 -I{} curl -fsSL --max-time 120 -O "{}" < "${PT_TMPDIR}/pt-uris.txt" 2>/dev/null
    echo "Downloading -dev headers ($(wc -l < "${PT_TMPDIR}/pt-devpkgs.txt") packages)..."
    while read -r p; do apt-get download "$p" >/dev/null 2>&1; done < "${PT_TMPDIR}/pt-devpkgs.txt"
    echo "Extracting $(ls -1 ./*.deb | wc -l) packages into $SYSROOT ..."
    for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$SYSROOT" 2>/dev/null; done
    # The -dev .so files symlink to runtime .so.N that live on the host; point
    # the dangling links at the system copies so the linker resolves them.
    local bridged=0
    for sofile in "$LIBDIR"/*.so; do
        [ -L "$sofile" ] || continue
        local tgt; tgt="$(readlink "$sofile")"
        [ -e "$LIBDIR/$tgt" ] && continue
        [ -e "$SYSLIB/$tgt" ] && { ln -sf "$SYSLIB/$tgt" "$LIBDIR/$tgt"; bridged=$((bridged+1)); }
    done
    echo "Sysroot ready ($(du -sh "$SYSROOT" | cut -f1); bridged $bridged runtime symlinks)."
}

### Build libgossamer (Zig) then the host binary (Rust)
build_host() {
    [ -f "$LIBDIR/pkgconfig/webkit2gtk-4.1.pc" ] || { echo "No sysroot; run: $0 sysroot"; exit 1; }
    # libpt is on the pixel hot path; build it optimised so the per-tile
    # buffer copies are fast.
    echo "Building libpt (ReleaseFast)..."
    ( cd "$ROOT/src/interface/ffi" && zig build -Doptimize=ReleaseFast ) || exit 1
    echo "Building libgossamer..."
    ( cd "$ROOT/third_party/gossamer/src/interface/ffi" && zig build ) || exit 1
    echo "Building the host binary (release)..."
    cargo build --release --manifest-path "$ROOT/src/host/Cargo.toml" || exit 1
    echo "Built: $ROOT/src/host/target/release/paint-type"
}

### Run the windowed application
run_host() {
    [ -n "$DISPLAY" ] || { echo "No \$DISPLAY set; a window cannot open."; exit 1; }
    exec "$ROOT/src/host/target/release/paint-type"
}

case "${1:-all}" in
    sysroot) build_sysroot ;;
    build)   build_host ;;
    run)     run_host ;;
    all)     build_sysroot && build_host ;;
    *) echo "usage: $0 {sysroot|build|run|all}"; exit 2 ;;
esac
