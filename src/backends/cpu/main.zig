// SPDX-License-Identifier: AGPL-3.0-or-later
//
// paint.type — CpuReferenceBackend
//
// The mandatory, always-loaded reference backend. The oracle for every
// accelerated backend. Correct first, fast nowhere. No SIMD assumptions
// here; speed lives under src/backends/vector/.
//
// Governed by ADR-0002. This file registers a single BackendImpl with the
// dispatcher at startup. Each MVP-N operation's reference implementation
// lives in its own section below. Operations not yet implemented return
// ResultCode.not_implemented, which the dispatcher honours as a "please
// fall back" signal — but here, on the reference backend, that's a bug:
// the reference must implement everything. The not_implemented stubs are
// scaffolding that will be filled in milestone by milestone.

const std = @import("std");
const dispatcher = @import("dispatcher");

//==============================================================================
// 1. Internal state — canvases, layers, masks, history
//==============================================================================

const TILE_SIZE: u32 = 64;
const TILE_CHANNELS: u32 = 4;
const TILE_SCALARS: usize = @as(usize, TILE_SIZE) * TILE_SIZE * TILE_CHANNELS;

// Upper bound on canvas dimensions. width/height arrive as raw u32 across the
// FFI from callers we don't trust and feed allocation + PNG-encoder size
// arithmetic (width*height*4, (row_bytes+1)*height). Without a cap those
// products can overflow `usize` on 32-bit targets — yielding a buffer too small
// for the full-size write that follows (heap overflow) — and on any target
// invite an allocation-DoS. 16384 mirrors the Rust codec's MAX_DIM.
const MAX_CANVAS_DIM: u32 = 16384;

// Hard cap on the number of stamps a single brush-stroke segment may emit, so a
// caller passing far-apart points can't drive an unbounded stamp loop.
const MAX_STROKE_STAMPS: u32 = 1 << 20;

// `@intFromFloat` is illegal behaviour for NaN, ±Inf, or out-of-range values: a
// safety-check panic in Debug and undefined behaviour in ReleaseFast. Stroke
// coordinates and brush geometry are caller-supplied f64s, so every conversion
// goes through these guards rather than a bare `@intFromFloat`.

/// Floor `v` to an integer in [0, limit), or null if `v` is non-finite,
/// negative, or beyond the limit (caller should skip the value).
fn finiteFloorU32(v: f64, limit: u32) ?u32 {
    if (!std.math.isFinite(v) or v < 0) return null;
    const f = @floor(v);
    if (f >= @as(f64, @floatFromInt(limit))) return null;
    return @intFromFloat(f);
}

/// Convert `v` to an i64 clamped to [lo, hi]; NaN maps to `lo`. Keeps an
/// attacker-large bbox coordinate from overflowing the i64 cast.
fn finiteToI64Clamped(v: f64, lo: i64, hi: i64) i64 {
    if (std.math.isNan(v)) return lo;
    if (v <= @as(f64, @floatFromInt(lo))) return lo;
    if (v >= @as(f64, @floatFromInt(hi))) return hi;
    return @intFromFloat(v);
}

const Tile = struct {
    /// RGBA16F pixel data stored as u16 bit-patterns of f16 values. Same
    /// convention as src/interface/ffi/src/main.zig and src/ephapax/src/lib.rs.
    pixels: [TILE_SCALARS]u16 = [_]u16{0} ** TILE_SCALARS,
};

const TileKey = struct { tx: u32, ty: u32 };

const BlendMode = enum(u32) {
    normal = 0,
    multiply = 1,
    screen = 2,
};

const Layer = struct {
    name: []u8,
    visible: bool = true,
    opacity: f64 = 1.0,
    blend: BlendMode = .normal,
    tiles: std.AutoHashMapUnmanaged(TileKey, *Tile) = .empty,

    fn deinit(self: *Layer, alloc: std.mem.Allocator) void {
        var it = self.tiles.valueIterator();
        while (it.next()) |t| alloc.destroy(t.*);
        self.tiles.deinit(alloc);
        alloc.free(self.name);
    }
};

const Canvas = struct {
    // std.Thread.Mutex sleeps under contention rather than burning a core, and
    // is the standard, non-reentrant lock — do not re-enter on the same Canvas
    // (see cpu_canvas_render_rgba8, which splits into an _internal helper to
    // avoid re-acquiring this lock).
    lock: std.Thread.Mutex = .{},
    width: u32,
    height: u32,
    format: u32, // 0=RGBA16F, 1=RGBA8, ...
    background: [4]f32,
    layers: std.ArrayListUnmanaged(*Layer) = .empty,
    next_layer_id: u64 = 1,
    history: History = .{},
    viewport: Viewport = .{},

    fn deinit(self: *Canvas, alloc: std.mem.Allocator) void {
        for (self.layers.items) |l| {
            l.deinit(alloc);
            alloc.destroy(l);
        }
        self.layers.deinit(alloc);
        self.history.deinit(alloc);
    }
};

const Viewport = struct {
    zoom: f64 = 1.0,
    pan_x: f64 = 0.0,
    pan_y: f64 = 0.0,
    rotation: f64 = 0.0,
};

// ----------------------------------------------------------------------------
// History — persistent (tree-shaped) undo graph backed by full canvas snapshots.
//
// Each operation records a HistoryNode containing a snapshot of the layer
// stack + canvas-level state. undo / redo walk the tree by moving `current`
// along parent / child edges and restoring the snapshot at the new node.
//
// Branching is supported: undoing then performing a new operation creates a
// SIBLING child rather than discarding the previous future. That's the
// "branches are first-class so non-linear edits don't lose work" promise from
// the ROADMAP v0.2.0 MVP-10 entry.
//
// Memory: snapshots are full-state right now. Bounded-memory pruning is a
// v0.3.0 perf concern — the data structure already records cost-per-node so
// the pruner has accurate accounting once it lands. See VerisimDB Temporal
// modality (ADR-0003) for the production-grade persistence path.
// ----------------------------------------------------------------------------

const TileMap = std.AutoHashMapUnmanaged(TileKey, *Tile);

const LayerSnapshot = struct {
    name: []u8,
    visible: bool,
    opacity: f64,
    blend: BlendMode,
    tiles: TileMap,

    fn deinit(self: *LayerSnapshot, alloc: std.mem.Allocator) void {
        var it = self.tiles.valueIterator();
        while (it.next()) |t| alloc.destroy(t.*);
        self.tiles.deinit(alloc);
        alloc.free(self.name);
    }
};

const CanvasSnapshot = struct {
    width: u32,
    height: u32,
    format: u32,
    background: [4]f32,
    viewport: Viewport,
    layers: std.ArrayListUnmanaged(LayerSnapshot) = .empty,

    fn deinit(self: *CanvasSnapshot, alloc: std.mem.Allocator) void {
        for (self.layers.items) |*l| l.deinit(alloc);
        self.layers.deinit(alloc);
    }
};

const HistoryNode = struct {
    id: u64,
    parent: ?u64,
    children: std.ArrayListUnmanaged(u64) = .empty,
    op_name: []u8,
    cost_bytes: u64,
    snapshot: CanvasSnapshot,

    fn deinit(self: *HistoryNode, alloc: std.mem.Allocator) void {
        self.children.deinit(alloc);
        alloc.free(self.op_name);
        self.snapshot.deinit(alloc);
    }
};

const History = struct {
    nodes: std.AutoHashMapUnmanaged(u64, *HistoryNode) = .empty,
    root: u64 = 0,
    current: u64 = 0,
    next_id: u64 = 1,
    used_bytes: u64 = 0,
    budget_bytes: u64 = 1024 * 1024 * 512, // 512 MiB; pruning is a v0.3.0 concern

    fn deinit(self: *History, alloc: std.mem.Allocator) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |np| {
            np.*.deinit(alloc);
            alloc.destroy(np.*);
        }
        self.nodes.deinit(alloc);
    }
};

fn saturatingAdd(a: u64, b: u64) u64 {
    const res = @addWithOverflow(a, b);
    return if (res[1] != 0) std.math.maxInt(u64) else res[0];
}

fn saturatingSub(a: u64, b: u64) u64 {
    const res = @subWithOverflow(a, b);
    return if (res[1] != 0) 0 else res[0];
}

fn deleteSubtree(alloc: std.mem.Allocator, history: *History, node_id: u64) void {
    if (history.nodes.fetchRemove(node_id)) |kv| {
        const node = kv.value;
        for (node.children.items) |child_id| {
            deleteSubtree(alloc, history, child_id);
        }
        history.used_bytes = saturatingSub(history.used_bytes, node.cost_bytes);
        node.deinit(alloc);
        alloc.destroy(node);
    }
}

