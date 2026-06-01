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

// pt_layer_* — cross-language layer metadata stack.
extern fn pt_layer_stack_new() u64;
extern fn pt_layer_stack_free(stack_ptr: u64) void;
extern fn pt_layer_push(stack_ptr: u64, name_ptr: u64, name_len: u32) u32;
extern fn pt_layer_delete(stack_ptr: u64, id: u32) u32;
extern fn pt_layer_reorder_to(stack_ptr: u64, id: u32, new_position: u32) u32;
extern fn pt_layer_count(stack_ptr: u64) u32;
extern fn pt_layer_get_id_at(stack_ptr: u64, position: u32) u32;
extern fn pt_layer_get_name(
    stack_ptr: u64,
    id: u32,
    out_buf: u64,
    buf_size: u32,
    out_len: u64,
) u32;
extern fn pt_layer_set_opacity(stack_ptr: u64, id: u32, opacity_bits: u32) u32;
extern fn pt_layer_get_opacity(stack_ptr: u64, id: u32) u32;
extern fn pt_layer_set_visible(stack_ptr: u64, id: u32, visible: u32) u32;
extern fn pt_layer_get_visible(stack_ptr: u64, id: u32) u32;

//==============================================================================
// Constants (must match libpt)
//==============================================================================

const TILE_SIZE: u32 = 64;
const RESULT_OK: u32 = 0;
const RESULT_ERROR: u32 = 1;
const RESULT_INVALID_PARAM: u32 = 2;
const PT_LAYER_ID_NONE: u32 = 0;

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

//==============================================================================
// pt_layer_* integration tests
//==============================================================================

test "layer stack: new + free roundtrip" {
    const stack = pt_layer_stack_new();
    try std.testing.expect(stack != 0);
    try std.testing.expectEqual(@as(u32, 0), pt_layer_count(stack));
    pt_layer_stack_free(stack);
}

test "layer stack: free of null is safe" {
    pt_layer_stack_free(0);
    // Surviving this is the test.
}

test "layer push: id starts at 1 and increments" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const name1 = "Background";
    const id1 = pt_layer_push(stack, @intFromPtr(name1.ptr), name1.len);
    try std.testing.expectEqual(@as(u32, 1), id1);

    const name2 = "Sketch";
    const id2 = pt_layer_push(stack, @intFromPtr(name2.ptr), name2.len);
    try std.testing.expectEqual(@as(u32, 2), id2);

    try std.testing.expectEqual(@as(u32, 2), pt_layer_count(stack));
    try std.testing.expectEqual(id1, pt_layer_get_id_at(stack, 0));
    try std.testing.expectEqual(id2, pt_layer_get_id_at(stack, 1));
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_get_id_at(stack, 2));
}

test "layer push: empty / null name accepted" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const id_null = pt_layer_push(stack, 0, 0);
    try std.testing.expect(id_null != PT_LAYER_ID_NONE);

    const id_empty = pt_layer_push(stack, 0, 17); // null ptr + non-zero len → still 0 bytes
    try std.testing.expect(id_empty != PT_LAYER_ID_NONE);

    // Read back name length on the null-pointer push: should be 0.
    var buf: [16]u8 = undefined;
    var out_len: u32 = 0xFFFFFFFF;
    const rc = pt_layer_get_name(stack, id_null, @intFromPtr(&buf), buf.len, @intFromPtr(&out_len));
    try std.testing.expectEqual(RESULT_OK, rc);
    try std.testing.expectEqual(@as(u32, 0), out_len);
}

test "layer get_name: round-trips the bytes" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const name = "Highlights";
    const id = pt_layer_push(stack, @intFromPtr(name.ptr), name.len);
    try std.testing.expect(id != PT_LAYER_ID_NONE);

    var buf: [64]u8 = undefined;
    var out_len: u32 = 0;
    const rc = pt_layer_get_name(stack, id, @intFromPtr(&buf), buf.len, @intFromPtr(&out_len));
    try std.testing.expectEqual(RESULT_OK, rc);
    try std.testing.expectEqual(@as(u32, name.len), out_len);
    try std.testing.expectEqualSlices(u8, name, buf[0..out_len]);
}

test "layer delete: id removed and ids of other layers stable" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const a = pt_layer_push(stack, 0, 0);
    const b = pt_layer_push(stack, 0, 0);
    const c = pt_layer_push(stack, 0, 0);

    // Order: [a, b, c]
    try std.testing.expectEqual(@as(u32, 3), pt_layer_count(stack));

    const rc = pt_layer_delete(stack, b);
    try std.testing.expectEqual(RESULT_OK, rc);

    // Order now: [a, c] — b is gone, a and c keep their ids.
    try std.testing.expectEqual(@as(u32, 2), pt_layer_count(stack));
    try std.testing.expectEqual(a, pt_layer_get_id_at(stack, 0));
    try std.testing.expectEqual(c, pt_layer_get_id_at(stack, 1));

    // Deleting an unknown id is RESULT_ERROR.
    const rc_bad = pt_layer_delete(stack, 9999);
    try std.testing.expectEqual(RESULT_ERROR, rc_bad);
}

