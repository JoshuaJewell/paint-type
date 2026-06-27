// SPDX-License-Identifier: AGPL-3.0-or-later
//
// libpt — paint.type native FFI implementation.
//
// Implements the C ABI declared in src/interface/Abi/Foreign.idr.
// All exported symbols are prefixed `pt_`.
//
// Memory model:
//   - One PtTile lives at a single C-allocator allocation. The 16-byte
//     header (x, y, width=64, height=64) is followed immediately by
//     32768 bytes of pixel data (64*64*4 channels of f16). A `magic`
//     u32 sits at offset 16 inside the header — wait, no: the magic
//     occupies offset 0 of the header for cheap validation, with the
//     coordinate fields after it. See `PtTile` below for the canonical
//     order; the Idris2 layout proof uses the same offsets.
//   - Linear ownership: every successful pt_tile_alloc is balanced by
//     exactly one pt_tile_free. Calling free on a null pointer is a
//     documented no-op.

const std = @import("std");
const builtin = @import("builtin");

//==============================================================================
// Constants
//==============================================================================

const VERSION: [:0]const u8 = "0.1.0";

/// Tile edge length in pixels. Matches `Abi.Types.TileSize`.
pub const TILE_SIZE: u32 = 64;

/// Channels per pixel for RGBA16F. Matches `Abi.Types.channelCount`.
pub const TILE_CHANNELS: u32 = 4;

/// Total f16 elements in one tile's pixel buffer (64 * 64 * 4 = 16384).
pub const TILE_PIXEL_SCALARS: usize = @as(usize, TILE_SIZE) * TILE_SIZE * TILE_CHANNELS;

/// Total byte count of one tile's pixel buffer (16384 * 2 = 32768).
pub const TILE_PIXEL_BYTES: usize = TILE_PIXEL_SCALARS * @sizeOf(f16);

/// Magic value for live PtTile structs. ASCII "PTLE" big-endian.
const PT_TILE_MAGIC: u32 = 0x50544C45;

/// Magic value written into a tile header when it has been freed; lets
/// pt_tile_free detect double-frees in debug builds.
const PT_TILE_DEAD_MAGIC: u32 = 0x44454144; // "DEAD"

//==============================================================================
// Result Codes
//==============================================================================

/// Result codes. Numeric encoding matches Abi.Types.resultFromCode in Idris2.
pub const Result = enum(u32) {
    ok = 0,
    @"error" = 1,
    invalid_param = 2,
    busy = 3,
};

//==============================================================================
// Error Reporting
//==============================================================================

/// Thread-local last-error string. Static-storage messages only — never
/// freed by `pt_last_error`.
threadlocal var last_error: ?[:0]const u8 = null;

fn setError(msg: [:0]const u8) void {
    last_error = msg;
}

fn clearError() void {
    last_error = null;
}

//==============================================================================
// PtTile
//==============================================================================

/// The on-heap representation of a tile.
///
/// Layout (extern struct, no compiler reordering):
///   offset  size  field
///   ------  ----  -----
///        0     4  magic     (PT_TILE_MAGIC when live)
///        4     4  x         (grid x)
///        8     4  y         (grid y)
///       12     4  width     (always TILE_SIZE)
///       16     4  height    (always TILE_SIZE)
///       20     4  _pad      (alignment to 8 for the f16 array)
///       24 32768  pixels    (RGBA16F, row-major)
///
/// Note: The Idris2 layout proof in Abi.Layout describes a 16-byte header
/// without `magic`. The on-disk/over-the-wire ABI for the *coordinate*
/// fields matches: (x, y, width, height) at offsets (0, 4, 8, 12) of a
/// header that begins after the magic word. C/Idris2 callers consume the
/// pointer returned by pt_tile_alloc as opaque; only this Zig file
/// dereferences it as a PtTile, so the magic prefix is safe.
///
/// (If you want the layout proof to literally cover `magic`, extend
/// tileLayout with a leading `magic: u32` field. Both descriptions are
/// internally consistent; we keep the prover-facing struct minimal.)
pub const PtTile = extern struct {
    magic: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    _pad: u32,
    pixels: [TILE_PIXEL_SCALARS]f16,

    fn isLive(self: *const PtTile) bool {
        return self.magic == PT_TILE_MAGIC;
    }
};

comptime {
    // Compile-time sanity: pixel buffer is exactly 32768 bytes.
    std.debug.assert(@sizeOf([TILE_PIXEL_SCALARS]f16) == 32768);
    // Header (everything before pixels) is 24 bytes — 4 (magic) + 4*4 (coords) + 4 (pad).
    std.debug.assert(@offsetOf(PtTile, "pixels") == 24);
}

//==============================================================================
// Allocation
//==============================================================================