fn pruneHistory(alloc: std.mem.Allocator, c: *Canvas) void {
    while (c.history.used_bytes > c.history.budget_bytes) {
        const root_id = c.history.root;
        const cur_id = c.history.current;
        if (root_id == cur_id) {
            break;
        }

        var p = cur_id;
        var parent_id: ?u64 = null;
        while (true) {
            const node = c.history.nodes.get(p) orelse break;
            if (node.parent) |parent| {
                if (parent == root_id) {
                    parent_id = parent;
                    break;
                }
                p = parent;
            } else {
                break;
            }
        }

        if (parent_id == null) {
            break;
        }

        const old_root_node = c.history.nodes.get(root_id) orelse break;

        var i: usize = 0;
        while (i < old_root_node.children.items.len) {
            if (old_root_node.children.items[i] == p) {
                _ = old_root_node.children.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (c.history.nodes.get(p)) |p_node| {
            p_node.parent = null;
        }
        c.history.root = p;

        deleteSubtree(alloc, &c.history, root_id);
    }
}

fn cloneTileMap(alloc: std.mem.Allocator, src: *const TileMap) !TileMap {
    var out: TileMap = .empty;
    var it = src.iterator();
    while (it.next()) |e| {
        const t = try alloc.create(Tile);
        t.* = e.value_ptr.*.*;
        try out.put(alloc, e.key_ptr.*, t);
    }
    return out;
}

fn snapshotCanvas(alloc: std.mem.Allocator, c: *const Canvas) !CanvasSnapshot {
    var snap = CanvasSnapshot{
        .width = c.width,
        .height = c.height,
        .format = c.format,
        .background = c.background,
        .viewport = c.viewport,
    };
    errdefer snap.deinit(alloc);
    for (c.layers.items) |l| {
        const tiles_copy = try cloneTileMap(alloc, &l.tiles);
        const name_copy = try alloc.dupe(u8, l.name);
        try snap.layers.append(alloc, .{
            .name = name_copy,
            .visible = l.visible,
            .opacity = l.opacity,
            .blend = l.blend,
            .tiles = tiles_copy,
        });
    }
    return snap;
}

fn snapshotByteCost(snap: *const CanvasSnapshot) u64 {
    var bytes: u64 = @sizeOf(CanvasSnapshot);
    for (snap.layers.items) |*l| {
        bytes += @sizeOf(LayerSnapshot) + l.name.len;
        bytes += @as(u64, l.tiles.count()) * (@sizeOf(TileKey) + @sizeOf(Tile));
    }
    return bytes;
}

fn restoreCanvas(alloc: std.mem.Allocator, c: *Canvas, snap: *const CanvasSnapshot) !void {
    // Drop existing layers.
    for (c.layers.items) |l| {
        l.deinit(alloc);
        alloc.destroy(l);
    }
    c.layers.clearRetainingCapacity();
    c.background = snap.background;
    c.viewport = snap.viewport;
    // Rebuild layers from snapshot.
    for (snap.layers.items) |*ls| {
        const l = try alloc.create(Layer);
        l.* = .{
            .name = try alloc.dupe(u8, ls.name),
            .visible = ls.visible,
            .opacity = ls.opacity,
            .blend = ls.blend,
            .tiles = try cloneTileMap(alloc, &ls.tiles),
        };
        try c.layers.append(alloc, l);
    }
}

fn ensureHistoryInit(alloc: std.mem.Allocator, c: *Canvas) !void {
    if (c.history.nodes.count() != 0) return;
    const root = try alloc.create(HistoryNode);
    const snap = try snapshotCanvas(alloc, c);
    const cost = snapshotByteCost(&snap);
    root.* = .{
        .id = 0,
        .parent = null,
        .op_name = try alloc.dupe(u8, "init"),
        .cost_bytes = cost,
        .snapshot = snap,
    };
    try c.history.nodes.put(alloc, 0, root);
    c.history.root = 0;
    c.history.current = 0;
    c.history.next_id = 1;
    c.history.used_bytes = cost;
}

//==============================================================================
// 1b. Selection masks + clipboard (MVP-3 — selection tools)
//==============================================================================

/// Magic for a live SelectionMask, validated on every handle deref. "PMSK".
const PT_MASK_MAGIC: u32 = 0x504D534B;

/// A canvas-sized boolean selection mask. Handles cross the FFI as
/// @intFromPtr(mask); `liveMask` validates the magic before use so a stale or
/// garbage handle is a reported error, not a crash. (The selection ABI has no
/// explicit free; masks are owned by the backend allocator for its lifetime,
/// matching the canvas registry.)
const SelectionMask = struct {
    magic: u32,
    w: u32,
    h: u32,
    /// w*h bytes; 1 = selected, 0 = unselected. Row-major.
    sel: []u8,
};

fn liveMask(handle: u64) ?*SelectionMask {
    if (handle == 0) return null;
    const m: *SelectionMask = @ptrFromInt(handle);
    if (m.magic != PT_MASK_MAGIC) return null;
    return m;
}

fn newMask(alloc: std.mem.Allocator, w: u32, h: u32) !*SelectionMask {
    const m = try alloc.create(SelectionMask);
    errdefer alloc.destroy(m);
    const sel = try alloc.alloc(u8, @as(usize, w) * @as(usize, h));
    @memset(sel, 0);
    m.* = .{ .magic = PT_MASK_MAGIC, .w = w, .h = h, .sel = sel };
    return m;
}

/// A copied/cut region: a dense bbox of straight RGBA plus a per-cell selected
/// flag and the bbox origin in canvas coordinates. paste replays it at an
/// offset from that origin.
const Clipboard = struct {
    w: u32,
    h: u32,
    ox: u32,
    oy: u32,
    px: [][4]f32,
    has: []u8,
};

const State = struct {
    alloc: std.mem.Allocator,
    canvases: std.AutoHashMapUnmanaged(u64, *Canvas) = .empty,
    next_canvas_id: u64 = 1,
    clipboard: ?Clipboard = null,
    lock: std.Thread.Mutex = .{},

    fn replaceClipboard(self: *State, cb: Clipboard) void {
        if (self.clipboard) |old| {
            self.alloc.free(old.px);
            self.alloc.free(old.has);
        }
        self.clipboard = cb;
    }

    fn put(self: *State, c: *Canvas) !u64 {
        self.lock.lock();
        defer self.lock.unlock();
        const id = self.next_canvas_id;
        self.next_canvas_id += 1;
        try self.canvases.put(self.alloc, id, c);
        return id;
    }

    fn get(self: *State, id: u64) ?*Canvas {
        self.lock.lock();
        defer self.lock.unlock();
        return self.canvases.get(id);
    }
};

var state: ?State = null;

fn requireState() *State {
    return &state.?;
}

//==============================================================================
// 2. Helpers — colour, format, tile addressing
//==============================================================================

/// f32 → IEEE 754 binary16 bit pattern (stable-Rust-compatible algorithm).
/// Mirrors src/ephapax/src/lib.rs::f32_to_f16_bits.
fn f32ToF16Bits(value: f32) u16 {
    const bits: u32 = @bitCast(value);
    const sign: u16 = @intCast((bits >> 31) & 0x1);
    const exp_i: i32 = @intCast((bits >> 23) & 0xFF);
    const mant: u32 = bits & 0x007F_FFFF;

    if (exp_i == 0xFF) {
        const new_mant: u16 = if (mant != 0) @as(u16, @intCast(mant >> 13)) | 0x0200 else 0;
        return (sign << 15) | 0x7C00 | new_mant;
    }
    const new_exp: i32 = exp_i - 127 + 15;
    if (new_exp >= 0x1F) return (sign << 15) | 0x7C00;
    if (new_exp <= 0) {
        if (new_exp < -10) return sign << 15;
        const mant_with_lead: u32 = mant | 0x0080_0000;
        const shift: u5 = @intCast(@as(i32, 14) - new_exp);
        const shifted: u32 = mant_with_lead >> shift;
        const half_bit: u32 = @as(u32, 1) << (shift - 1);
        const lower_mask: u32 = (@as(u32, 1) << shift) - 1;
        const lower_bits: u32 = mant_with_lead & lower_mask;
        var rounded = shifted;
        if (lower_bits > half_bit or (lower_bits == half_bit and (shifted & 1) == 1)) rounded += 1;
        return (sign << 15) | @as(u16, @intCast(rounded));
    }
    var new_mant: u32 = mant >> 13;
    const half_bit: u32 = @as(u32, 1) << 12;
    const lower_mask: u32 = (@as(u32, 1) << 13) - 1;
    const lower_bits: u32 = mant & lower_mask;
    if (lower_bits > half_bit or (lower_bits == half_bit and (new_mant & 1) == 1)) {
        new_mant += 1;
        if (new_mant == 0x400) {
            new_mant = 0;
            const bumped: i32 = new_exp + 1;
            if (bumped >= 0x1F) return (sign << 15) | 0x7C00;
            return (sign << 15) | (@as(u16, @intCast(bumped)) << 10);
        }
    }
    return (sign << 15) | (@as(u16, @intCast(new_exp)) << 10) | @as(u16, @intCast(new_mant));
}

/// IEEE 754 binary16 bit pattern → f32. Inverse of f32ToF16Bits.
fn f16BitsToF32(bits: u16) f32 {
    const sign: u32 = @intCast(bits >> 15);
    const exp_u: u32 = @intCast((bits >> 10) & 0x1F);
    const mant: u32 = @intCast(bits & 0x03FF);
    var out: u32 = 0;
    if (exp_u == 0) {
        if (mant == 0) {
            out = sign << 31;
        } else {
            // Subnormal: normalise.
            var e: i32 = -1;
            var m: u32 = mant;
            while ((m & 0x0400) == 0) {
                m <<= 1;
                e -= 1;
            }
            const new_exp: u32 = @intCast(@as(i32, 127) + e + 1);
            const new_mant: u32 = (m & 0x03FF) << 13;
            out = (sign << 31) | (new_exp << 23) | new_mant;
        }
    } else if (exp_u == 0x1F) {
        out = (sign << 31) | 0x7F80_0000 | (mant << 13);
    } else {
        // Reorder to avoid u32 underflow when exp_u < 15 (i.e. f16 < 1.0).
        const new_exp: u32 = exp_u + 127 - 15;
        out = (sign << 31) | (new_exp << 23) | (mant << 13);
    }
    return @bitCast(out);
}

fn readPixelF32(layer: *const Layer, x: u32, y: u32) [4]f32 {
    const tx = x / TILE_SIZE;
    const ty = y / TILE_SIZE;
    const key = TileKey{ .tx = tx, .ty = ty };
    const tile_opt = layer.tiles.get(key);
    if (tile_opt) |t| {
        const lx = x % TILE_SIZE;
        const ly = y % TILE_SIZE;
        const idx: usize = (@as(usize, ly) * TILE_SIZE + @as(usize, lx)) * TILE_CHANNELS;
        return .{
            f16BitsToF32(t.pixels[idx + 0]),
            f16BitsToF32(t.pixels[idx + 1]),
            f16BitsToF32(t.pixels[idx + 2]),
            f16BitsToF32(t.pixels[idx + 3]),
        };
    }
    return .{ 0, 0, 0, 0 };
}

/// Single-pixel compositing: place `above` (already scaled by `opacity`) over
/// `below` using `mode`. Both are linear-light straight (non-premultiplied)
/// RGBA. Output is straight RGBA.
///
/// Formulas follow the standard "blend mode applied per channel, then
/// Porter-Duff src-over" convention used by Photoshop/Paint.NET:
///
///   α_eff      = above.a * opacity
///   blended_rgb = B(above.rgb, below.rgb)   -- per blend mode
///   result.rgb = blended_rgb * α_eff + below.rgb * below.a * (1 - α_eff)
///   result.a   = α_eff + below.a * (1 - α_eff)
///
/// The non-Normal modes still use src-over for alpha; only the RGB combination
/// differs.
fn blend(below: [4]f32, above: [4]f32, opacity: f32, mode: BlendMode) [4]f32 {
    const a_eff: f32 = above[3] * opacity;
    if (a_eff <= 0) return below;

    var blended: [4]f32 = undefined;
    switch (mode) {
        .normal => {
            blended[0] = above[0];
            blended[1] = above[1];
            blended[2] = above[2];
        },
        .multiply => {
            blended[0] = above[0] * below[0];
            blended[1] = above[1] * below[1];
            blended[2] = above[2] * below[2];
        },
        .screen => {
            blended[0] = 1.0 - (1.0 - above[0]) * (1.0 - below[0]);
            blended[1] = 1.0 - (1.0 - above[1]) * (1.0 - below[1]);
            blended[2] = 1.0 - (1.0 - above[2]) * (1.0 - below[2]);
        },
    }

    const one_minus_aeff: f32 = 1.0 - a_eff;
    const r_a: f32 = a_eff + below[3] * one_minus_aeff;
    if (r_a <= 0) return .{ 0, 0, 0, 0 };

    return .{
        (blended[0] * a_eff + below[0] * below[3] * one_minus_aeff) / r_a,
        (blended[1] * a_eff + below[1] * below[3] * one_minus_aeff) / r_a,
        (blended[2] * a_eff + below[2] * below[3] * one_minus_aeff) / r_a,
        r_a,
    };
}

fn quantizeU8(v: f32) u8 {
    // clamp() propagates NaN, and @intFromFloat(NaN) is illegal behaviour; map
    // a NaN channel (e.g. from a caller-supplied colour) to 0.
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
}

fn writePixelF16(layer: *Layer, alloc: std.mem.Allocator, x: u32, y: u32, c: [4]f32) !void {
    const tx = x / TILE_SIZE;
    const ty = y / TILE_SIZE;
    const lx = x % TILE_SIZE;
    const ly = y % TILE_SIZE;
    const key = TileKey{ .tx = tx, .ty = ty };
    const gop = try layer.tiles.getOrPut(alloc, key);
    if (!gop.found_existing) {
        const t = try alloc.create(Tile);
        t.* = .{};
        gop.value_ptr.* = t;
    }
    const t = gop.value_ptr.*;
    const idx: usize = (@as(usize, ly) * TILE_SIZE + @as(usize, lx)) * TILE_CHANNELS;
    t.pixels[idx + 0] = f32ToF16Bits(c[0]);
    t.pixels[idx + 1] = f32ToF16Bits(c[1]);
    t.pixels[idx + 2] = f32ToF16Bits(c[2]);
    t.pixels[idx + 3] = f32ToF16Bits(c[3]);
}

//==============================================================================
// 3. MVP-1 — Canvas (real implementation)
//==============================================================================

fn cpu_canvas_new(width: u32, height: u32, fmt: u32, bg_r: f32, bg_g: f32, bg_b: f32, bg_a: f32, out_canvas: *u64) callconv(.c) u32 {
    const s = requireState();
    if (width == 0 or height == 0 or width > MAX_CANVAS_DIM or height > MAX_CANVAS_DIM)
        return @intFromEnum(dispatcher.ResultCode.invalid_param);
    const c = s.alloc.create(Canvas) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    c.* = .{
        .width = width,
        .height = height,
        .format = fmt,
        .background = .{ bg_r, bg_g, bg_b, bg_a },
    };
    // Every canvas starts with one layer.
    const l = s.alloc.create(Layer) catch {
        s.alloc.destroy(c);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    const name = s.alloc.dupe(u8, "Background") catch {
        s.alloc.destroy(l);
        s.alloc.destroy(c);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    l.* = .{ .name = name };
    c.layers.append(s.alloc, l) catch {
        l.deinit(s.alloc);
        s.alloc.destroy(l);
        s.alloc.destroy(c);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    // Capture the empty-canvas snapshot as the history root. Eager init avoids
    // the "first history_record captures post-op state as root" footgun where
    // undoing all the way back lands on the first op's after-state instead of
    // the truly initial blank canvas.
    ensureHistoryInit(s.alloc, c) catch {
        c.deinit(s.alloc);
        s.alloc.destroy(c);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    const id = s.put(c) catch {
        c.deinit(s.alloc);
        s.alloc.destroy(c);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    out_canvas.* = id;
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_canvas_resize(canvas: u64, w: u32, h: u32, _ax: f64, _ay: f64) callconv(.c) u32 {
    _ = _ax;
    _ = _ay;
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    if (w == 0 or h == 0 or w > MAX_CANVAS_DIM or h > MAX_CANVAS_DIM)
        return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.width = w;
    c.height = h;
    // Existing tiles outside the new bounds are not eagerly dropped; that's a
    // post-MVP optimisation. Correctness is preserved.
    return @intFromEnum(dispatcher.ResultCode.ok);
}

//==============================================================================
// 4. MVP-12 — Layers (real implementation)
//==============================================================================

fn cpu_layer_new(canvas: u64, _after: u64, _has_after: u32, name: [*:0]const u8, out_layer: *u64) callconv(.c) u32 {
    _ = _after;
    _ = _has_after;
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    const l = s.alloc.create(Layer) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    const name_copy = s.alloc.dupe(u8, std.mem.span(name)) catch {
        s.alloc.destroy(l);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    l.* = .{ .name = name_copy };
    c.layers.append(s.alloc, l) catch {
        l.deinit(s.alloc);
        s.alloc.destroy(l);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    const id = c.next_layer_id;
    c.next_layer_id += 1;
    out_layer.* = id;
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_layer_delete(canvas: u64, layer: u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    const idx = @as(usize, layer - 1);
    const l = c.layers.orderedRemove(idx);
    l.deinit(s.alloc);
    s.alloc.destroy(l);
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_layer_reorder(canvas: u64, layer: u64, new_index: u32) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    if (new_index >= c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    const old_idx: usize = @intCast(layer - 1);
    const l = c.layers.orderedRemove(old_idx);
    c.layers.insert(s.alloc, @intCast(new_index), l) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_layer_set_visible(canvas: u64, layer: u64, visible: u32) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.layers.items[@intCast(layer - 1)].visible = visible != 0;
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_layer_set_opacity(canvas: u64, layer: u64, opacity: f64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.layers.items[@intCast(layer - 1)].opacity = std.math.clamp(opacity, 0.0, 1.0);
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_layer_set_blend(canvas: u64, layer: u64, mode: u32) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    if (mode > @intFromEnum(BlendMode.screen)) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.layers.items[@intCast(layer - 1)].blend = @enumFromInt(mode);
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_canvas_render_rgba8_internal(c: *const Canvas, x: u32, y: u32, w: u32, h: u32, out_buf: [*]u8, out_buf_len: usize) u32 {
    if (@as(u64, x) + @as(u64, w) > @as(u64, c.width)) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    if (@as(u64, y) + @as(u64, h) > @as(u64, c.height)) return @intFromEnum(dispatcher.ResultCode.invalid_param);

    const needed: usize = @as(usize, w) * @as(usize, h) * 4;
    if (out_buf_len < needed) return @intFromEnum(dispatcher.ResultCode.invalid_param);

    var py: u32 = 0;
    while (py < h) : (py += 1) {
        var px: u32 = 0;
        while (px < w) : (px += 1) {
            const cx: u32 = x + px;
            const cy: u32 = y + py;

            // Start with the canvas background as the bottom of the stack.
            var below: [4]f32 = c.background;

            // Composite each visible layer in stack order (index 0 = bottom).
            for (c.layers.items) |layer| {
                if (!layer.visible) continue;
                const above = readPixelF32(layer, cx, cy);
                below = blend(below, above, @floatCast(layer.opacity), layer.blend);
            }

            const out_idx: usize = (@as(usize, py) * @as(usize, w) + @as(usize, px)) * 4;
            out_buf[out_idx + 0] = quantizeU8(below[0]);
            out_buf[out_idx + 1] = quantizeU8(below[1]);
            out_buf[out_idx + 2] = quantizeU8(below[2]);
            out_buf[out_idx + 3] = quantizeU8(below[3]);
        }
    }
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_canvas_render_rgba8(canvas: u64, x: u32, y: u32, w: u32, h: u32, out_buf: [*]u8, out_buf_len: usize) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    return cpu_canvas_render_rgba8_internal(c, x, y, w, h, out_buf, out_buf_len);
}

//==============================================================================
// 5. MVP-11 — Viewport (real implementation)
//==============================================================================

fn cpu_viewport_set(canvas: u64, zoom: f64, px: f64, py: f64, rot: f64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    c.viewport = .{ .zoom = zoom, .pan_x = px, .pan_y = py, .rotation = rot };
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_viewport_fit(canvas: u64, oz: *f64, opx: *f64, opy: *f64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    // Fit-to-window heuristic; without a viewport size from the display
    // backend we just return zoom=1, pan=0.
    oz.* = 1.0;
    opx.* = 0.0;
    opy.* = 0.0;
    return @intFromEnum(dispatcher.ResultCode.ok);
}

//==============================================================================
// 6. MVP-3 — Pencil stub (placeholder, writes one pixel per point)
//==============================================================================

fn cpu_tool_stroke_pencil(canvas: u64, layer: u64, n: u32, points: [*]const f64, points_len: usize, colour: *const [4]f32) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    const l = c.layers.items[@intCast(layer - 1)];
    // Each pencil point is a flat (x, y) f64 pair, so the buffer must hold 2*n
    // elements. Validate against the caller-declared length before indexing —
    // without it an over-large `n` is an out-of-bounds read. `i` is usize so
    // `i * 2` cannot wrap the index arithmetic.
    const needed = std.math.mul(usize, n, 2) catch return @intFromEnum(dispatcher.ResultCode.invalid_param);
    if (needed > points_len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const px = points[i * 2];
        const py = points[i * 2 + 1];
        const ix = finiteFloorU32(px, c.width) orelse continue;
        const iy = finiteFloorU32(py, c.height) orelse continue;
        writePixelF16(l, s.alloc, ix, iy, colour.*) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    }
    return @intFromEnum(dispatcher.ResultCode.ok);
}

//==============================================================================
// 6b. Brush footprint + stamp (MVP-3)
//
//   brushAlphaProfile maps normalised distance + hardness to a per-pixel
//   coverage value. The "hardness" axis is the fraction of the radius that
//   stays at full alpha; beyond it, a smoothstep falloff carries down to
//   alpha=0 at the radius edge. hardness=1 → hard disk, hardness=0 → fully
//   soft (Photoshop / Krita / Paint.NET semantics).
//
//   stampBrush places one footprint at (cx, cy). A stroke is just a sequence
//   of stamps along the polyline between successive stroke points, spaced by
//   `spacing` (fraction of brush diameter).
//==============================================================================

fn brushAlphaProfile(norm_dist: f64, hardness: f64) f64 {
    if (norm_dist >= 1.0) return 0;
    if (norm_dist <= hardness) return 1.0;
    if (hardness >= 1.0) return 1.0;
    const t: f64 = (norm_dist - hardness) / (1.0 - hardness);
    // smoothstep(0,1,t)
    const ss: f64 = t * t * (3.0 - 2.0 * t);
    return 1.0 - ss;
}

fn stampBrush(
    layer: *Layer,
    alloc: std.mem.Allocator,
    canvas_w: u32,
    canvas_h: u32,
    cx: f64,
    cy: f64,
    radius: f64,
    hardness: f64,
    opacity: f64,
    colour: [4]f32,
) !void {
    if (radius <= 0) return;
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(radius)) return;
    const bbox_x0_f = @floor(cx - radius - 1.0);
    const bbox_y0_f = @floor(cy - radius - 1.0);
    const bbox_x1_f = @ceil(cx + radius + 1.0);
    const bbox_y1_f = @ceil(cy + radius + 1.0);

    const w_i: i64 = @intCast(canvas_w);
    const h_i: i64 = @intCast(canvas_h);

    // Clamp the footprint bbox into the canvas before the i64 cast: this bounds
    // the iteration and prevents an attacker-large coordinate from overflowing
    // the conversion.
    const x0: i64 = finiteToI64Clamped(bbox_x0_f, 0, w_i);
    const y0: i64 = finiteToI64Clamped(bbox_y0_f, 0, h_i);
    const x1: i64 = finiteToI64Clamped(bbox_x1_f, 0, w_i);
    const y1: i64 = finiteToI64Clamped(bbox_y1_f, 0, h_i);

    var y: i64 = y0;
    while (y <= y1) : (y += 1) {
        if (y < 0 or y >= h_i) continue;
        var x: i64 = x0;
        while (x <= x1) : (x += 1) {
            if (x < 0 or x >= w_i) continue;
            const fx: f64 = @as(f64, @floatFromInt(x)) + 0.5;
            const fy: f64 = @as(f64, @floatFromInt(y)) + 0.5;
            const ddx = fx - cx;
            const ddy = fy - cy;
            const dist = @sqrt(ddx * ddx + ddy * ddy);
            if (dist >= radius) continue;
            const norm_d = dist / radius;
            const cov = brushAlphaProfile(norm_d, hardness);
            const stamp_a: f64 = cov * opacity * @as(f64, colour[3]);
            if (stamp_a <= 0) continue;

            const ux: u32 = @intCast(x);
            const uy: u32 = @intCast(y);
            const dst = readPixelF32(layer, ux, uy);
            const sa: f32 = @floatCast(stamp_a);
            const one_minus_sa: f32 = 1.0 - sa;
            const result_a: f32 = sa + dst[3] * one_minus_sa;
            var rr: f32 = 0;
            var rg: f32 = 0;
            var rb: f32 = 0;
            if (result_a > 0) {
                rr = (colour[0] * sa + dst[0] * dst[3] * one_minus_sa) / result_a;
                rg = (colour[1] * sa + dst[1] * dst[3] * one_minus_sa) / result_a;
                rb = (colour[2] * sa + dst[2] * dst[3] * one_minus_sa) / result_a;
            }
            try writePixelF16(layer, alloc, ux, uy, .{ rr, rg, rb, result_a });
        }
    }
}

//==============================================================================
// 6c. Eraser / fill / selection helpers (MVP-3 tool primitives)
//==============================================================================

/// Shorthand for returning a dispatcher result code from a C-ABI tool fn.
inline fn rcode(code: dispatcher.ResultCode) u32 {
    return @intFromEnum(code);
}

/// Erase footprint: lower destination alpha by the brush coverage, leaving RGB
/// intact. `strength` is the already-clamped erase opacity. Fully-transparent
/// pixels are skipped so no tile is allocated just to write zero.
fn stampEraser(
    layer: *Layer,
    alloc: std.mem.Allocator,
    canvas_w: u32,
    canvas_h: u32,
    cx: f64,
    cy: f64,
    radius: f64,
    hardness: f64,
    strength: f64,
) !void {
    if (radius <= 0 or strength <= 0) return;
    if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or !std.math.isFinite(radius)) return;

    const w_i: i64 = @intCast(canvas_w);
    const h_i: i64 = @intCast(canvas_h);
    const x0: i64 = finiteToI64Clamped(@floor(cx - radius - 1.0), 0, w_i);
    const y0: i64 = finiteToI64Clamped(@floor(cy - radius - 1.0), 0, h_i);
    const x1: i64 = finiteToI64Clamped(@ceil(cx + radius + 1.0), 0, w_i);
    const y1: i64 = finiteToI64Clamped(@ceil(cy + radius + 1.0), 0, h_i);

    var y: i64 = y0;
    while (y <= y1) : (y += 1) {
        if (y < 0 or y >= h_i) continue;
        var x: i64 = x0;
        while (x <= x1) : (x += 1) {
            if (x < 0 or x >= w_i) continue;
            const fx: f64 = @as(f64, @floatFromInt(x)) + 0.5;
            const fy: f64 = @as(f64, @floatFromInt(y)) + 0.5;
            const ddx = fx - cx;
            const ddy = fy - cy;
            const dist = @sqrt(ddx * ddx + ddy * ddy);
            if (dist >= radius) continue;
            const cov = brushAlphaProfile(dist / radius, hardness);
            const e: f64 = cov * strength;
            if (e <= 0) continue;

            const ux: u32 = @intCast(x);
            const uy: u32 = @intCast(y);
            const dst = readPixelF32(layer, ux, uy);
            if (dst[3] <= 0) continue; // already transparent — nothing to erase
            const ef: f32 = @floatCast(std.math.clamp(e, 0.0, 1.0));
            const new_a: f32 = dst[3] * (1.0 - ef);
            try writePixelF16(layer, alloc, ux, uy, .{ dst[0], dst[1], dst[2], new_a });
        }
    }
}

/// Chebyshev (per-channel max-abs) colour match used by the fill tool.
fn colourWithin(a: [4]f32, b: [4]f32, tol: f32) bool {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (@abs(a[i] - b[i]) > tol) return false;
    }
    return true;
}

/// Even-odd ray-casting point-in-polygon test for the lasso. `pts` holds
/// `2*n` f64s as (x, y) pairs; the polygon is implicitly closed.
fn pointInPoly(x: f64, y: f64, pts: [*]const f64, n: u32) bool {
    var inside = false;
    var i: usize = 0;
    var j: usize = @as(usize, n) - 1;
    while (i < n) : (i += 1) {
        const xi = pts[i * 2];
        const yi = pts[i * 2 + 1];
        const xj = pts[j * 2];
        const yj = pts[j * 2 + 1];
        if (((yi > y) != (yj > y)) and
            (x < (xj - xi) * (y - yi) / (yj - yi) + xi))
        {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

const SelectionError = error{ OutOfMemory, EmptySelection };

/// Copy the masked pixels of `l` into the state clipboard as a tight bbox.
/// Caller must hold `c.lock`. Errors if the selection is empty.
fn copyMaskedRegion(s: *State, c: *Canvas, l: *Layer, m: *SelectionMask) SelectionError!void {
    var minx: u32 = c.width;
    var miny: u32 = c.height;
    var maxx: u32 = 0;
    var maxy: u32 = 0;
    var any = false;
    var y: u32 = 0;
    while (y < c.height) : (y += 1) {
        var x: u32 = 0;
        while (x < c.width) : (x += 1) {
            if (m.sel[@as(usize, y) * c.width + x] != 0) {
                any = true;
                if (x < minx) minx = x;
                if (y < miny) miny = y;
                if (x > maxx) maxx = x;
                if (y > maxy) maxy = y;
            }
        }
    }
    if (!any) return SelectionError.EmptySelection;

    const bw: u32 = maxx - minx + 1;
    const bh: u32 = maxy - miny + 1;
    const cnt: usize = @as(usize, bw) * @as(usize, bh);
    const px = try s.alloc.alloc([4]f32, cnt);
    errdefer s.alloc.free(px);
    const has = try s.alloc.alloc(u8, cnt);
    @memset(has, 0);

    var yy: u32 = miny;
    while (yy <= maxy) : (yy += 1) {
        var xx: u32 = minx;
        while (xx <= maxx) : (xx += 1) {
            const bi: usize = @as(usize, yy - miny) * bw + (xx - minx);
            if (m.sel[@as(usize, yy) * c.width + xx] != 0) {
                px[bi] = readPixelF32(l, xx, yy);
                has[bi] = 1;
            } else {
                px[bi] = .{ 0, 0, 0, 0 };
            }
        }
    }
    s.replaceClipboard(.{ .w = bw, .h = bh, .ox = minx, .oy = miny, .px = px, .has = has });
}

//==============================================================================
// 6a. Codecs — PNG and PPM encoders used by io_save (MVP-2)
//
//   These are pure-Zig encoders with no external dependencies. PNG uses
//   deflate STORED blocks (no compression) — perfectly valid PNG, just
//   larger files than a real LZ77 compressor would produce. We trade
//   bytes for code simplicity at MVP; real compression lands when an
//   accelerated backend with a fast DEFLATE / zstd / etc. comes online.
//==============================================================================

const CRC32_POLY: u32 = 0xEDB88320;

fn crc32Byte(crc: u32, byte: u8) u32 {
    var c: u32 = crc ^ byte;
    var i: u3 = 0;
    while (i < 7) : (i += 1) {
        c = if ((c & 1) != 0) (c >> 1) ^ CRC32_POLY else c >> 1;
    }
    // unrolled last iter to keep i: u3 in range
    c = if ((c & 1) != 0) (c >> 1) ^ CRC32_POLY else c >> 1;
    return c;
}

fn crc32Concat(parts: []const []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (parts) |p| for (p) |b| {
        c = crc32Byte(c, b);
    };
    return c ^ 0xFFFFFFFF;
}

fn adler32(data: []const u8) u32 {
    var s1: u32 = 1;
    var s2: u32 = 0;
    for (data) |b| {
        s1 = (s1 + b) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    return (s2 << 16) | s1;
}

fn writeBE32(buf: []u8, offset: usize, val: u32) void {
    buf[offset + 0] = @intCast((val >> 24) & 0xFF);
    buf[offset + 1] = @intCast((val >> 16) & 0xFF);
    buf[offset + 2] = @intCast((val >> 8) & 0xFF);
    buf[offset + 3] = @intCast(val & 0xFF);
}

fn writeLE16(buf: []u8, offset: usize, val: u16) void {
    buf[offset + 0] = @intCast(val & 0xFF);
    buf[offset + 1] = @intCast((val >> 8) & 0xFF);
}

/// Encode RGBA8 pixels as a valid PNG image. Caller owns the returned slice.
fn encodePngRgba8(alloc: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    if (rgba.len != @as(usize, width) * @as(usize, height) * 4) return error.InvalidParam;

    // Step 1 — build the filtered scanlines (filter byte 0 = None, per row).
    const row_bytes: usize = @as(usize, width) * 4;
    const filtered_len: usize = (row_bytes + 1) * @as(usize, height);
    var filtered = try alloc.alloc(u8, filtered_len);
    defer alloc.free(filtered);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const dst_off: usize = @as(usize, y) * (row_bytes + 1);
        filtered[dst_off] = 0; // filter type None
        const src_off: usize = @as(usize, y) * row_bytes;
        @memcpy(filtered[dst_off + 1 .. dst_off + 1 + row_bytes], rgba[src_off .. src_off + row_bytes]);
    }

    // Step 2 — wrap as a zlib stream of stored deflate blocks.
    const max_block: usize = 65535;
    const block_count: usize = (filtered_len + max_block - 1) / max_block;
    const block_count_safe: usize = if (block_count == 0) 1 else block_count;
    const idat_len: usize = 2 + block_count_safe * 5 + filtered_len + 4;
    var idat = try alloc.alloc(u8, idat_len);
    defer alloc.free(idat);

    // zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (FCHECK OK: 0x7801 mod 31 == 0).
    idat[0] = 0x78;
    idat[1] = 0x01;
    var p: usize = 2;

    if (filtered_len == 0) {
        // Edge: write one empty final stored block.
        idat[p] = 0x01;
        writeLE16(idat, p + 1, 0);
        writeLE16(idat, p + 3, 0xFFFF);
        p += 5;
    } else {
        var in_pos: usize = 0;
        while (in_pos < filtered_len) {
            const remaining: usize = filtered_len - in_pos;
            const block_len: usize = if (remaining > max_block) max_block else remaining;
            const is_final: bool = (in_pos + block_len >= filtered_len);
            idat[p] = if (is_final) @as(u8, 0x01) else @as(u8, 0x00);
            p += 1;
            const len_u16: u16 = @intCast(block_len);
            writeLE16(idat, p, len_u16);
            p += 2;
            writeLE16(idat, p, ~len_u16);
            p += 2;
            @memcpy(idat[p .. p + block_len], filtered[in_pos .. in_pos + block_len]);
            p += block_len;
            in_pos += block_len;
        }
    }

    const adler = adler32(filtered);
    writeBE32(idat, p, adler);
    p += 4;

    const idat_payload = idat[0..p];

    // Step 3 — assemble the PNG: signature + IHDR + IDAT + IEND.
    var ihdr: [13]u8 = undefined;
    writeBE32(ihdr[0..], 0, width);
    writeBE32(ihdr[0..], 4, height);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type 6 = RGBA
    ihdr[10] = 0; // compression method (deflate)
    ihdr[11] = 0; // filter method 0
    ihdr[12] = 0; // no interlace

    const total: usize = 8 + (4 + 4 + 13 + 4) + (4 + 4 + idat_payload.len + 4) + (4 + 4 + 0 + 4);
    var out = try alloc.alloc(u8, total);

    var op: usize = 0;
    // Signature
    const sig = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
    @memcpy(out[op .. op + 8], &sig);
    op += 8;

    // IHDR chunk
    writeBE32(out, op, 13);
    op += 4;
    @memcpy(out[op .. op + 4], "IHDR");
    op += 4;
    @memcpy(out[op .. op + 13], &ihdr);
    op += 13;
    writeBE32(out, op, crc32Concat(&.{ "IHDR", ihdr[0..] }));
    op += 4;

    // IDAT chunk
    writeBE32(out, op, @intCast(idat_payload.len));
    op += 4;
    @memcpy(out[op .. op + 4], "IDAT");
    op += 4;
    @memcpy(out[op .. op + idat_payload.len], idat_payload);
    op += idat_payload.len;
    writeBE32(out, op, crc32Concat(&.{ "IDAT", idat_payload }));
    op += 4;

    // IEND chunk
    writeBE32(out, op, 0);
    op += 4;
    @memcpy(out[op .. op + 4], "IEND");
    op += 4;
    writeBE32(out, op, crc32Concat(&.{ "IEND", &.{} }));
    op += 4;

    return out;
}

fn encodePpmRgba8(alloc: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });
    const total: usize = header.len + @as(usize, width) * @as(usize, height) * 3;
    var out = try alloc.alloc(u8, total);
    @memcpy(out[0..header.len], header);
    var src: usize = 0;
    var dst: usize = header.len;
    while (src < rgba.len) : (src += 4) {
        out[dst + 0] = rgba[src + 0];
        out[dst + 1] = rgba[src + 1];
        out[dst + 2] = rgba[src + 2];
        dst += 3;
    }
    return out;
}

const Cstdio = struct {
    extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
    extern "c" fn fclose(stream: *anyopaque) c_int;
};

fn writeFileBytes(path: [*:0]const u8, data: []const u8) bool {
    const fh = Cstdio.fopen(path, "wb") orelse return false;
    defer _ = Cstdio.fclose(fh);
    return Cstdio.fwrite(data.ptr, 1, data.len, fh) == data.len;
}

//==============================================================================
// 7. Stubs returning not_implemented — to be filled in MVP-by-MVP
//==============================================================================
// The dispatcher honours `not_implemented` from a non-reference backend by
// falling back to the reference. From the reference itself, `not_implemented`
// is a flag that this operation still needs its real body — the test harness
// will surface these as TODO before v0.2.0 closes.

fn cpu_io_open(_path: [*:0]const u8, _fmt: ?[*:0]const u8, _out: *u64) callconv(.c) u32 {
    _ = _path;
    _ = _fmt;
    _ = _out;
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

// SECURITY: `path` is written verbatim via fopen() with no canonicalisation or
// sandboxing. That is correct for the local desktop app, whose user chooses the
// save location ("Save As anywhere"). It is NOT safe to forward a request-
// supplied path here from a network surface: any future REST/connector dispatch
// that reaches io_save MUST constrain paths to a sandbox and reject
// traversal/absolute/symlink-escaping paths at that boundary. See
// audits/SECURITY-REVIEW-2026-06-15.md (M2).
fn cpu_io_save(canvas: u64, path: [*:0]const u8, fmt: [*:0]const u8, _opts: [*:0]const u8) callconv(.c) u32 {
    _ = _opts;
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    if (std.mem.span(path).len == 0) return @intFromEnum(dispatcher.ResultCode.invalid_param);

    // Step 1 — composite the canvas into an RGBA8 buffer through the same
    // render path the rest of the pipeline uses.
    const pixel_count: usize = @as(usize, c.width) * @as(usize, c.height);
    const buf = s.alloc.alloc(u8, pixel_count * 4) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    defer s.alloc.free(buf);
    const rc = cpu_canvas_render_rgba8(canvas, 0, 0, c.width, c.height, buf.ptr, buf.len);
    if (rc != @intFromEnum(dispatcher.ResultCode.ok)) return rc;

    // Step 2 — encode according to the requested format.
    const fmt_str = std.mem.span(fmt);
    if (std.mem.eql(u8, fmt_str, "png")) {
        const bytes = encodePngRgba8(s.alloc, c.width, c.height, buf) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
        defer s.alloc.free(bytes);
        return if (writeFileBytes(path, bytes)) @intFromEnum(dispatcher.ResultCode.ok) else @intFromEnum(dispatcher.ResultCode.err);
    }
    if (std.mem.eql(u8, fmt_str, "ppm")) {
        const bytes = encodePpmRgba8(s.alloc, c.width, c.height, buf) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
        defer s.alloc.free(bytes);
        return if (writeFileBytes(path, bytes)) @intFromEnum(dispatcher.ResultCode.ok) else @intFromEnum(dispatcher.ResultCode.err);
    }
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

fn cpu_tool_stroke_brush(
    canvas: u64,
    layer: u64,
    brush_state: *const dispatcher.BrushStateC,
    n: u32,
    points: [*]const dispatcher.StrokePointC,
    points_len: usize,
    colour: *const [4]f32,
) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    // `points` holds one StrokePointC per point; reject an `n` larger than the
    // caller-declared buffer before indexing.
    if (n > points_len) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    const l = c.layers.items[@intCast(layer - 1)];

    const radius: f64 = brush_state.radius;
    if (radius <= 0) return @intFromEnum(dispatcher.ResultCode.invalid_param);
    const hardness: f64 = std.math.clamp(brush_state.hardness, 0.0, 1.0);
    const opacity: f64 = std.math.clamp(brush_state.opacity, 0.0, 1.0);
    const spacing_frac: f64 = if (brush_state.spacing > 0.0) brush_state.spacing else 0.25;
    // Distance between successive stamps, in pixels.
    const spacing_px: f64 = spacing_frac * radius * 2.0;

    if (n == 0) return @intFromEnum(dispatcher.ResultCode.ok);

    // Always stamp the first point — single-tap brush works even with one input point.
    stampBrush(l, s.alloc, c.width, c.height, points[0].x, points[0].y, radius, hardness, opacity, colour.*) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);

    // Walk consecutive pairs, lerp at spacing intervals.
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const prev = points[i - 1];
        const curr = points[i];
        if (!std.math.isFinite(prev.x) or !std.math.isFinite(prev.y) or
            !std.math.isFinite(curr.x) or !std.math.isFinite(curr.y)) continue;
        const dx = curr.x - prev.x;
        const dy = curr.y - prev.y;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist <= 0) continue;
        const stamps_f = dist / spacing_px;
        const stamps: u32 = if (stamps_f < 1.0)
            1
        else if (stamps_f >= @as(f64, @floatFromInt(MAX_STROKE_STAMPS)))
            MAX_STROKE_STAMPS
        else
            @intFromFloat(@ceil(stamps_f));
        var k: u32 = 1;
        while (k <= stamps) : (k += 1) {
            const t: f64 = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(stamps));
            const sx = prev.x + dx * t;
            const sy = prev.y + dy * t;
            stampBrush(l, s.alloc, c.width, c.height, sx, sy, radius, hardness, opacity, colour.*) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
        }
    }

    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_tool_stroke_eraser(
    canvas: u64,
    layer: u64,
    brush_state: *const dispatcher.BrushStateC,
    n: u32,
    points: [*]const dispatcher.StrokePointC,
    points_len: usize,
    mode: u32,
) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return rcode(.invalid_param);
    // Only mode 0 (Normal — lower alpha) is defined for v0.3.0; reject others
    // loudly rather than silently treating them as Normal.
    if (mode != 0) return rcode(.invalid_param);
    if (n > points_len) return rcode(.invalid_param);
    const l = c.layers.items[@intCast(layer - 1)];

    const radius: f64 = brush_state.radius;
    if (radius <= 0) return rcode(.invalid_param);
    const hardness: f64 = std.math.clamp(brush_state.hardness, 0.0, 1.0);
    const strength: f64 = std.math.clamp(brush_state.opacity, 0.0, 1.0);
    const spacing_frac: f64 = if (brush_state.spacing > 0.0) brush_state.spacing else 0.25;
    const spacing_px: f64 = spacing_frac * radius * 2.0;

    if (n == 0) return rcode(.ok);

    stampEraser(l, s.alloc, c.width, c.height, points[0].x, points[0].y, radius, hardness, strength) catch return rcode(.out_of_memory);

    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const prev = points[i - 1];
        const curr = points[i];
        if (!std.math.isFinite(prev.x) or !std.math.isFinite(prev.y) or
            !std.math.isFinite(curr.x) or !std.math.isFinite(curr.y)) continue;
        const dx = curr.x - prev.x;
        const dy = curr.y - prev.y;
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist <= 0) continue;
        const stamps_f = dist / spacing_px;
        const stamps: u32 = if (stamps_f < 1.0)
            1
        else if (stamps_f >= @as(f64, @floatFromInt(MAX_STROKE_STAMPS)))
            MAX_STROKE_STAMPS
        else
            @intFromFloat(@ceil(stamps_f));
        var k: u32 = 1;
        while (k <= stamps) : (k += 1) {
            const t: f64 = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(stamps));
            const sx = prev.x + dx * t;
            const sy = prev.y + dy * t;
            stampEraser(l, s.alloc, c.width, c.height, sx, sy, radius, hardness, strength) catch return rcode(.out_of_memory);
        }
    }

    return rcode(.ok);
}

fn cpu_tool_sample_colour(_c: u64, _x: f64, _y: f64, _a: u32, _out: *[4]f32) callconv(.c) u32 {
    _ = _c;
    _ = _x;
    _ = _y;
    _ = _a;
    _ = _out;
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

fn cpu_tool_fill(canvas: u64, layer: u64, sx: f64, sy: f64, colour: *const [4]f32, tol: f64, contig: u32) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return rcode(.invalid_param);
    const l = c.layers.items[@intCast(layer - 1)];

    const seed_x = finiteFloorU32(sx, c.width) orelse return rcode(.invalid_param);
    const seed_y = finiteFloorU32(sy, c.height) orelse return rcode(.invalid_param);

    const target = readPixelF32(l, seed_x, seed_y);
    const fill_colour = colour.*;
    const tolf: f32 = if (std.math.isNan(tol) or tol < 0) 0.0 else @floatCast(tol);
    const total: usize = @as(usize, c.width) * @as(usize, c.height);

    if (contig != 0) {
        // Contiguous 4-connected flood fill. Mark pixels visited on push so each
        // enters the work stack at most once (stack bounded by pixel count).
        const visited = s.alloc.alloc(u8, total) catch return rcode(.out_of_memory);
        defer s.alloc.free(visited);
        @memset(visited, 0);

        var stack: std.ArrayListUnmanaged(usize) = .empty;
        defer stack.deinit(s.alloc);
        const seed_idx: usize = @as(usize, seed_y) * c.width + seed_x;
        visited[seed_idx] = 1;
        stack.append(s.alloc, seed_idx) catch return rcode(.out_of_memory);

        while (stack.items.len != 0) {
            const idx = stack.items[stack.items.len - 1];
            stack.items.len -= 1;
            const x: u32 = @intCast(idx % c.width);
            const y: u32 = @intCast(idx / c.width);
            if (!colourWithin(readPixelF32(l, x, y), target, tolf)) continue;
            writePixelF16(l, s.alloc, x, y, fill_colour) catch return rcode(.out_of_memory);
            if (x > 0 and visited[idx - 1] == 0) {
                visited[idx - 1] = 1;
                stack.append(s.alloc, idx - 1) catch return rcode(.out_of_memory);
            }
            if (x + 1 < c.width and visited[idx + 1] == 0) {
                visited[idx + 1] = 1;
                stack.append(s.alloc, idx + 1) catch return rcode(.out_of_memory);
            }
            if (y > 0 and visited[idx - c.width] == 0) {
                visited[idx - c.width] = 1;
                stack.append(s.alloc, idx - c.width) catch return rcode(.out_of_memory);
            }
            if (y + 1 < c.height and visited[idx + c.width] == 0) {
                visited[idx + c.width] = 1;
                stack.append(s.alloc, idx + c.width) catch return rcode(.out_of_memory);
            }
        }
    } else {
        // Global fill: every pixel matching the seed colour within tolerance.
        var y: u32 = 0;
        while (y < c.height) : (y += 1) {
            var x: u32 = 0;
            while (x < c.width) : (x += 1) {
                if (colourWithin(readPixelF32(l, x, y), target, tolf)) {
                    writePixelF16(l, s.alloc, x, y, fill_colour) catch return rcode(.out_of_memory);
                }
            }
        }
    }
    return rcode(.ok);
}

fn cpu_selection_rect(canvas: u64, x0: u32, y0: u32, x1: u32, y1: u32, out_mask: *u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    const m = newMask(s.alloc, c.width, c.height) catch return rcode(.out_of_memory);
    // Half-open [lo, hi) in each axis, clamped to the canvas; corners may arrive
    // in any order.
    const lo_x = @min(@min(x0, x1), c.width);
    const hi_x = @min(@max(x0, x1), c.width);
    const lo_y = @min(@min(y0, y1), c.height);
    const hi_y = @min(@max(y0, y1), c.height);
    var yy: u32 = lo_y;
    while (yy < hi_y) : (yy += 1) {
        var xx: u32 = lo_x;
        while (xx < hi_x) : (xx += 1) {
            m.sel[@as(usize, yy) * c.width + xx] = 1;
        }
    }
    out_mask.* = @intFromPtr(m);
    return rcode(.ok);
}

fn cpu_selection_lasso(canvas: u64, n: u32, pts: [*]const f64, out_mask: *u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (n < 3) return rcode(.invalid_param);
    const m = newMask(s.alloc, c.width, c.height) catch return rcode(.out_of_memory);
    var py: u32 = 0;
    while (py < c.height) : (py += 1) {
        const fy: f64 = @as(f64, @floatFromInt(py)) + 0.5;
        var px: u32 = 0;
        while (px < c.width) : (px += 1) {
            const fx: f64 = @as(f64, @floatFromInt(px)) + 0.5;
            if (pointInPoly(fx, fy, pts, n)) m.sel[@as(usize, py) * c.width + px] = 1;
        }
    }
    out_mask.* = @intFromPtr(m);
    return rcode(.ok);
}

fn cpu_selection_invert(canvas: u64, mask: u64, out_mask: *u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    const src = liveMask(mask) orelse return rcode(.invalid_param);
    if (src.w != c.width or src.h != c.height) return rcode(.invalid_param);
    const m = newMask(s.alloc, c.width, c.height) catch return rcode(.out_of_memory);
    var i: usize = 0;
    while (i < src.sel.len) : (i += 1) {
        m.sel[i] = if (src.sel[i] != 0) 0 else 1;
    }
    out_mask.* = @intFromPtr(m);
    return rcode(.ok);
}

fn cpu_selection_cut(canvas: u64, layer: u64, mask: u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return rcode(.invalid_param);
    const l = c.layers.items[@intCast(layer - 1)];
    const m = liveMask(mask) orelse return rcode(.invalid_param);
    if (m.w != c.width or m.h != c.height) return rcode(.invalid_param);

    copyMaskedRegion(s, c, l, m) catch |e| return switch (e) {
        error.OutOfMemory => rcode(.out_of_memory),
        error.EmptySelection => rcode(.invalid_param),
    };

    // Clear the selected pixels (skip already-transparent ones so we don't
    // allocate tiles just to write zero).
    var y: u32 = 0;
    while (y < c.height) : (y += 1) {
        var x: u32 = 0;
        while (x < c.width) : (x += 1) {
            if (m.sel[@as(usize, y) * c.width + x] == 0) continue;
            const p = readPixelF32(l, x, y);
            if (p[0] != 0 or p[1] != 0 or p[2] != 0 or p[3] != 0) {
                writePixelF16(l, s.alloc, x, y, .{ 0, 0, 0, 0 }) catch return rcode(.out_of_memory);
            }
        }
    }
    return rcode(.ok);
}

fn cpu_selection_copy(canvas: u64, layer: u64, mask: u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return rcode(.invalid_param);
    const l = c.layers.items[@intCast(layer - 1)];
    const m = liveMask(mask) orelse return rcode(.invalid_param);
    if (m.w != c.width or m.h != c.height) return rcode(.invalid_param);

    copyMaskedRegion(s, c, l, m) catch |e| return switch (e) {
        error.OutOfMemory => rcode(.out_of_memory),
        error.EmptySelection => rcode(.invalid_param),
    };
    return rcode(.ok);
}

fn cpu_selection_paste(canvas: u64, layer: u64, dx: f64, dy: f64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return rcode(.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    if (layer == 0 or layer > c.layers.items.len) return rcode(.invalid_param);
    const l = c.layers.items[@intCast(layer - 1)];
    const cb = s.clipboard orelse return rcode(.invalid_param); // nothing copied yet
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return rcode(.invalid_param);

    const base_x: f64 = @round(@as(f64, @floatFromInt(cb.ox)) + dx);
    const base_y: f64 = @round(@as(f64, @floatFromInt(cb.oy)) + dy);
    var by: u32 = 0;
    while (by < cb.h) : (by += 1) {
        var bx: u32 = 0;
        while (bx < cb.w) : (bx += 1) {
            const bi: usize = @as(usize, by) * cb.w + bx;
            if (cb.has[bi] == 0) continue;
            const tx = finiteFloorU32(base_x + @as(f64, @floatFromInt(bx)), c.width) orelse continue;
            const ty = finiteFloorU32(base_y + @as(f64, @floatFromInt(by)), c.height) orelse continue;
            writePixelF16(l, s.alloc, tx, ty, cb.px[bi]) catch return rcode(.out_of_memory);
        }
    }
    return rcode(.ok);
}

fn cpu_shape_line(_c: u64, _l: u64, _ax: f64, _ay: f64, _bx: f64, _by: f64, _w: f64, _col: *const [4]f32, _aa: u32) callconv(.c) u32 {
    _ = _c;
    _ = _l;
    _ = _ax;
    _ = _ay;
    _ = _bx;
    _ = _by;
    _ = _w;
    _ = _col;
    _ = _aa;
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

fn cpu_shape_rectangle(_c: u64, _l: u64, _ax: f64, _ay: f64, _bx: f64, _by: f64, _sw: f64, _sc: *const [4]f32, _fc: *const [4]f32, _hs: u32, _hf: u32, _aa: u32) callconv(.c) u32 {
    _ = _c;
    _ = _l;
    _ = _ax;
    _ = _ay;
    _ = _bx;
    _ = _by;
    _ = _sw;
    _ = _sc;
    _ = _fc;
    _ = _hs;
    _ = _hf;
    _ = _aa;
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

fn cpu_shape_ellipse(_c: u64, _l: u64, _cx: f64, _cy: f64, _rx: f64, _ry: f64, _sw: f64, _sc: *const [4]f32, _fc: *const [4]f32, _hs: u32, _hf: u32, _aa: u32) callconv(.c) u32 {
    _ = _c;
    _ = _l;
    _ = _cx;
    _ = _cy;
    _ = _rx;
    _ = _ry;
    _ = _sw;
    _ = _sc;
    _ = _fc;
    _ = _hs;
    _ = _hf;
    _ = _aa;
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

fn cpu_shape_polygon(_c: u64, _l: u64, _n: u32, _v: [*]const f64, _sw: f64, _sc: *const [4]f32, _fc: *const [4]f32, _hs: u32, _hf: u32, _aa: u32) callconv(.c) u32 {
    _ = _c;
    _ = _l;
    _ = _n;
    _ = _v;
    _ = _sw;
    _ = _sc;
    _ = _fc;
    _ = _hs;
    _ = _hf;
    _ = _aa;
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

fn cpu_text_rasterise(_c: u64, _l: u64, _ox: f64, _oy: f64, _t: [*:0]const u8, _fam: [*:0]const u8, _s: f64, _w: u32, _i: u32, _col: *const [4]f32) callconv(.c) u32 {
    _ = _c;
    _ = _l;
    _ = _ox;
    _ = _oy;
    _ = _t;
    _ = _fam;
    _ = _s;
    _ = _w;
    _ = _i;
    _ = _col;
    return @intFromEnum(dispatcher.ResultCode.not_implemented);
}

fn cpu_history_record(canvas: u64, opcode: [*:0]const u8, _n: u32, _p: [*]const u8, _rc: u64) callconv(.c) u32 {
    _ = _n;
    _ = _p;
    _ = _rc;
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    ensureHistoryInit(s.alloc, c) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);

    // Capture the post-op state.
    var snap = snapshotCanvas(s.alloc, c) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    errdefer snap.deinit(s.alloc);
    const cost = snapshotByteCost(&snap);

    // New node hangs as a child of `current`.
    const node = s.alloc.create(HistoryNode) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    const name = s.alloc.dupe(u8, std.mem.span(opcode)) catch {
        s.alloc.destroy(node);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    node.* = .{
        .id = c.history.next_id,
        .parent = c.history.current,
        .op_name = name,
        .cost_bytes = cost,
        .snapshot = snap,
    };
    c.history.next_id += 1;
    c.history.nodes.put(s.alloc, node.id, node) catch {
        node.deinit(s.alloc);
        s.alloc.destroy(node);
        return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    };
    // Wire as a child of parent.
    if (c.history.nodes.get(c.history.current)) |parent| {
        parent.children.append(s.alloc, node.id) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    }
    c.history.current = node.id;
    c.history.used_bytes = saturatingAdd(c.history.used_bytes, cost);
    pruneHistory(s.alloc, c);
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_history_undo(canvas: u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    ensureHistoryInit(s.alloc, c) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);

    const cur = c.history.nodes.get(c.history.current) orelse return @intFromEnum(dispatcher.ResultCode.err);
    const parent_id = cur.parent orelse return @intFromEnum(dispatcher.ResultCode.ok); // at root — nothing to undo
    const parent = c.history.nodes.get(parent_id) orelse return @intFromEnum(dispatcher.ResultCode.err);

    restoreCanvas(s.alloc, c, &parent.snapshot) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    c.history.current = parent_id;
    return @intFromEnum(dispatcher.ResultCode.ok);
}

fn cpu_history_redo(canvas: u64) callconv(.c) u32 {
    const s = requireState();
    const c = s.get(canvas) orelse return @intFromEnum(dispatcher.ResultCode.invalid_param);
    c.lock.lock();
    defer c.lock.unlock();
    ensureHistoryInit(s.alloc, c) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);

    const cur = c.history.nodes.get(c.history.current) orelse return @intFromEnum(dispatcher.ResultCode.err);
    if (cur.children.items.len == 0) return @intFromEnum(dispatcher.ResultCode.ok); // nothing to redo
    // Pick the most-recently-added child — this preserves "redo continues
    // the branch you last extended" semantics. Branch picking among multiple
    // futures is a v0.3.0 UI concern.
    const child_id = cur.children.items[cur.children.items.len - 1];
    const child = c.history.nodes.get(child_id) orelse return @intFromEnum(dispatcher.ResultCode.err);

    restoreCanvas(s.alloc, c, &child.snapshot) catch return @intFromEnum(dispatcher.ResultCode.out_of_memory);
    c.history.current = child_id;
    return @intFromEnum(dispatcher.ResultCode.ok);
}

//==============================================================================
// 8. Capability table + registration
//==============================================================================

const ref_precs = [_]dispatcher.Precision{ .f16, .f32, .f64, .i8, .i16, .i32 };
const ref_caps = [_]dispatcher.CapabilityEntry{
    .{ .class = .math, .prec_count = ref_precs.len, .prec_ptr = &ref_precs, .memory_model = .unified_host, .device_idx = -1 },
    .{ .class = .io, .prec_count = ref_precs.len, .prec_ptr = &ref_precs, .memory_model = .unified_host, .device_idx = -1 },
};

const ref_id = dispatcher.BackendId{
    .vendor = "cpu",
    .name = "ref",
    .major = 0,
    .minor = 1,
};

const cpu_reference_impl = dispatcher.BackendImpl{
    .id = ref_id,
    .cap_count = ref_caps.len,
    .cap_ptr = &ref_caps,

    .canvas_new = cpu_canvas_new,
    .canvas_resize = cpu_canvas_resize,

    .io_open = cpu_io_open,
    .io_save = cpu_io_save,

    .tool_stroke_pencil = cpu_tool_stroke_pencil,
    .tool_stroke_brush = cpu_tool_stroke_brush,

    .tool_stroke_eraser = cpu_tool_stroke_eraser,

    .tool_sample_colour = cpu_tool_sample_colour,

    .tool_fill = cpu_tool_fill,

    .selection_rect = cpu_selection_rect,
    .selection_lasso = cpu_selection_lasso,
    .selection_invert = cpu_selection_invert,
    .selection_cut = cpu_selection_cut,
    .selection_copy = cpu_selection_copy,
    .selection_paste = cpu_selection_paste,

    .shape_line = cpu_shape_line,
    .shape_rectangle = cpu_shape_rectangle,
    .shape_ellipse = cpu_shape_ellipse,
    .shape_polygon = cpu_shape_polygon,

    .text_rasterise = cpu_text_rasterise,

    .history_record = cpu_history_record,
    .history_undo = cpu_history_undo,
    .history_redo = cpu_history_redo,

    .viewport_set = cpu_viewport_set,
    .viewport_fit = cpu_viewport_fit,

    .layer_new = cpu_layer_new,
    .layer_delete = cpu_layer_delete,
    .layer_reorder = cpu_layer_reorder,
    .layer_set_visible = cpu_layer_set_visible,
    .layer_set_opacity = cpu_layer_set_opacity,
    .layer_set_blend = cpu_layer_set_blend,

    .canvas_render_rgba8 = cpu_canvas_render_rgba8,
};

/// Called once at process start. Initialises internal state and registers
/// the reference backend with the dispatcher.
pub export fn pt_cpu_reference_register(allocator: ?*anyopaque) callconv(.c) u32 {
    _ = allocator; // dispatcher owns the allocator currently
    if (state == null) {
        state = .{ .alloc = std.heap.c_allocator };
    }
    dispatcher.register(&cpu_reference_impl) catch return @intFromEnum(dispatcher.ResultCode.err);
    return @intFromEnum(dispatcher.ResultCode.ok);
}

test "history budget pruning" {
    const alloc = std.testing.allocator;
    var canvas = Canvas{
        .width = 16,
        .height = 16,
        .format = 1,
        .background = .{ 0.0, 0.0, 0.0, 0.0 },
    };
    defer canvas.deinit(alloc);

    // Initialise history
    try ensureHistoryInit(alloc, &canvas);

    // Set a small budget (e.g. 300 bytes)
    canvas.history.budget_bytes = 300;

    // The root node (id 0) is already added in ensureHistoryInit.
    // Let's verify we have 1 node.
    try std.testing.expectEqual(@as(usize, 1), canvas.history.nodes.count());
    const initial_cost = canvas.history.used_bytes;
    try std.testing.expect(initial_cost > 0);

    // Create a new layer so subsequent snapshots have some cost
    const layer = try alloc.create(Layer);
    layer.* = .{
        .name = try alloc.dupe(u8, "layer1"),
        .visible = true,
        .opacity = 1.0,
        .blend = .normal,
        .tiles = .empty,
    };
    try canvas.layers.append(alloc, layer);

    // Record some history entries manually to avoid global state.
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var snap = try snapshotCanvas(alloc, &canvas);
        errdefer snap.deinit(alloc);
        const cost = snapshotByteCost(&snap);

        const node = try alloc.create(HistoryNode);
        const name = try alloc.dupe(u8, "dummy_op");
        node.* = .{
            .id = canvas.history.next_id,
            .parent = canvas.history.current,
            .op_name = name,
            .cost_bytes = cost,
            .snapshot = snap,
        };
        canvas.history.next_id += 1;
        try canvas.history.nodes.put(alloc, node.id, node);

        if (canvas.history.nodes.get(canvas.history.current)) |parent| {
            try parent.children.append(alloc, node.id);
        }
        canvas.history.current = node.id;
        canvas.history.used_bytes = saturatingAdd(canvas.history.used_bytes, cost);

        // Run pruner
        pruneHistory(alloc, &canvas);
    }

    // Since budget_bytes is 300, and each snapshot has a cost, some early nodes must have been pruned!
    try std.testing.expect(canvas.history.used_bytes <= canvas.history.budget_bytes or canvas.history.root == canvas.history.current);
    // Also verify that the root node is no longer 0 (since it was pruned).
    try std.testing.expect(canvas.history.root > 0);
    // Verify that the old root (0) is deleted from the map.
    try std.testing.expect(!canvas.history.nodes.contains(0));
}

test "concurrent history records" {
    const alloc = std.testing.allocator;
    var canvas = Canvas{
        .width = 16,
        .height = 16,
        .format = 1,
        .background = .{ 0.0, 0.0, 0.0, 0.0 },
    };
    defer canvas.deinit(alloc);

    try ensureHistoryInit(alloc, &canvas);

    const Context = struct {
        c: *Canvas,
        alloc: std.mem.Allocator,
    };
    const threadFn = struct {
        fn run(ctx: Context) void {
            var j: u32 = 0;
            while (j < 10) : (j += 1) {
                ctx.c.lock.lock();
                defer ctx.c.lock.unlock();
                const node = ctx.alloc.create(HistoryNode) catch return;
                const name = ctx.alloc.dupe(u8, "dummy_concurrent") catch {
                    ctx.alloc.destroy(node);
                    return;
                };
                var snap = snapshotCanvas(ctx.alloc, ctx.c) catch {
                    ctx.alloc.free(name);
                    ctx.alloc.destroy(node);
                    return;
                };
                const cost = snapshotByteCost(&snap);
                node.* = .{
                    .id = ctx.c.history.next_id,
                    .parent = ctx.c.history.current,
                    .op_name = name,
                    .cost_bytes = cost,
                    .snapshot = snap,
                };
                ctx.c.history.next_id += 1;
                ctx.c.history.nodes.put(ctx.alloc, node.id, node) catch {
                    node.deinit(ctx.alloc);
                    ctx.alloc.destroy(node);
                    return;
                };
                if (ctx.c.history.nodes.get(ctx.c.history.current)) |parent| {
                    parent.children.append(ctx.alloc, node.id) catch {};
                }
                ctx.c.history.current = node.id;
                ctx.c.history.used_bytes = saturatingAdd(ctx.c.history.used_bytes, cost);
                pruneHistory(ctx.alloc, ctx.c);
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, threadFn, .{Context{ .c = &canvas, .alloc = alloc }});
    }
    for (threads) |t| {
        t.join();
    }
}

//==============================================================================
// MVP-3 tool primitive tests (eraser / fill / selection)
//
// These drive the real C-ABI tool functions through the global backend state
// (initialised with the C allocator, so the intentionally-unfreed selection
// masks/clipboard do not trip the test leak detector) and assert the
// gesture -> tile-mutation round-trip.
//==============================================================================

fn testNewCanvas(w: u32, h: u32) u64 {
    if (state == null) state = .{ .alloc = std.heap.c_allocator };
    var handle: u64 = 0;
    std.debug.assert(cpu_canvas_new(w, h, 0, 0, 0, 0, 0, &handle) == rcode(.ok));
    return handle;
}

test "colourWithin: Chebyshev tolerance" {
    try std.testing.expect(colourWithin(.{ 0.5, 0.5, 0.5, 1 }, .{ 0.5, 0.5, 0.5, 1 }, 0.0));
    try std.testing.expect(colourWithin(.{ 0.5, 0.5, 0.5, 1 }, .{ 0.55, 0.5, 0.5, 1 }, 0.1));
    try std.testing.expect(!colourWithin(.{ 0.5, 0.5, 0.5, 1 }, .{ 0.7, 0.5, 0.5, 1 }, 0.1));
}

test "pointInPoly: square containment" {
    const sq = [_]f64{ 0, 0, 10, 0, 10, 10, 0, 10 };
    try std.testing.expect(pointInPoly(5, 5, &sq, 4));
    try std.testing.expect(!pointInPoly(15, 5, &sq, 4));
    try std.testing.expect(!pointInPoly(-1, 5, &sq, 4));
    try std.testing.expect(!pointInPoly(5, 11, &sq, 4));
}

test "eraser lowers destination alpha and preserves rgb" {
    const canvas = testNewCanvas(64, 64);
    const c = requireState().get(canvas).?;
    const l = c.layers.items[0];
    try writePixelF16(l, requireState().alloc, 10, 10, .{ 0.25, 0.5, 0.75, 1.0 });

    const bs = dispatcher.BrushStateC{ .radius = 4, .hardness = 1, .opacity = 1, .spacing = 0.25, .profile = 0 };
    const pts = [_]dispatcher.StrokePointC{.{ .x = 10, .y = 10, .pressure = 1, .tilt_x = 0, .tilt_y = 0 }};
    try std.testing.expectEqual(rcode(.ok), cpu_tool_stroke_eraser(canvas, 1, &bs, 1, &pts, pts.len, 0));

    const p = readPixelF32(l, 10, 10);
    try std.testing.expect(p[3] < 0.01); // alpha erased at the hard centre
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), p[0], 0.01); // rgb preserved
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), p[2], 0.01);

    // Unknown erase mode is rejected loudly.
    try std.testing.expectEqual(rcode(.invalid_param), cpu_tool_stroke_eraser(canvas, 1, &bs, 1, &pts, pts.len, 9));
}

test "fill flood fills a uniform layer (contiguous)" {
    const canvas = testNewCanvas(8, 8);
    const c = requireState().get(canvas).?;
    const l = c.layers.items[0];
    const red = [4]f32{ 1, 0, 0, 1 };
    try std.testing.expectEqual(rcode(.ok), cpu_tool_fill(canvas, 1, 0, 0, &red, 0.0, 1));
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        var x: u32 = 0;
        while (x < 8) : (x += 1) {
            const p = readPixelF32(l, x, y);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), p[0], 0.01);
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), p[3], 0.01);
        }
    }
}

test "fill (contiguous) stops at a colour boundary" {
    const canvas = testNewCanvas(8, 8);
    const c = requireState().get(canvas).?;
    const l = c.layers.items[0];
    const alloc = requireState().alloc;
    // Full-height blue wall at x = 4 separates left from right.
    var yy: u32 = 0;
    while (yy < 8) : (yy += 1) try writePixelF16(l, alloc, 4, yy, .{ 0, 0, 1, 1 });
    const green = [4]f32{ 0, 1, 0, 1 };
    try std.testing.expectEqual(rcode(.ok), cpu_tool_fill(canvas, 1, 0, 0, &green, 0.0, 1));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), readPixelF32(l, 0, 0)[1], 0.01); // filled green
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), readPixelF32(l, 3, 5)[1], 0.01); // filled green
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), readPixelF32(l, 4, 5)[2], 0.01); // wall intact (blue)
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), readPixelF32(l, 5, 5)[3], 0.01); // right side untouched
}

