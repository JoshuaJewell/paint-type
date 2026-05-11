// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Cargo build script for ephapax.
//
// Locates libpt.a (built by the Zig FFI under src/interface/ffi/) and
// emits the linker directives Cargo needs to statically link it.
//
// Resolution strategy:
//   1. If `PT_LIB_DIR` is set in the environment, use it verbatim. This
//      lets CI / packagers point at a prebuilt library without rebuilding.
//   2. Otherwise, look in `../../interface/ffi/zig-out/lib/` relative to
//      this Cargo.toml.
//   3. If the library isn't there, attempt `zig build -Doptimize=ReleaseSafe`
//      in `../../interface/ffi/`. Requires `zig` on PATH.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=PT_LIB_DIR");
    println!("cargo:rerun-if-changed=../interface/ffi/src/main.zig");
    println!("cargo:rerun-if-changed=../interface/ffi/build.zig");

    let lib_dir = resolve_lib_dir();

    if !static_lib_exists(&lib_dir) {
        // Last-ditch attempt: invoke `zig build` to produce libpt.a.
        // This requires `zig` on PATH; if it's missing, fail with a clear
        // diagnostic so the developer knows what to do.
        try_build_zig();
    }

    // We do not hard-fail here: if the library still isn't present, the
    // resulting link error will be the actionable diagnostic. We do print
    // a warning so the build log explains it.
    if !static_lib_exists(&lib_dir) {
        println!(
            "cargo:warning=ephapax: libpt static library not found in {}; \
             linker will fail. Run `zig build` in src/interface/ffi/.",
            lib_dir.display()
        );
    }

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=pt");

    // Zig's static libraries pull in libc symbols on most targets.
    let target = env::var("TARGET").unwrap_or_default();
    if target.contains("linux") {
        println!("cargo:rustc-link-lib=dylib=c");
    } else if target.contains("apple") {
        println!("cargo:rustc-link-lib=dylib=System");
    }
}

fn resolve_lib_dir() -> PathBuf {
    if let Ok(custom) = env::var("PT_LIB_DIR") {
        return PathBuf::from(custom);
    }
    // Cargo runs build scripts with CWD = the package root.
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR set by cargo");
    PathBuf::from(manifest_dir)
        .join("..")
        .join("interface")
        .join("ffi")
        .join("zig-out")
        .join("lib")
}

fn static_lib_exists(dir: &Path) -> bool {
    // Zig produces libpt.a on POSIX, pt.lib on MSVC, libpt.a on MinGW.
    dir.join("libpt.a").is_file() || dir.join("pt.lib").is_file()
}

fn try_build_zig() {
    let manifest_dir = match env::var("CARGO_MANIFEST_DIR") {
        Ok(d) => d,
        Err(_) => return,
    };
    let zig_dir = PathBuf::from(manifest_dir)
        .join("..")
        .join("interface")
        .join("ffi");
    if !zig_dir.is_dir() {
        return;
    }
    let status = Command::new("zig")
        .arg("build")
        .arg("-Doptimize=ReleaseSafe")
        .current_dir(&zig_dir)
        .status();
    match status {
        Ok(s) if s.success() => {
            println!("cargo:warning=ephapax: built libpt via `zig build`");
        }
        Ok(s) => {
            println!(
                "cargo:warning=ephapax: `zig build` exited with status {}",
                s
            );
        }
        Err(e) => {
            println!(
                "cargo:warning=ephapax: could not run `zig build` ({}); \
                 ensure `zig` is on PATH or set PT_LIB_DIR.",
                e
            );
        }
    }
}