/// Allocate a 64x64 RGBA16F tile at grid position (x, y).
/// Returns the pointer cast to u64, or 0 on out-of-memory.
export fn pt_tile_alloc(x: u32, y: u32) u64 {
    const allocator = std.heap.c_allocator;

    const tile = allocator.create(PtTile) catch {
        setError("pt_tile_alloc: out of memory");
        return 0;
    };

    tile.* = .{
        .magic = PT_TILE_MAGIC,
        .x = x,
        .y = y,
        .width = TILE_SIZE,
        .height = TILE_SIZE,
        ._pad = 0,
        .pixels = [_]f16{0} ** TILE_PIXEL_SCALARS,
    };

    clearError();
    return @intFromPtr(tile);
}

/// Free a tile. Safe to call with 0.
/// In debug builds, refuses to double-free by checking the magic word.
export fn pt_tile_free(tile_ptr: u64) void {
    if (tile_ptr == 0) return;

    const tile: *PtTile = @ptrFromInt(tile_ptr);
    if (tile.magic != PT_TILE_MAGIC) {
        // Double-free or corruption. Refuse rather than crash.
        setError("pt_tile_free: invalid or already-freed tile");
        return;
    }

    // Poison the magic so a subsequent free is detected.
    tile.magic = PT_TILE_DEAD_MAGIC;

    const allocator = std.heap.c_allocator;
    allocator.destroy(tile);
    clearError();
}

//==============================================================================
// Operations
//==============================================================================

