// SPDX-License-Identifier: MPL-2.0
//
// paint.type desktop shell — standalone Zig build (Zig 0.15+).
//
// Kept separate from the root build.zig on purpose: the shell links the
// platform webview stack (GTK 3 + WebKitGTK 4.1 on Linux), which the headless
// dispatcher/CPU-reference build and its cross-OS CI matrix must NOT require.
// tests/e2e.sh builds this only on a platform that has the webview toolkit.
//
// Linux/BSD system deps: libgtk-3-dev libwebkit2gtk-4.1-dev (Debian) /
// gtk3-devel webkit2gtk4.1-devel (Fedora).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;

    switch (target.result.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd => {
            mod.linkSystemLibrary("gtk+-3.0", .{});
            mod.linkSystemLibrary("webkit2gtk-4.1", .{});
            mod.linkSystemLibrary("glib-2.0", .{});
        },
        .macos => {
            mod.linkFramework("Cocoa", .{});
            mod.linkFramework("WebKit", .{});
        },
        else => {},
    }

    const exe = b.addExecutable(.{
        .name = "paint-type-shell",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Build and launch the paint.type desktop shell");
    run_step.dependOn(&run_cmd.step);
}