test "layer reorder_to: move top to bottom" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const a = pt_layer_push(stack, 0, 0);
    const b = pt_layer_push(stack, 0, 0);
    const c = pt_layer_push(stack, 0, 0);

    // Move c (top) to position 0.
    const rc = pt_layer_reorder_to(stack, c, 0);
    try std.testing.expectEqual(RESULT_OK, rc);

    // Order now: [c, a, b]
    try std.testing.expectEqual(c, pt_layer_get_id_at(stack, 0));
    try std.testing.expectEqual(a, pt_layer_get_id_at(stack, 1));
    try std.testing.expectEqual(b, pt_layer_get_id_at(stack, 2));
}

test "layer reorder_to: move bottom to top" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const a = pt_layer_push(stack, 0, 0);
    const b = pt_layer_push(stack, 0, 0);
    const c = pt_layer_push(stack, 0, 0);

    // Move a (bottom) to position 2 (top).
    const rc = pt_layer_reorder_to(stack, a, 2);
    try std.testing.expectEqual(RESULT_OK, rc);

    // Order now: [b, c, a]
    try std.testing.expectEqual(b, pt_layer_get_id_at(stack, 0));
    try std.testing.expectEqual(c, pt_layer_get_id_at(stack, 1));
    try std.testing.expectEqual(a, pt_layer_get_id_at(stack, 2));
}

test "layer reorder_to: out-of-bounds position is invalid_param" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const a = pt_layer_push(stack, 0, 0);
    _ = pt_layer_push(stack, 0, 0);

    const rc = pt_layer_reorder_to(stack, a, 99);
    try std.testing.expectEqual(RESULT_INVALID_PARAM, rc);
}

test "layer opacity: set + get round-trips and clamps" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const id = pt_layer_push(stack, 0, 0);

    // Default opacity = 1.0
    const default_opa: f32 = @bitCast(pt_layer_get_opacity(stack, id));
    try std.testing.expectEqual(@as(f32, 1.0), default_opa);

    // Set to 0.3, read back.
    const three_tenths: u32 = @bitCast(@as(f32, 0.3));
    try std.testing.expectEqual(RESULT_OK, pt_layer_set_opacity(stack, id, three_tenths));
    const read_back: f32 = @bitCast(pt_layer_get_opacity(stack, id));
    try std.testing.expect(@abs(read_back - 0.3) < 1e-6);

    // Clamp: 1.5 → 1.0.
    const too_high: u32 = @bitCast(@as(f32, 1.5));
    try std.testing.expectEqual(RESULT_OK, pt_layer_set_opacity(stack, id, too_high));
    const clamped_high: f32 = @bitCast(pt_layer_get_opacity(stack, id));
    try std.testing.expectEqual(@as(f32, 1.0), clamped_high);

    // Clamp: -0.5 → 0.0.
    const too_low: u32 = @bitCast(@as(f32, -0.5));
    try std.testing.expectEqual(RESULT_OK, pt_layer_set_opacity(stack, id, too_low));
    const clamped_low: f32 = @bitCast(pt_layer_get_opacity(stack, id));
    try std.testing.expectEqual(@as(f32, 0.0), clamped_low);

    // NaN → 1.0.
    const nan_bits: u32 = @bitCast(@as(f32, std.math.nan(f32)));
    try std.testing.expectEqual(RESULT_OK, pt_layer_set_opacity(stack, id, nan_bits));
    const clamped_nan: f32 = @bitCast(pt_layer_get_opacity(stack, id));
    try std.testing.expectEqual(@as(f32, 1.0), clamped_nan);
}

test "layer visibility: round-trips" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const id = pt_layer_push(stack, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), pt_layer_get_visible(stack, id));

    try std.testing.expectEqual(RESULT_OK, pt_layer_set_visible(stack, id, 0));
    try std.testing.expectEqual(@as(u32, 0), pt_layer_get_visible(stack, id));

    try std.testing.expectEqual(RESULT_OK, pt_layer_set_visible(stack, id, 42));
    try std.testing.expectEqual(@as(u32, 1), pt_layer_get_visible(stack, id));
}

test "layer: operations on bad-magic stack are rejected" {
    const stack = pt_layer_stack_new();
    pt_layer_stack_free(stack);
    // Stack is now freed — the magic word is poisoned. Operations on
    // it must NOT crash and must NOT mutate freed memory.
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_push(stack, 0, 0));
    try std.testing.expectEqual(RESULT_INVALID_PARAM, pt_layer_delete(stack, 1));
    try std.testing.expectEqual(@as(u32, 0), pt_layer_count(stack));
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_get_id_at(stack, 0));
}

test "layer: null stack returns errors uniformly" {
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_push(0, 0, 0));
    try std.testing.expectEqual(RESULT_INVALID_PARAM, pt_layer_delete(0, 1));
    try std.testing.expectEqual(RESULT_INVALID_PARAM, pt_layer_reorder_to(0, 1, 0));
    try std.testing.expectEqual(@as(u32, 0), pt_layer_count(0));
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_get_id_at(0, 0));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pt_layer_get_opacity(0, 1));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pt_layer_get_visible(0, 1));
}