/// Fill all pixels with one RGBA16F colour.
/// Channel arguments carry the bit patterns of f16 values.
export fn pt_tile_fill(tile_ptr: u64, r: u16, g: u16, b: u16, a: u16) u32 {
    if (tile_ptr == 0) {
        setError("pt_tile_fill: null tile");
        return @intFromEnum(Result.invalid_param);
    }

    const tile: *PtTile = @ptrFromInt(tile_ptr);
    if (!tile.isLive()) {
        setError("pt_tile_fill: invalid tile (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }

    const rf: f16 = @bitCast(r);
    const gf: f16 = @bitCast(g);
    const bf: f16 = @bitCast(b);
    const af: f16 = @bitCast(a);

    var i: usize = 0;
    while (i < TILE_PIXEL_SCALARS) : (i += 4) {
        tile.pixels[i + 0] = rf;
        tile.pixels[i + 1] = gf;
        tile.pixels[i + 2] = bf;
        tile.pixels[i + 3] = af;
    }

    clearError();
    return @intFromEnum(Result.ok);
}

/// Read one pixel from inside the tile.
/// out_r/g/b/a are u64 addresses of u16 destinations.
/// Returns 0 on success, non-zero on null/out-of-bounds.
export fn pt_tile_read_pixel(
    tile_ptr: u64,
    px: u32,
    py: u32,
    out_r: u64,
    out_g: u64,
    out_b: u64,
    out_a: u64,
) u32 {
    if (tile_ptr == 0) {
        setError("pt_tile_read_pixel: null tile");
        return @intFromEnum(Result.invalid_param);
    }
    if (out_r == 0 or out_g == 0 or out_b == 0 or out_a == 0) {
        setError("pt_tile_read_pixel: null output pointer");
        return @intFromEnum(Result.invalid_param);
    }
    if (px >= TILE_SIZE or py >= TILE_SIZE) {
        setError("pt_tile_read_pixel: pixel out of bounds");
        return @intFromEnum(Result.invalid_param);
    }

    const tile: *PtTile = @ptrFromInt(tile_ptr);
    if (!tile.isLive()) {
        setError("pt_tile_read_pixel: invalid tile (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }

    const base: usize = (@as(usize, py) * TILE_SIZE + @as(usize, px)) * TILE_CHANNELS;

    const r_ptr: *u16 = @ptrFromInt(out_r);
    const g_ptr: *u16 = @ptrFromInt(out_g);
    const b_ptr: *u16 = @ptrFromInt(out_b);
    const a_ptr: *u16 = @ptrFromInt(out_a);

    r_ptr.* = @bitCast(tile.pixels[base + 0]);
    g_ptr.* = @bitCast(tile.pixels[base + 1]);
    b_ptr.* = @bitCast(tile.pixels[base + 2]);
    a_ptr.* = @bitCast(tile.pixels[base + 3]);

    clearError();
    return @intFromEnum(Result.ok);
}

/// Write one pixel inside the tile.
/// Channel arguments carry the bit patterns of f16 values.
/// Returns 0 on success, non-zero on null/out-of-bounds.
export fn pt_tile_write_pixel(
    tile_ptr: u64,
    px: u32,
    py: u32,
    r: u16,
    g: u16,
    b: u16,
    a: u16,
) u32 {
    if (tile_ptr == 0) {
        setError("pt_tile_write_pixel: null tile");
        return @intFromEnum(Result.invalid_param);
    }
    if (px >= TILE_SIZE or py >= TILE_SIZE) {
        setError("pt_tile_write_pixel: pixel out of bounds");
        return @intFromEnum(Result.invalid_param);
    }

    const tile: *PtTile = @ptrFromInt(tile_ptr);
    if (!tile.isLive()) {
        setError("pt_tile_write_pixel: invalid tile (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }

    const base: usize = (@as(usize, py) * TILE_SIZE + @as(usize, px)) * TILE_CHANNELS;
    tile.pixels[base + 0] = @bitCast(r);
    tile.pixels[base + 1] = @bitCast(g);
    tile.pixels[base + 2] = @bitCast(b);
    tile.pixels[base + 3] = @bitCast(a);

    clearError();
    return @intFromEnum(Result.ok);
}

/// Copy the whole RGBA16F tile buffer into `out_ptr`.
/// `out_ptr` must address at least TILE_PIXEL_SCALARS u16 elements.
export fn pt_tile_read_buffer(tile_ptr: u64, out_ptr: u64) u32 {
    if (tile_ptr == 0) {
        setError("pt_tile_read_buffer: null tile");
        return @intFromEnum(Result.invalid_param);
    }
    if (out_ptr == 0) {
        setError("pt_tile_read_buffer: null output pointer");
        return @intFromEnum(Result.invalid_param);
    }

    const tile: *const PtTile = @ptrFromInt(tile_ptr);
    if (!tile.isLive()) {
        setError("pt_tile_read_buffer: invalid tile (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }

    const out: [*]u16 = @ptrFromInt(out_ptr);
    var i: usize = 0;
    while (i < TILE_PIXEL_SCALARS) : (i += 1) {
        out[i] = @bitCast(tile.pixels[i]);
    }

    clearError();
    return @intFromEnum(Result.ok);
}

/// Copy the whole RGBA16F tile buffer from `in_ptr`.
/// `in_ptr` must address at least TILE_PIXEL_SCALARS u16 elements.
export fn pt_tile_write_buffer(tile_ptr: u64, in_ptr: u64) u32 {
    if (tile_ptr == 0) {
        setError("pt_tile_write_buffer: null tile");
        return @intFromEnum(Result.invalid_param);
    }
    if (in_ptr == 0) {
        setError("pt_tile_write_buffer: null input pointer");
        return @intFromEnum(Result.invalid_param);
    }

    const tile: *PtTile = @ptrFromInt(tile_ptr);
    if (!tile.isLive()) {
        setError("pt_tile_write_buffer: invalid tile (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }

    const input: [*]const u16 = @ptrFromInt(in_ptr);
    var i: usize = 0;
    while (i < TILE_PIXEL_SCALARS) : (i += 1) {
        tile.pixels[i] = @bitCast(input[i]);
    }

    clearError();
    return @intFromEnum(Result.ok);
}

//==============================================================================
// Idris2 Out-Parameter Slot Helpers
//==============================================================================
//
// Idris2's FFI cannot allocate raw u16 stack slots and pass their addresses
// to a C function. These three helpers let the safe wrapper in Foreign.idr
// allocate, read, and free a one-u16 slot on the C heap.

export fn pt_alloc_u16_slot() u64 {
    const allocator = std.heap.c_allocator;
    const slot = allocator.create(u16) catch {
        setError("pt_alloc_u16_slot: out of memory");
        return 0;
    };
    slot.* = 0;
    return @intFromPtr(slot);
}

export fn pt_read_u16_slot(slot_ptr: u64) u16 {
    if (slot_ptr == 0) return 0;
    const slot: *const u16 = @ptrFromInt(slot_ptr);
    return slot.*;
}

export fn pt_free_u16_slot(slot_ptr: u64) void {
    if (slot_ptr == 0) return;
    const allocator = std.heap.c_allocator;
    const slot: *u16 = @ptrFromInt(slot_ptr);
    allocator.destroy(slot);
}

//==============================================================================
// PtLayerStack — cross-language layer-metadata stack
//==============================================================================
//
// The canonical implementation of the `pt_layer_*` C ABI consumed by the Rust
// `paint_core` crate (see its `unsafe extern "C"` block). A PtLayerStack is an
// ordered list of layer records; index 0 is the *bottom* of the stack and the
// last element is the *top*. `pt_layer_push` appends a new layer at the top and
// issues a fresh, non-zero, monotonically-increasing id. Ids are stable across
// reordering and never reused, so a caller can hold an id and address the same
// layer regardless of its position.
//
// Pointers cross the boundary as u64 (cast via @ptrFromInt), matching the tile
// ABI above. Opacity crosses as the IEEE-754 binary32 bit-pattern of an f32.
// All entry points are null- and liveness-checked; a stale or null handle is a
// reported error (Result.error / PT_LAYER_ID_NONE), never a crash.

/// Sentinel "no such layer" id. Real ids start at 1, so 0 is always invalid.
const PT_LAYER_ID_NONE: u32 = 0;

/// Magic for a live PtLayerStack. ASCII "PLST".
const PT_LSTACK_MAGIC: u32 = 0x504C5354;
/// Magic stamped into a freed stack header to catch double-free.
const PT_LSTACK_DEAD: u32 = 0x44454144; // "DEAD"

const Layer = struct {
    id: u32,
    /// Owned UTF-8 name (c_allocator). Zero-length names carry an empty,
    /// non-heap slice and are never freed.
    name: []u8,
    /// Clamped to [0, 1]; NaN inputs are normalised to 1.0.
    opacity: f32,
    visible: bool,
};

const PtLayerStack = struct {
    magic: u32,
    next_id: u32,
    layers: std.ArrayListUnmanaged(Layer),

    fn isLive(self: *const PtLayerStack) bool {
        return self.magic == PT_LSTACK_MAGIC;
    }

    fn indexOf(self: *const PtLayerStack, id: u32) ?usize {
        for (self.layers.items, 0..) |layer, i| {
            if (layer.id == id) return i;
        }
        return null;
    }
};

/// Resolve a u64 handle to a live stack, or null if null/stale.
fn liveStack(stack_ptr: u64) ?*PtLayerStack {
    if (stack_ptr == 0) return null;
    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) return null;
    return stack;
}

/// Normalise an f32 opacity bit-pattern: NaN → 1.0, then clamp to [0, 1].
fn sanitizeOpacity(opacity_bits: u32) f32 {
    const v: f32 = @bitCast(opacity_bits);
    if (std.math.isNan(v)) return 1.0;
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

/// Allocate a fresh, empty stack. Returns the handle, or 0 on OOM.
export fn pt_layer_stack_new() u64 {
    const allocator = std.heap.c_allocator;
    const stack = allocator.create(PtLayerStack) catch {
        setError("pt_layer_stack_new: out of memory");
        return 0;
    };
    stack.* = .{ .magic = PT_LSTACK_MAGIC, .next_id = 1, .layers = .empty };
    clearError();
    return @intFromPtr(stack);
}

/// Free a stack and every owned layer name. Safe to call with 0.
export fn pt_layer_stack_free(stack_ptr: u64) void {
    if (stack_ptr == 0) return;
    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) {
        setError("pt_layer_stack_free: invalid or already-freed stack");
        return;
    }
    const allocator = std.heap.c_allocator;
    for (stack.layers.items) |layer| {
        if (layer.name.len > 0) allocator.free(layer.name);
    }
    stack.layers.deinit(allocator);
    stack.magic = PT_LSTACK_DEAD;
    allocator.destroy(stack);
    clearError();
}

/// Push a new layer at the top. Returns its fresh non-zero id, or
/// PT_LAYER_ID_NONE on invalid stack, bad arguments, id exhaustion, or OOM.
export fn pt_layer_push(stack_ptr: u64, name_ptr: u64, name_len: u32) u32 {
    const stack = liveStack(stack_ptr) orelse {
        setError("pt_layer_push: invalid stack");
        return PT_LAYER_ID_NONE;
    };
    if (stack.next_id == std.math.maxInt(u32)) {
        setError("pt_layer_push: layer id space exhausted");
        return PT_LAYER_ID_NONE;
    }
    const allocator = std.heap.c_allocator;

    var name_copy: []u8 = &[_]u8{};
    if (name_len > 0) {
        if (name_ptr == 0) {
            setError("pt_layer_push: null name pointer with non-zero length");
            return PT_LAYER_ID_NONE;
        }
        const src: [*]const u8 = @ptrFromInt(name_ptr);
        name_copy = allocator.alloc(u8, name_len) catch {
            setError("pt_layer_push: out of memory (name)");
            return PT_LAYER_ID_NONE;
        };
        @memcpy(name_copy, src[0..name_len]);
    }

    const id = stack.next_id;
    stack.layers.append(allocator, .{
        .id = id,
        .name = name_copy,
        .opacity = 1.0,
        .visible = true,
    }) catch {
        if (name_copy.len > 0) allocator.free(name_copy);
        setError("pt_layer_push: out of memory (append)");
        return PT_LAYER_ID_NONE;
    };
    stack.next_id += 1;
    clearError();
    return id;
}

/// Delete the layer with `id`. Returns Result.ok, or Result.error if the
/// stack is invalid or the id is unknown.
export fn pt_layer_delete(stack_ptr: u64, id: u32) u32 {
    const stack = liveStack(stack_ptr) orelse return @intFromEnum(Result.@"error");
    const idx = stack.indexOf(id) orelse {
        setError("pt_layer_delete: unknown id");
        return @intFromEnum(Result.@"error");
    };
    const allocator = std.heap.c_allocator;
    const removed = stack.layers.orderedRemove(idx);
    if (removed.name.len > 0) allocator.free(removed.name);
    clearError();
    return @intFromEnum(Result.ok);
}

/// Move the layer with `id` to 0-based `new_position`, preserving the relative
/// order of the others. Returns Result.ok, or Result.error on invalid stack,
/// unknown id, or out-of-range position.
export fn pt_layer_reorder_to(stack_ptr: u64, id: u32, new_position: u32) u32 {
    const stack = liveStack(stack_ptr) orelse return @intFromEnum(Result.@"error");
    const idx = stack.indexOf(id) orelse {
        setError("pt_layer_reorder_to: unknown id");
        return @intFromEnum(Result.@"error");
    };
    if (new_position >= stack.layers.items.len) {
        setError("pt_layer_reorder_to: position out of bounds");
        return @intFromEnum(Result.@"error");
    }
    const allocator = std.heap.c_allocator;
    const layer = stack.layers.orderedRemove(idx);
    stack.layers.insert(allocator, new_position, layer) catch {
        // Re-append rather than drop the layer on OOM.
        stack.layers.append(allocator, layer) catch {
            if (layer.name.len > 0) allocator.free(layer.name);
        };
        setError("pt_layer_reorder_to: out of memory");
        return @intFromEnum(Result.@"error");
    };
    clearError();
    return @intFromEnum(Result.ok);
}

/// Number of layers in the stack (0 for an invalid handle).
export fn pt_layer_count(stack_ptr: u64) u32 {
    const stack = liveStack(stack_ptr) orelse return 0;
    return @intCast(stack.layers.items.len);
}

/// Id of the layer at 0-based `position`, or PT_LAYER_ID_NONE if out of range.
export fn pt_layer_get_id_at(stack_ptr: u64, position: u32) u32 {
    const stack = liveStack(stack_ptr) orelse return PT_LAYER_ID_NONE;
    if (position >= stack.layers.items.len) return PT_LAYER_ID_NONE;
    return stack.layers.items[position].id;
}

/// Copy the UTF-8 name of layer `id` into the caller buffer and write the true
/// byte length through `out_len` (a *u32). The length is written even when the
/// buffer is too small, so a caller can resize and retry. Returns Result.ok,
/// or Result.error on invalid stack, unknown id, or insufficient buffer.
export fn pt_layer_get_name(
    stack_ptr: u64,
    id: u32,
    out_buf: u64,
    buf_size: u32,
    out_len: u64,
) u32 {
    const stack = liveStack(stack_ptr) orelse return @intFromEnum(Result.@"error");
    const idx = stack.indexOf(id) orelse {
        setError("pt_layer_get_name: unknown id");
        return @intFromEnum(Result.@"error");
    };
    const layer = stack.layers.items[idx];
    const n: u32 = @intCast(layer.name.len);

    if (out_len != 0) {
        const len_ptr: *u32 = @ptrFromInt(out_len);
        len_ptr.* = n;
    }
    if (n > buf_size) {
        setError("pt_layer_get_name: output buffer too small");
        return @intFromEnum(Result.@"error");
    }
    if (n > 0) {
        if (out_buf == 0) {
            setError("pt_layer_get_name: null output buffer");
            return @intFromEnum(Result.@"error");
        }
        const dst: [*]u8 = @ptrFromInt(out_buf);
        @memcpy(dst[0..n], layer.name);
    }
    clearError();
    return @intFromEnum(Result.ok);
}

/// Set the opacity of layer `id` from an f32 bit-pattern (NaN → 1.0, clamped to
/// [0, 1]). Returns Result.ok, or Result.error on invalid stack / unknown id.
export fn pt_layer_set_opacity(stack_ptr: u64, id: u32, opacity_bits: u32) u32 {
    const stack = liveStack(stack_ptr) orelse return @intFromEnum(Result.@"error");
    const idx = stack.indexOf(id) orelse {
        setError("pt_layer_set_opacity: unknown id");
        return @intFromEnum(Result.@"error");
    };
    stack.layers.items[idx].opacity = sanitizeOpacity(opacity_bits);
    clearError();
    return @intFromEnum(Result.ok);
}

/// Get the opacity of layer `id` as an f32 bit-pattern. Returns the bits of
/// 1.0 for an invalid stack or unknown id.
export fn pt_layer_get_opacity(stack_ptr: u64, id: u32) u32 {
    const one_bits: u32 = @bitCast(@as(f32, 1.0));
    const stack = liveStack(stack_ptr) orelse return one_bits;
    const idx = stack.indexOf(id) orelse return one_bits;
    return @bitCast(stack.layers.items[idx].opacity);
}

/// Set the visibility of layer `id` (non-zero → visible). Returns Result.ok,
/// or Result.error on invalid stack / unknown id.
export fn pt_layer_set_visible(stack_ptr: u64, id: u32, visible: u32) u32 {
    const stack = liveStack(stack_ptr) orelse return @intFromEnum(Result.@"error");
    const idx = stack.indexOf(id) orelse {
        setError("pt_layer_set_visible: unknown id");
        return @intFromEnum(Result.@"error");
    };
    stack.layers.items[idx].visible = (visible != 0);
    clearError();
    return @intFromEnum(Result.ok);
}

/// Get the visibility of layer `id` (1 → visible, 0 → hidden / unknown id).
export fn pt_layer_get_visible(stack_ptr: u64, id: u32) u32 {
    const stack = liveStack(stack_ptr) orelse return 0;
    const idx = stack.indexOf(id) orelse return 0;
    return if (stack.layers.items[idx].visible) 1 else 0;
}

//==============================================================================
// Library Status
//==============================================================================

/// Get the last error message. Returns null if no error is recorded.
/// The returned string has static lifetime — do not free.
export fn pt_last_error() ?[*:0]const u8 {
    const err = last_error orelse return null;
    return err.ptr;
}

/// Get the library version. Static storage; do not free.
export fn pt_version() [*:0]const u8 {
    return VERSION.ptr;
}

/// Returns 1 if the given pointer looks like a live tile, 0 otherwise.
/// Checks both non-null and a valid magic word.
export fn pt_is_initialized(tile_ptr: u64) u32 {
    if (tile_ptr == 0) return 0;
    const tile: *const PtTile = @ptrFromInt(tile_ptr);
    return if (tile.isLive()) 1 else 0;
}

//==============================================================================
// Tests
//==============================================================================

test "tile alloc and free" {
    const tile_ptr = pt_tile_alloc(3, 7);
    try std.testing.expect(tile_ptr != 0);
    try std.testing.expectEqual(@as(u32, 1), pt_is_initialized(tile_ptr));

    const tile: *const PtTile = @ptrFromInt(tile_ptr);
    try std.testing.expectEqual(@as(u32, 3), tile.x);
    try std.testing.expectEqual(@as(u32, 7), tile.y);
    try std.testing.expectEqual(TILE_SIZE, tile.width);
    try std.testing.expectEqual(TILE_SIZE, tile.height);

    pt_tile_free(tile_ptr);
}

test "tile fill and read pixel" {
    const tile_ptr = pt_tile_alloc(0, 0);
    try std.testing.expect(tile_ptr != 0);
    defer pt_tile_free(tile_ptr);

    // Fill with opaque red: r=1.0, g=0.0, b=0.0, a=1.0 in f16.
    const one_bits: u16 = @bitCast(@as(f16, 1.0));
    const zero_bits: u16 = @bitCast(@as(f16, 0.0));
    const fill_rc = pt_tile_fill(tile_ptr, one_bits, zero_bits, zero_bits, one_bits);
    try std.testing.expectEqual(@intFromEnum(Result.ok), fill_rc);

    var r_out: u16 = 0;
    var g_out: u16 = 0;
    var b_out: u16 = 0;
    var a_out: u16 = 0;
    const read_rc = pt_tile_read_pixel(
        tile_ptr,
        17,
        42,
        @intFromPtr(&r_out),
        @intFromPtr(&g_out),
        @intFromPtr(&b_out),
        @intFromPtr(&a_out),
    );
    try std.testing.expectEqual(@intFromEnum(Result.ok), read_rc);

    try std.testing.expectEqual(one_bits, r_out);
    try std.testing.expectEqual(zero_bits, g_out);
    try std.testing.expectEqual(zero_bits, b_out);
    try std.testing.expectEqual(one_bits, a_out);

    // Round-trip: bit pattern interpreted as f16 yields the original value.
    try std.testing.expectEqual(@as(f16, 1.0), @as(f16, @bitCast(r_out)));
    try std.testing.expectEqual(@as(f16, 0.0), @as(f16, @bitCast(g_out)));
}

test "tile read bounds check" {
    const tile_ptr = pt_tile_alloc(0, 0);
    try std.testing.expect(tile_ptr != 0);
    defer pt_tile_free(tile_ptr);

    var r: u16 = 0;
    var g: u16 = 0;
    var b: u16 = 0;
    var a: u16 = 0;

    // px == TILE_SIZE is out of bounds (valid range is 0..63).
    const rc1 = pt_tile_read_pixel(
        tile_ptr,
        TILE_SIZE,
        0,
        @intFromPtr(&r),
        @intFromPtr(&g),
        @intFromPtr(&b),
        @intFromPtr(&a),
    );
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), rc1);

    const rc2 = pt_tile_read_pixel(
        tile_ptr,
        0,
        9999,
        @intFromPtr(&r),
        @intFromPtr(&g),
        @intFromPtr(&b),
        @intFromPtr(&a),
    );
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), rc2);
}

test "null tile safety" {
    // Free of zero is a no-op (no crash).
    pt_tile_free(0);

    // is_initialized of zero returns 0.
    try std.testing.expectEqual(@as(u32, 0), pt_is_initialized(0));

    // Fill on null returns invalid_param.
    const fill_rc = pt_tile_fill(0, 0, 0, 0, 0);
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), fill_rc);

    // Read on null returns invalid_param.
    var r: u16 = 0;
    var g: u16 = 0;
    var b: u16 = 0;
    var a: u16 = 0;
    const read_rc = pt_tile_read_pixel(
        0,
        0,
        0,
        @intFromPtr(&r),
        @intFromPtr(&g),
        @intFromPtr(&b),
        @intFromPtr(&a),
    );
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), read_rc);

    // Read with null out-pointers also returns invalid_param.
    const tile_ptr = pt_tile_alloc(0, 0);
    try std.testing.expect(tile_ptr != 0);
    defer pt_tile_free(tile_ptr);
    const read_rc2 = pt_tile_read_pixel(tile_ptr, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), read_rc2);
}

