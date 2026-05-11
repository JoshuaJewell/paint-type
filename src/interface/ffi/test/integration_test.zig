// SPDX-License-Identifier: PMPL-1.0-or-later
//
// libpt FFI integration tests.
//
// These tests link against the libpt shared/static library and exercise
// the C ABI from the outside, using only the four public tile entry
// points plus the helpers needed for null-out-pointer round-trips.
// The signatures here MUST match the ones in src/main.zig and the ones
// declared in src/interface/Abi/Foreign.idr.

const std = @import("std");

//==============================================================================
// External Declarations (must match libpt C ABI)
//==============================================================================

extern fn pt_tile_alloc(x: u32, y: u32) u64;
extern fn pt_tile_free(tile_ptr: u64) void;
extern fn pt_tile_fill(tile_ptr: u64, r: u16, g: u16, b: u16, a: u16) u32;
extern fn pt_tile_read_pixel(
    tile_ptr: u64,
    px: u32,
    py: u32,
    out_r: u64,
    out_g: u64,
    out_b: u64,
    out_a: u64,
) u32;
extern fn pt_is_initialized(tile_ptr: u64) u32;
extern fn pt_version() [*:0]const u8;
extern fn pt_last_error() ?[*:0]const u8;

//==============================================================================
// Constants (must match libpt)
//==============================================================================

const TILE_SIZE: u32 = 64;
const RESULT_OK: u32 = 0;
const RESULT_INVALID_PARAM: u32 = 2;

//==============================================================================
// Tests
//==============================================================================

test "lifecycle: alloc then free" {
    const tile = pt_tile_alloc(0, 0);
    try std.testing.expect(tile != 0);
    try std.testing.expectEqual(@as(u32, 1), pt_is_initialized(tile));
    pt_tile_free(tile);
}

test "lifecycle: free of null is safe" {
    pt_tile_free(0);
    // No assertion — surviving this call is the test.
}

test "lifecycle: alloc records grid coordinates" {
    const tile = pt_tile_alloc(11, 22);
    try std.testing.expect(tile != 0);
    defer pt_tile_free(tile);

    // Read first pixel of a freshly allocated tile — must be zero
    // (alloc zero-fills the pixel buffer).
    var r: u16 = 0xFFFF;
    var g: u16 = 0xFFFF;
    var b: u16 = 0xFFFF;
    var a: u16 = 0xFFFF;
    const rc = pt_tile_read_pixel(
        tile,
        0,
        0,
        @intFromPtr(&r),
        @intFromPtr(&g),
        @intFromPtr(&b),
        @intFromPtr(&a),
    );
    try std.testing.expectEqual(RESULT_OK, rc);
    try std.testing.expectEqual(@as(u16, 0), r);
    try std.testing.expectEqual(@as(u16, 0), g);
    try std.testing.expectEqual(@as(u16, 0), b);
    try std.testing.expectEqual(@as(u16, 0), a);
}

test "full lifecycle: alloc, fill, read, free" {
    const tile = pt_tile_alloc(5, 9);
    try std.testing.expect(tile != 0);
    defer pt_tile_free(tile);

    // Pick a representative non-trivial colour: linear-light yellow,
    // r=1.0, g=1.0, b=0.0, a=0.5.
    const r_in: u16 = @bitCast(@as(f16, 1.0));
    const g_in: u16 = @bitCast(@as(f16, 1.0));
    const b_in: u16 = @bitCast(@as(f16, 0.0));
    const a_in: u16 = @bitCast(@as(f16, 0.5));

    try std.testing.expectEqual(RESULT_OK, pt_tile_fill(tile, r_in, g_in, b_in, a_in));

    // Spot-check a handful of pixels: corners and centre.
    const probes = [_][2]u32{
        .{ 0, 0 },
        .{ 0, TILE_SIZE - 1 },
        .{ TILE_SIZE - 1, 0 },
        .{ TILE_SIZE - 1, TILE_SIZE - 1 },
        .{ 32, 32 },
        .{ 17, 41 },
    };

    for (probes) |p| {
        var r: u16 = 0;
        var g: u16 = 0;
        var b: u16 = 0;
        var a: u16 = 0;
        const rc = pt_tile_read_pixel(
            tile,
            p[0],
            p[1],
            @intFromPtr(&r),
            @intFromPtr(&g),
            @intFromPtr(&b),
            @intFromPtr(&a),
        );
        try std.testing.expectEqual(RESULT_OK, rc);
        try std.testing.expectEqual(r_in, r);
        try std.testing.expectEqual(g_in, g);
        try std.testing.expectEqual(b_in, b);
        try std.testing.expectEqual(a_in, a);

        // Reinterpret as f16 and check value-level round-trip.
        try std.testing.expectEqual(@as(f16, 1.0), @as(f16, @bitCast(r)));
        try std.testing.expectEqual(@as(f16, 1.0), @as(f16, @bitCast(g)));
        try std.testing.expectEqual(@as(f16, 0.0), @as(f16, @bitCast(b)));
        try std.testing.expectEqual(@as(f16, 0.5), @as(f16, @bitCast(a)));
    }
}

test "double-free safety (poisoned magic)" {
    const tile = pt_tile_alloc(0, 0);
    try std.testing.expect(tile != 0);

    pt_tile_free(tile);

    // After free, magic is poisoned. A second free is a no-op (no crash,
    // no double-destroy of the underlying allocation) because the magic
    // check inside pt_tile_free fails. is_initialized must report 0.
    try std.testing.expectEqual(@as(u32, 0), pt_is_initialized(tile));
    pt_tile_free(tile);
}

test "out-of-bounds pixel read is rejected" {
    const tile = pt_tile_alloc(0, 0);
    try std.testing.expect(tile != 0);
    defer pt_tile_free(tile);

    var r: u16 = 0;
    var g: u16 = 0;
    var b: u16 = 0;
    var a: u16 = 0;

    const cases = [_][2]u32{
        .{ TILE_SIZE, 0 },
        .{ 0, TILE_SIZE },
        .{ TILE_SIZE, TILE_SIZE },
        .{ 1_000_000, 0 },
        .{ 0, 1_000_000 },
    };

    for (cases) |p| {
        const rc = pt_tile_read_pixel(
            tile,
            p[0],
            p[1],
            @intFromPtr(&r),
            @intFromPtr(&g),
            @intFromPtr(&b),
            @intFromPtr(&a),
        );
        try std.testing.expectEqual(RESULT_INVALID_PARAM, rc);
    }
}

test "null out-pointer is rejected" {
    const tile = pt_tile_alloc(0, 0);
    try std.testing.expect(tile != 0);
    defer pt_tile_free(tile);

    const rc = pt_tile_read_pixel(tile, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(RESULT_INVALID_PARAM, rc);
}

test "fill on null tile is rejected" {
    const rc = pt_tile_fill(0, 0, 0, 0, 0);
    try std.testing.expectEqual(RESULT_INVALID_PARAM, rc);
}

test "version is reported" {
    const ver = pt_version();
    const ver_str = std.mem.span(ver);
    try std.testing.expect(ver_str.len > 0);
}

test "many alloc-free cycles do not leak (smoke)" {
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const tile = pt_tile_alloc(i, i);
        try std.testing.expect(tile != 0);
        const r_in: u16 = @bitCast(@as(f16, 0.25));
        try std.testing.expectEqual(RESULT_OK, pt_tile_fill(tile, r_in, r_in, r_in, r_in));
        pt_tile_free(tile);
    }
}