test "selection rect -> cut -> paste round-trips" {
    const canvas = testNewCanvas(16, 16);
    const c = requireState().get(canvas).?;
    const l = c.layers.items[0];
    try writePixelF16(l, requireState().alloc, 2, 2, .{ 1, 0, 0, 1 }); // red marker

    var mask: u64 = 0;
    try std.testing.expectEqual(rcode(.ok), cpu_selection_rect(canvas, 0, 0, 8, 8, &mask));
    try std.testing.expect(mask != 0);

    // Cut: copy the [0,8)x[0,8) region to the clipboard and clear it.
    try std.testing.expectEqual(rcode(.ok), cpu_selection_cut(canvas, 1, mask));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), readPixelF32(l, 2, 2)[3], 0.001);

    // Paste at the original origin restores the marker exactly.
    try std.testing.expectEqual(rcode(.ok), cpu_selection_paste(canvas, 1, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), readPixelF32(l, 2, 2)[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), readPixelF32(l, 2, 2)[3], 0.001);

    // Paste shifted by (5,5): the marker reappears at (7,7).
    try std.testing.expectEqual(rcode(.ok), cpu_selection_paste(canvas, 1, 5, 5));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), readPixelF32(l, 7, 7)[0], 0.001);

    // Invert yields a fresh, distinct complementary mask handle.
    var inv: u64 = 0;
    try std.testing.expectEqual(rcode(.ok), cpu_selection_invert(canvas, mask, &inv));
    try std.testing.expect(inv != 0 and inv != mask);
}

test "selection lasso selects a triangle interior" {
    const canvas = testNewCanvas(16, 16);
    // Triangle (1,1)-(14,1)-(1,14): (3,3) inside, (12,12) outside.
    const poly = [_]f64{ 1, 1, 14, 1, 1, 14 };
    var mask: u64 = 0;
    try std.testing.expectEqual(rcode(.ok), cpu_selection_lasso(canvas, 3, &poly, &mask));
    const m = liveMask(mask).?;
    try std.testing.expect(m.sel[@as(usize, 3) * 16 + 3] != 0); // inside
    try std.testing.expect(m.sel[@as(usize, 12) * 16 + 12] == 0); // outside
    // Degenerate polygons are rejected.
    try std.testing.expectEqual(rcode(.invalid_param), cpu_selection_lasso(canvas, 2, &poly, &mask));
}