test "version string is non-empty" {
    const ver = pt_version();
    const ver_str = std.mem.span(ver);
    try std.testing.expect(ver_str.len > 0);
    try std.testing.expectEqualStrings("0.1.0", ver_str);
}

test "u16 slot helpers round-trip" {
    const slot = pt_alloc_u16_slot();
    try std.testing.expect(slot != 0);
    defer pt_free_u16_slot(slot);

    const slot_ptr: *u16 = @ptrFromInt(slot);
    slot_ptr.* = 0xBEEF;
    try std.testing.expectEqual(@as(u16, 0xBEEF), pt_read_u16_slot(slot));
}

//------------------------------------------------------------------------------
// PtLayerStack tests
//------------------------------------------------------------------------------

/// Read the name of layer `id` into a fixed buffer and return it as a slice of
/// `buf`, asserting the call succeeded.
fn expectName(stack: u64, id: u32, buf: []u8) ![]const u8 {
    var out_len: u32 = 0;
    const rc = pt_layer_get_name(stack, id, @intFromPtr(buf.ptr), @intCast(buf.len), @intFromPtr(&out_len));
    try std.testing.expectEqual(@intFromEnum(Result.ok), rc);
    try std.testing.expect(out_len <= buf.len);
    return buf[0..out_len];
}

