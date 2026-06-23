// SPDX-License-Identifier: AGPL-3.0-or-later
//
// paint.type — top-level Zig build.
//
// Governed by ADR-0002. Builds:
//
//   * libpaint_type.{a,so}  — dispatcher + CPU reference backend, one library.
//   * composite_demo        — example exercising the layer compositing path.
//
// Targets to add as backends land: paint-type (the unified API server),
// per-backend object files (vector, gpu, …).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------
    // Modules — exposed to every executable / library in this build.
    // -----------------------------------------------------------------
    const dispatcher_mod = b.createModule(.{
        .root_source_file = b.path("src/backends/dispatcher.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cpu_mod = b.createModule(.{
        .root_source_file = b.path("src/backends/cpu/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dispatcher", .module = dispatcher_mod },
        },
    });

    // -----------------------------------------------------------------
    // libpaint_type — dispatcher + CPU reference, as one library.
    // -----------------------------------------------------------------
    const lib = b.addLibrary(.{
        .name = "paint_type",
        .linkage = .static,
        .root_module = dispatcher_mod,
    });
    lib.root_module.addImport("cpu_reference", cpu_mod);
    b.installArtifact(lib);

    // -----------------------------------------------------------------
    // composite_demo — exercises the layer compositing path end-to-end.
    // -----------------------------------------------------------------
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/composite_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dispatcher", .module = dispatcher_mod },
            .{ .name = "cpu", .module = cpu_mod },
        },
    });
    const demo = b.addExecutable(.{
        .name = "composite_demo",
        .root_module = demo_mod,
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    const demo_step = b.step("demo", "Run the layer-compositing demo");
    demo_step.dependOn(&run_demo.step);

    // brush_demo — MVP-3 brush stroke demo.
    const brush_mod = b.createModule(.{
        .root_source_file = b.path("examples/brush_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dispatcher", .module = dispatcher_mod },
            .{ .name = "cpu", .module = cpu_mod },
        },
    });
    const brush_exe = b.addExecutable(.{
        .name = "brush_demo",
        .root_module = brush_mod,
    });
    b.installArtifact(brush_exe);

    const run_brush = b.addRunArtifact(brush_exe);
    run_brush.step.dependOn(b.getInstallStep());
    const brush_step = b.step("brush", "Run the brush-stroke demo");
    brush_step.dependOn(&run_brush.step);

    // undo_demo — MVP-10 persistent undo graph.
    const undo_mod = b.createModule(.{
        .root_source_file = b.path("examples/undo_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dispatcher", .module = dispatcher_mod },
            .{ .name = "cpu", .module = cpu_mod },
        },
    });
    const undo_exe = b.addExecutable(.{
        .name = "undo_demo",
        .root_module = undo_mod,
    });
    b.installArtifact(undo_exe);
    const run_undo = b.addRunArtifact(undo_exe);
    run_undo.step.dependOn(b.getInstallStep());
    const undo_step = b.step("undo", "Run the undo-graph demo");
    undo_step.dependOn(&run_undo.step);

    // -----------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------
    const dispatcher_tests = b.addTest(.{ .root_module = dispatcher_mod });
    const cpu_tests = b.addTest(.{ .root_module = cpu_mod });
    const run_dispatcher_tests = b.addRunArtifact(dispatcher_tests);
    const run_cpu_tests = b.addRunArtifact(cpu_tests);
    const test_step = b.step("test", "Run dispatcher + CPU-reference unit tests");
    test_step.dependOn(&run_dispatcher_tests.step);
    test_step.dependOn(&run_cpu_tests.step);

    // VerisimDB storage client (skeleton)
    const verisimdb_mod = b.createModule(.{
        .root_source_file = b.path("src/backends/storage/verisimdb.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const verisimdb_tests = b.addTest(.{ .root_module = verisimdb_mod });
    const run_verisimdb_tests = b.addRunArtifact(verisimdb_tests);
    test_step.dependOn(&run_verisimdb_tests.step);
}
