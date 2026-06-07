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

/// Bulk-read the whole tile pixel buffer (TILE_PIXEL_SCALARS f16 bit
/// patterns) into a caller-provided u16 array. One FFI crossing instead of
/// one per pixel: the per-pixel ABI is far too slow for hot render/brush
/// loops, so callers copy the tile out, work in their own language, and
/// copy back with pt_tile_write_buffer.
export fn pt_tile_read_buffer(tile_ptr: u64, out_ptr: u64) u32 {
    if (tile_ptr == 0 or out_ptr == 0) {
        setError("pt_tile_read_buffer: null pointer");
        return @intFromEnum(Result.invalid_param);
    }
    const tile: *PtTile = @ptrFromInt(tile_ptr);
    if (!tile.isLive()) {
        setError("pt_tile_read_buffer: invalid tile (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }
    const out: [*]u16 = @ptrFromInt(out_ptr);
    const src: [*]const u16 = @ptrCast(&tile.pixels);
    @memcpy(out[0..TILE_PIXEL_SCALARS], src[0..TILE_PIXEL_SCALARS]);
    clearError();
    return @intFromEnum(Result.ok);
}

/// Bulk-write the whole tile pixel buffer from a caller-provided u16 array.
/// The counterpart to pt_tile_read_buffer.
export fn pt_tile_write_buffer(tile_ptr: u64, in_ptr: u64) u32 {
    if (tile_ptr == 0 or in_ptr == 0) {
        setError("pt_tile_write_buffer: null pointer");
        return @intFromEnum(Result.invalid_param);
    }
    const tile: *PtTile = @ptrFromInt(tile_ptr);
    if (!tile.isLive()) {
        setError("pt_tile_write_buffer: invalid tile (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }
    const in: [*]const u16 = @ptrFromInt(in_ptr);
    const dst: [*]u16 = @ptrCast(&tile.pixels);
    @memcpy(dst[0..TILE_PIXEL_SCALARS], in[0..TILE_PIXEL_SCALARS]);
    clearError();
    return @intFromEnum(Result.ok);
}

/// Write a single pixel (px, py) on the tile with RGBA16F bit patterns.
/// Channel arguments carry the bit patterns of f16 values.
/// Returns RESULT_OK on success, RESULT_INVALID_PARAM on null / OOB / bad magic.
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
// PtLayerStack — cross-language layer metadata
//==============================================================================
//
// Layer metadata (id, name, opacity, visibility) lives on the libpt side
// so non-Rust consumers (AffineScript, Idris2 callers, future Gossamer
// shell, etc.) can manage layer order through a single C ABI. Tile
// storage stays on the caller side — this stack is metadata-only.
//
// Storage is a fixed-size in-struct array (no allocator gymnastics, no
// growable buffer). Each stack is 256 slots × 272 B ≈ 68 KB, which
// comfortably covers Photoshop-document-sized layer stacks (rarely
// >100 layers) while staying small enough to allocate without thread-
// stack pressure when test runners briefly carry a PtLayerStack through
// a frame boundary.
//
// Identifiers are u32, monotonically issued from `next_id` starting at
// 1 (0 is reserved as the "null layer id" return sentinel). Once an id
// is deleted it is never reused — `pt_layer_get_name(..., dead_id)`
// returns `not_found` rather than silently reading a recycled slot.

/// Maximum bytes a layer name occupies on the stack (including no
/// terminator — `name_len` carries the real length).
pub const PT_LAYER_NAME_MAX: usize = 256;

/// Maximum number of layers a single PtLayerStack can hold.
pub const PT_LAYER_MAX_PER_STACK: usize = 256;

/// Magic value for a live PtLayerStack.
const PT_LAYER_STACK_MAGIC: u32 = 0x504C5354; // "PLST"

/// Magic value written into a stack header when it has been freed.
const PT_LAYER_STACK_DEAD_MAGIC: u32 = 0x44454144; // "DEAD"

/// Sentinel "no such layer" value for u32 id returns.
pub const PT_LAYER_ID_NONE: u32 = 0;

pub const PtLayer = extern struct {
    id: u32,
    name_len: u32,
    opacity_bits: u32, // raw bit pattern of an f32 (IEEE 754 binary32)
    visible: u32,      // 0 or 1; u32 keeps the struct extern-stable
    name_buf: [PT_LAYER_NAME_MAX]u8,
};

pub const PtLayerStack = extern struct {
    magic: u32,
    layer_count: u32,
    next_id: u32,
    _pad: u32,
    layers: [PT_LAYER_MAX_PER_STACK]PtLayer,

    fn isLive(self: *const PtLayerStack) bool {
        return self.magic == PT_LAYER_STACK_MAGIC;
    }
};

fn clamp_opacity(bits: u32) u32 {
    const v: f32 = @bitCast(bits);
    if (std.math.isNan(v)) return @bitCast(@as(f32, 1.0));
    if (v < 0.0) return @bitCast(@as(f32, 0.0));
    if (v > 1.0) return @bitCast(@as(f32, 1.0));
    return bits;
}

fn find_layer_index(stack: *const PtLayerStack, id: u32) ?usize {
    var i: usize = 0;
    const count = stack.layer_count;
    while (i < count) : (i += 1) {
        if (stack.layers[i].id == id) return i;
    }
    return null;
}

/// Allocate an empty layer stack. Returns 0 on out-of-memory.
export fn pt_layer_stack_new() callconv(.c) u64 {
    const allocator = std.heap.c_allocator;
    const stack = allocator.create(PtLayerStack) catch {
        setError("pt_layer_stack_new: out of memory");
        return 0;
    };

    stack.magic = PT_LAYER_STACK_MAGIC;
    stack.layer_count = 0;
    stack.next_id = 1;
    stack._pad = 0;
    // `layers` left uninitialised — `pt_layer_push` writes each slot
    // before it is observable through layer_count.

    clearError();
    return @intFromPtr(stack);
}

/// Free a layer stack. Safe to call with 0. Refuses double-free via the
/// magic word the same way `pt_tile_free` does.
export fn pt_layer_stack_free(stack_ptr: u64) callconv(.c) void {
    if (stack_ptr == 0) return;

    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (stack.magic != PT_LAYER_STACK_MAGIC) {
        setError("pt_layer_stack_free: invalid or already-freed stack");
        return;
    }

    stack.magic = PT_LAYER_STACK_DEAD_MAGIC;
    const allocator = std.heap.c_allocator;
    allocator.destroy(stack);
    clearError();
}

/// Push a new layer onto the top of the stack with `name` (UTF-8 bytes,
/// up to `PT_LAYER_NAME_MAX` — longer names are truncated). Default
/// opacity is 1.0; default visibility is true.
///
/// Returns the freshly-issued layer id, or `PT_LAYER_ID_NONE` on error.
/// Errors: null stack, bad magic, stack full, null name pointer.
export fn pt_layer_push(
    stack_ptr: u64,
    name_ptr: u64,
    name_len: u32,
) callconv(.c) u32 {
    if (stack_ptr == 0) {
        setError("pt_layer_push: null stack");
        return PT_LAYER_ID_NONE;
    }
    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) {
        setError("pt_layer_push: invalid stack (bad magic)");
        return PT_LAYER_ID_NONE;
    }
    if (stack.layer_count >= PT_LAYER_MAX_PER_STACK) {
        setError("pt_layer_push: stack full");
        return PT_LAYER_ID_NONE;
    }

    const slot_idx = stack.layer_count;
    var slot = &stack.layers[slot_idx];
    slot.id = stack.next_id;
    slot.opacity_bits = @bitCast(@as(f32, 1.0));
    slot.visible = 1;

    // Truncate name to PT_LAYER_NAME_MAX; allow zero-length names and
    // null pointer (treated as empty).
    const effective_len: usize = if (name_ptr == 0)
        0
    else
        @min(@as(usize, name_len), PT_LAYER_NAME_MAX);
    slot.name_len = @intCast(effective_len);

    if (effective_len > 0) {
        const src: [*]const u8 = @ptrFromInt(name_ptr);
        @memcpy(slot.name_buf[0..effective_len], src[0..effective_len]);
    }

    stack.layer_count += 1;
    stack.next_id += 1;
    clearError();
    return slot.id;
}

/// Delete the layer with `id`. Returns RESULT_OK on success,
/// RESULT_INVALID_PARAM on null/bad-magic, RESULT_ERROR on unknown id.
export fn pt_layer_delete(stack_ptr: u64, id: u32) callconv(.c) u32 {
    if (stack_ptr == 0) {
        setError("pt_layer_delete: null stack");
        return @intFromEnum(Result.invalid_param);
    }
    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) {
        setError("pt_layer_delete: invalid stack (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }

    const found = find_layer_index(stack, id) orelse {
        setError("pt_layer_delete: unknown layer id");
        return @intFromEnum(Result.@"error");
    };

    // Shift everything above `found` down by one. ids are NOT recycled
    // — `next_id` keeps growing — so positions in `layers[0..count]`
    // are dense and ids stay stable across deletes.
    var i: usize = found;
    const count = stack.layer_count;
    while (i + 1 < count) : (i += 1) {
        stack.layers[i] = stack.layers[i + 1];
    }
    stack.layer_count -= 1;
    clearError();
    return @intFromEnum(Result.ok);
}

/// Move the layer with `id` to position `new_position` (0 = bottom of
/// stack). Returns RESULT_OK on success, RESULT_INVALID_PARAM on
/// null/bad-magic/oob position, RESULT_ERROR on unknown id.
export fn pt_layer_reorder_to(
    stack_ptr: u64,
    id: u32,
    new_position: u32,
) callconv(.c) u32 {
    if (stack_ptr == 0) {
        setError("pt_layer_reorder_to: null stack");
        return @intFromEnum(Result.invalid_param);
    }
    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) {
        setError("pt_layer_reorder_to: invalid stack (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }
    if (new_position >= stack.layer_count) {
        setError("pt_layer_reorder_to: position out of bounds");
        return @intFromEnum(Result.invalid_param);
    }

    const from = find_layer_index(stack, id) orelse {
        setError("pt_layer_reorder_to: unknown layer id");
        return @intFromEnum(Result.@"error");
    };

    const target: usize = new_position;
    if (from == target) {
        clearError();
        return @intFromEnum(Result.ok);
    }

    const moving = stack.layers[from];
    if (from < target) {
        // Shift left to fill, then insert.
        var i: usize = from;
        while (i < target) : (i += 1) {
            stack.layers[i] = stack.layers[i + 1];
        }
    } else {
        // Shift right to make room, then insert.
        var i: usize = from;
        while (i > target) : (i -= 1) {
            stack.layers[i] = stack.layers[i - 1];
        }
    }
    stack.layers[target] = moving;
    clearError();
    return @intFromEnum(Result.ok);
}

/// Return the number of layers currently in the stack, or 0 on error.
export fn pt_layer_count(stack_ptr: u64) callconv(.c) u32 {
    if (stack_ptr == 0) return 0;
    const stack: *const PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) return 0;
    return stack.layer_count;
}

/// Return the layer id at `position` (0 = bottom). Returns
/// `PT_LAYER_ID_NONE` if the position is out of range, null stack, or
/// bad-magic stack.
export fn pt_layer_get_id_at(stack_ptr: u64, position: u32) callconv(.c) u32 {
    if (stack_ptr == 0) return PT_LAYER_ID_NONE;
    const stack: *const PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) return PT_LAYER_ID_NONE;
    if (position >= stack.layer_count) return PT_LAYER_ID_NONE;
    return stack.layers[position].id;
}

/// Copy the layer's name into the caller-provided buffer (UTF-8 bytes,
/// no null terminator written — use `out_len` to know the byte count).
/// `buf_size` is the buffer capacity; bytes beyond it are dropped.
///
/// Returns RESULT_OK on a clean copy, RESULT_INVALID_PARAM on
/// null/bad-magic/null-out-pointers, RESULT_ERROR on unknown id.
export fn pt_layer_get_name(
    stack_ptr: u64,
    id: u32,
    out_buf: u64,
    buf_size: u32,
    out_len: u64,
) callconv(.c) u32 {
    if (stack_ptr == 0) {
        setError("pt_layer_get_name: null stack");
        return @intFromEnum(Result.invalid_param);
    }
    if (out_buf == 0 or out_len == 0) {
        setError("pt_layer_get_name: null output pointer");
        return @intFromEnum(Result.invalid_param);
    }
    const stack: *const PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) {
        setError("pt_layer_get_name: invalid stack (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }

    const idx = find_layer_index(stack, id) orelse {
        setError("pt_layer_get_name: unknown layer id");
        return @intFromEnum(Result.@"error");
    };

    const layer = &stack.layers[idx];
    const want: usize = layer.name_len;
    const len_ptr: *u32 = @ptrFromInt(out_len);
    len_ptr.* = @intCast(want);

    if (buf_size > 0 and want > 0) {
        const dst: [*]u8 = @ptrFromInt(out_buf);
        const copy_n = @min(want, @as(usize, buf_size));
        @memcpy(dst[0..copy_n], layer.name_buf[0..copy_n]);
    }

    clearError();
    return @intFromEnum(Result.ok);
}

/// Set the opacity of `id` to `opacity_bits` (raw IEEE 754 binary32 bit
/// pattern). NaN is rewritten to 1.0; values outside [0, 1] are
/// clamped. Returns RESULT_OK on success.
export fn pt_layer_set_opacity(
    stack_ptr: u64,
    id: u32,
    opacity_bits: u32,
) callconv(.c) u32 {
    if (stack_ptr == 0) {
        setError("pt_layer_set_opacity: null stack");
        return @intFromEnum(Result.invalid_param);
    }
    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) {
        setError("pt_layer_set_opacity: invalid stack (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }
    const idx = find_layer_index(stack, id) orelse {
        setError("pt_layer_set_opacity: unknown layer id");
        return @intFromEnum(Result.@"error");
    };
    stack.layers[idx].opacity_bits = clamp_opacity(opacity_bits);
    clearError();
    return @intFromEnum(Result.ok);
}

/// Get the opacity bit pattern of `id`, or `0xFFFFFFFF` on error.
export fn pt_layer_get_opacity(stack_ptr: u64, id: u32) callconv(.c) u32 {
    if (stack_ptr == 0) return 0xFFFFFFFF;
    const stack: *const PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) return 0xFFFFFFFF;
    const idx = find_layer_index(stack, id) orelse return 0xFFFFFFFF;
    return stack.layers[idx].opacity_bits;
}

/// Set the visibility of `id` (0 = hidden, anything else = visible).
export fn pt_layer_set_visible(
    stack_ptr: u64,
    id: u32,
    visible: u32,
) callconv(.c) u32 {
    if (stack_ptr == 0) {
        setError("pt_layer_set_visible: null stack");
        return @intFromEnum(Result.invalid_param);
    }
    const stack: *PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) {
        setError("pt_layer_set_visible: invalid stack (bad magic)");
        return @intFromEnum(Result.invalid_param);
    }
    const idx = find_layer_index(stack, id) orelse {
        setError("pt_layer_set_visible: unknown layer id");
        return @intFromEnum(Result.@"error");
    };
    stack.layers[idx].visible = if (visible == 0) 0 else 1;
    clearError();
    return @intFromEnum(Result.ok);
}

/// Get the visibility flag of `id` (0 = hidden, 1 = visible, 0xFFFFFFFF
/// on error).
export fn pt_layer_get_visible(stack_ptr: u64, id: u32) callconv(.c) u32 {
    if (stack_ptr == 0) return 0xFFFFFFFF;
    const stack: *const PtLayerStack = @ptrFromInt(stack_ptr);
    if (!stack.isLive()) return 0xFFFFFFFF;
    const idx = find_layer_index(stack, id) orelse return 0xFFFFFFFF;
    return stack.layers[idx].visible;
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

test "tile write pixel round-trips" {
    const tile_ptr = pt_tile_alloc(0, 0);
    try std.testing.expect(tile_ptr != 0);
    defer pt_tile_free(tile_ptr);

    // Known RGBA pattern: r=0.25, g=0.5, b=0.75, a=1.0.
    const r_in: u16 = @bitCast(@as(f16, 0.25));
    const g_in: u16 = @bitCast(@as(f16, 0.5));
    const b_in: u16 = @bitCast(@as(f16, 0.75));
    const a_in: u16 = @bitCast(@as(f16, 1.0));

    const write_rc = pt_tile_write_pixel(tile_ptr, 3, 7, r_in, g_in, b_in, a_in);
    try std.testing.expectEqual(@intFromEnum(Result.ok), write_rc);

    // Every OTHER pixel must still be zero (alloc zero-fills, and write
    // only touched (3, 7)).
    const other_probes = [_][2]u32{
        .{ 0, 0 },
        .{ 3, 6 },
        .{ 4, 7 },
        .{ 2, 7 },
        .{ 3, 8 },
        .{ TILE_SIZE - 1, TILE_SIZE - 1 },
    };
    for (other_probes) |p| {
        var r: u16 = 0xFFFF;
        var g: u16 = 0xFFFF;
        var b: u16 = 0xFFFF;
        var a: u16 = 0xFFFF;
        const rc = pt_tile_read_pixel(
            tile_ptr,
            p[0],
            p[1],
            @intFromPtr(&r),
            @intFromPtr(&g),
            @intFromPtr(&b),
            @intFromPtr(&a),
        );
        try std.testing.expectEqual(@intFromEnum(Result.ok), rc);
        try std.testing.expectEqual(@as(u16, 0), r);
        try std.testing.expectEqual(@as(u16, 0), g);
        try std.testing.expectEqual(@as(u16, 0), b);
        try std.testing.expectEqual(@as(u16, 0), a);
    }

    // Read (3, 7) back and verify the round-trip.
    var r_out: u16 = 0;
    var g_out: u16 = 0;
    var b_out: u16 = 0;
    var a_out: u16 = 0;
    const read_rc = pt_tile_read_pixel(
        tile_ptr,
        3,
        7,
        @intFromPtr(&r_out),
        @intFromPtr(&g_out),
        @intFromPtr(&b_out),
        @intFromPtr(&a_out),
    );
    try std.testing.expectEqual(@intFromEnum(Result.ok), read_rc);
    try std.testing.expectEqual(r_in, r_out);
    try std.testing.expectEqual(g_in, g_out);
    try std.testing.expectEqual(b_in, b_out);
    try std.testing.expectEqual(a_in, a_out);

    // Value-level f16 round-trip too.
    try std.testing.expectEqual(@as(f16, 0.25), @as(f16, @bitCast(r_out)));
    try std.testing.expectEqual(@as(f16, 0.5), @as(f16, @bitCast(g_out)));
    try std.testing.expectEqual(@as(f16, 0.75), @as(f16, @bitCast(b_out)));
    try std.testing.expectEqual(@as(f16, 1.0), @as(f16, @bitCast(a_out)));
}

test "tile write pixel bounds + null checks" {
    // Null tile is rejected.
    const rc_null = pt_tile_write_pixel(0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), rc_null);

    const tile_ptr = pt_tile_alloc(0, 0);
    try std.testing.expect(tile_ptr != 0);
    defer pt_tile_free(tile_ptr);

    // px == TILE_SIZE is out of bounds.
    const rc_px = pt_tile_write_pixel(tile_ptr, TILE_SIZE, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), rc_px);

    // py far out of range is out of bounds.
    const rc_py = pt_tile_write_pixel(tile_ptr, 0, 9999, 0, 0, 0, 0);
    try std.testing.expectEqual(@intFromEnum(Result.invalid_param), rc_py);
}

test "u16 slot helpers round-trip" {
    const slot = pt_alloc_u16_slot();
    try std.testing.expect(slot != 0);
    defer pt_free_u16_slot(slot);

    const slot_ptr: *u16 = @ptrFromInt(slot);
    slot_ptr.* = 0xBEEF;
    try std.testing.expectEqual(@as(u16, 0xBEEF), pt_read_u16_slot(slot));
}
