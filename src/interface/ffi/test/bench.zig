// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Joshua Jewell (JoshuaJewell) <paint-type@pm.me>
//
// pt_core_bench — Performance benchmarks for the paint.type FFI core.
// Measures tile allocation, fill, and pixel access speeds.

const std = @import("std");
const pt = @import("../src/main.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var timer = try std.time.Timer.start();

    try stdout.print("═══════════════════════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("paint.type FFI Core Benchmarks\n", .{});
    try stdout.print("═══════════════════════════════════════════════════════════════════════════════\n\n", .{});

    //---------------------------------------------------------
    // Benchmark 1: Tile Allocation/Free
    //---------------------------------------------------------
    {
        const iterations = 100_000;
        timer.reset();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const tile = pt.pt_tile_alloc(0, 0);
            pt.pt_tile_free(tile);
        }
        const elapsed = timer.read();
        const per_op = elapsed / iterations;
        try stdout.print("Tile Alloc/Free ({d} iterations):\n", .{iterations});
        try stdout.print("  Total: {d:.3}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
        try stdout.print("  Mean:  {d}ns per op\n\n", .{per_op});
    }

    //---------------------------------------------------------
    // Benchmark 2: Tile Fill (RGBA16F)
    //---------------------------------------------------------
    {
        const iterations = 10_000;
        const tile = pt.pt_tile_alloc(0, 0);
        defer pt.pt_tile_free(tile);

        timer.reset();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = pt.pt_tile_fill(tile, 0x3C00, 0x3C00, 0x3C00, 0x3C00); // 1.0, 1.0, 1.0, 1.0
        }
        const elapsed = timer.read();
        const per_op = elapsed / iterations;
        try stdout.print("Tile Fill ({d} iterations):\n", .{iterations});
        try stdout.print("  Total: {d:.3}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
        try stdout.print("  Mean:  {d}ns per op\n\n", .{per_op});
    }

    //---------------------------------------------------------
    // Benchmark 3: Random Pixel Access (Read/Write)
    //---------------------------------------------------------
    {
        const iterations = 1_000_000;
        const tile = pt.pt_tile_alloc(0, 0);
        defer pt.pt_tile_free(tile);

        var prng = std.rand.DefaultPrng.init(42);
        const random = prng.random();

        timer.reset();
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const x = random.uintLessThan(u32, pt.TILE_SIZE);
            const y = random.uintLessThan(u32, pt.TILE_SIZE);
            _ = pt.pt_tile_write_pixel(tile, x, y, 0, 0, 0, 0);
        }
        const elapsed = timer.read();
        const per_op = elapsed / iterations;
        try stdout.print("Pixel Write ({d} iterations, random coords):\n", .{iterations});
        try stdout.print("  Total: {d:.3}ms\n", .{@as(f64, @floatFromInt(elapsed)) / 1_000_000.0});
        try stdout.print("  Mean:  {d}ns per op\n\n", .{per_op});
    }
}