test "layer stack: new, push, count, get_id_at ordering" {
    const stack = pt_layer_stack_new();
    try std.testing.expect(stack != 0);
    defer pt_layer_stack_free(stack);

    try std.testing.expectEqual(@as(u32, 0), pt_layer_count(stack));

    const bg = "Background";
    const fg = "Stroke";
    const bg_id = pt_layer_push(stack, @intFromPtr(bg.ptr), bg.len);
    const fg_id = pt_layer_push(stack, @intFromPtr(fg.ptr), fg.len);
    try std.testing.expect(bg_id != PT_LAYER_ID_NONE);
    try std.testing.expect(fg_id != PT_LAYER_ID_NONE);
    try std.testing.expect(bg_id != fg_id);

    try std.testing.expectEqual(@as(u32, 2), pt_layer_count(stack));
    // index 0 = bottom (first pushed), last = top.
    try std.testing.expectEqual(bg_id, pt_layer_get_id_at(stack, 0));
    try std.testing.expectEqual(fg_id, pt_layer_get_id_at(stack, 1));
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_get_id_at(stack, 2));
}

test "layer stack: get_name round-trips, empty name, buffer too small" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const name = "Layer Ω"; // multi-byte UTF-8 to prove byte-length handling
    const id = pt_layer_push(stack, @intFromPtr(name.ptr), name.len);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(name, try expectName(stack, id, &buf));

    // Empty name: push with null/zero, name length is 0.
    const empty_id = pt_layer_push(stack, 0, 0);
    try std.testing.expect(empty_id != PT_LAYER_ID_NONE);
    try std.testing.expectEqualStrings("", try expectName(stack, empty_id, &buf));

    // Buffer too small still reports the required length and returns error.
    var tiny: [3]u8 = undefined;
    var need: u32 = 0;
    const rc = pt_layer_get_name(stack, id, @intFromPtr(&tiny), tiny.len, @intFromPtr(&need));
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), rc);
    try std.testing.expectEqual(@as(u32, name.len), need);
}

