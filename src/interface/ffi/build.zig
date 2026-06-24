// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Build configuration for libpt (paint.type native FFI).
//
// Produces:
//   - libpt as a shared library  (.so / .dylib / .dll, depending on target)
//   - libpt as a static library  (.a / .lib)            for the Rust crate
//   - unit tests embedded in src/main.zig
//   - integration tests in test/integration_test.zig (linked against the
//     static libpt produced above)
//
// Steps exposed:
//   `zig build`         — builds both libraries (default)
//   `zig build lib`     — same, explicit
//   `zig build test`    — unit + integration tests
//
// Tested with Zig 0.15+.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //--------------------------------------------------------------------------
    // Module: libpt root source
    //--------------------------------------------------------------------------

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    //--------------------------------------------------------------------------
    // Shared library: libpt.so / libpt.dylib / pt.dll
    //--------------------------------------------------------------------------

    const shared = b.addLibrary(.{
        .name = "pt",
        .linkage = .dynamic,
        .root_module = root_module,
    });
    b.installArtifact(shared);

    //--------------------------------------------------------------------------
    // Static library: libpt.a (for the Rust crate)
    //--------------------------------------------------------------------------

    const static_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const static = b.addLibrary(.{
        .name = "pt",
        .linkage = .static,
        .root_module = static_module,
    });
    b.installArtifact(static);

    //--------------------------------------------------------------------------
    // `zig build lib` step: builds both libraries explicitly.
    //--------------------------------------------------------------------------

    const lib_step = b.step("lib", "Build libpt as both shared and static libraries");
    lib_step.dependOn(&b.addInstallArtifact(shared, .{}).step);
    lib_step.dependOn(&b.addInstallArtifact(static, .{}).step);

    //--------------------------------------------------------------------------
    // Unit tests (in src/main.zig)
    //--------------------------------------------------------------------------

    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_tests = b.addTest(.{
        .root_module = unit_test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    //--------------------------------------------------------------------------
    // Integration tests (in test/integration_test.zig, linked to static libpt)
    //--------------------------------------------------------------------------

    const integration_module = b.createModule(.{
        .root_source_file = b.path("test/integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });
    integration_tests.linkLibrary(static);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    //--------------------------------------------------------------------------
    // `zig build test` step
    //--------------------------------------------------------------------------

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    //--------------------------------------------------------------------------
    // Benchmarks (in test/bench.zig)
    //--------------------------------------------------------------------------

    // Like every other artifact above, the benchmark executable takes its
    // sources via an explicit module. The older `.root_source_file` field on
    // `addExecutable` was removed in Zig 0.15.2 (it survived as a deprecated
    // shim on 0.15.1, which is why CI stayed green while local 0.15.2 builds
    // broke here). The `b.createModule` form works on both.
    const bench_module = b.createModule(.{
        .root_source_file = b.path("test/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const bench_exe = b.addExecutable(.{
        .name = "pt_bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);

    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);
    }