test "layer stack: reorder preserves ids and moves position" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const a = "A";
    const b = "B";
    const c = "C";
    const a_id = pt_layer_push(stack, @intFromPtr(a.ptr), a.len);
    const b_id = pt_layer_push(stack, @intFromPtr(b.ptr), b.len);
    const c_id = pt_layer_push(stack, @intFromPtr(c.ptr), c.len);
    // [A, B, C]; move C (top) to bottom.
    try std.testing.expectEqual(@intFromEnum(Result.ok), pt_layer_reorder_to(stack, c_id, 0));
    try std.testing.expectEqual(c_id, pt_layer_get_id_at(stack, 0));
    try std.testing.expectEqual(a_id, pt_layer_get_id_at(stack, 1));
    try std.testing.expectEqual(b_id, pt_layer_get_id_at(stack, 2));

    // Out-of-range position is rejected; ordering unchanged.
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_reorder_to(stack, a_id, 3));
    try std.testing.expectEqual(c_id, pt_layer_get_id_at(stack, 0));
}

test "layer stack: delete removes by id and shifts" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);

    const a = "A";
    const b = "B";
    const a_id = pt_layer_push(stack, @intFromPtr(a.ptr), a.len);
    const b_id = pt_layer_push(stack, @intFromPtr(b.ptr), b.len);
    try std.testing.expectEqual(@intFromEnum(Result.ok), pt_layer_delete(stack, a_id));
    try std.testing.expectEqual(@as(u32, 1), pt_layer_count(stack));
    try std.testing.expectEqual(b_id, pt_layer_get_id_at(stack, 0));
    // Deleting an unknown id errors.
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_delete(stack, a_id));
}

test "layer stack: opacity clamps and NaN normalises" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);
    const n = "L";
    const id = pt_layer_push(stack, @intFromPtr(n.ptr), n.len);

    // Default opacity is 1.0.
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(pt_layer_get_opacity(stack, id))));

    // 1.5 → 1.0 (overshoot), -0.25 → 0.0 (undershoot), NaN → 1.0, 0.5 stays.
    _ = pt_layer_set_opacity(stack, id, @bitCast(@as(f32, 1.5)));
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(pt_layer_get_opacity(stack, id))));
    _ = pt_layer_set_opacity(stack, id, @bitCast(@as(f32, -0.25)));
    try std.testing.expectEqual(@as(f32, 0.0), @as(f32, @bitCast(pt_layer_get_opacity(stack, id))));
    _ = pt_layer_set_opacity(stack, id, @bitCast(@as(f32, std.math.nan(f32))));
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(pt_layer_get_opacity(stack, id))));
    _ = pt_layer_set_opacity(stack, id, @bitCast(@as(f32, 0.5)));
    try std.testing.expectEqual(@as(f32, 0.5), @as(f32, @bitCast(pt_layer_get_opacity(stack, id))));

    // Unknown id → bits of 1.0 on get, error on set.
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(pt_layer_get_opacity(stack, 9999))));
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_set_opacity(stack, 9999, 0));
}

test "layer stack: visibility toggles, default visible" {
    const stack = pt_layer_stack_new();
    defer pt_layer_stack_free(stack);
    const n = "L";
    const id = pt_layer_push(stack, @intFromPtr(n.ptr), n.len);

    try std.testing.expectEqual(@as(u32, 1), pt_layer_get_visible(stack, id));
    try std.testing.expectEqual(@intFromEnum(Result.ok), pt_layer_set_visible(stack, id, 0));
    try std.testing.expectEqual(@as(u32, 0), pt_layer_get_visible(stack, id));
    try std.testing.expectEqual(@intFromEnum(Result.ok), pt_layer_set_visible(stack, id, 7));
    try std.testing.expectEqual(@as(u32, 1), pt_layer_get_visible(stack, id));

    // Unknown id → 0 on get, error on set.
    try std.testing.expectEqual(@as(u32, 0), pt_layer_get_visible(stack, 9999));
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_set_visible(stack, 9999, 1));
}

test "layer stack: null / stale handle safety" {
    // Null handle: frees are no-ops, queries return safe defaults.
    pt_layer_stack_free(0);
    try std.testing.expectEqual(@as(u32, 0), pt_layer_count(0));
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_push(0, 0, 0));
    try std.testing.expectEqual(PT_LAYER_ID_NONE, pt_layer_get_id_at(0, 0));
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_delete(0, 1));
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_reorder_to(0, 1, 0));
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_set_opacity(0, 1, 0));
    try std.testing.expectEqual(@intFromEnum(Result.@"error"), pt_layer_set_visible(0, 1, 1));
    // Getters on a null handle return safe defaults: opacity 1.0, hidden.
    try std.testing.expectEqual(@as(f32, 1.0), @as(f32, @bitCast(pt_layer_get_opacity(0, 1))));
    try std.testing.expectEqual(@as(u32, 0), pt_layer_get_visible(0, 1));
}
