// SPDX-License-Identifier: AGPL-3.0-or-later
//
// paint.type — the dispatcher.
//
// The runtime that holds the registry of backends, picks the best one per
// operation, falls back to the reference backend on miss, and emits self-
// healing diagnostics.
//
// Governed by ADR-0002. The behaviour mirrors hyperpolymath/Axiom.jl's
// gpu_capability_report + detect_gpu + fallback dispatch pattern in
// `src/backends/gpu_hooks.jl`, generalised across every kernel class.
//
// This file is the entry point for every call from the AffineScript
// application and from the unified API surface. It is the only place a
// concrete backend is named.

const std = @import("std");
const builtin = @import("builtin");

//==============================================================================
// 1. C ABI mirror of Backends.Abstract (Idris2)
//
//    The exact layout of these structs is what Idris2's `BackendImpl` record
//    generates. Idris2 owns the schema; this file follows.
//==============================================================================

pub const KernelClass = enum(u32) {
    dsp = 0,
    fpga = 1,
    audio = 2,
    math = 3,
    gpu = 4,
    physics = 5,
    crypto = 6,
    io = 7,
    vector = 8,
    tensor = 9,
};

pub const Precision = enum(u32) {
    f16 = 0,
    bf16 = 1,
    f32 = 2,
    f64 = 3,
    i8 = 4,
    i16 = 5,
    i32 = 6,
    i64 = 7,
    f8_e5m2 = 8,
    f8_e4m3 = 9,
};

pub const MemoryModel = enum(u32) {
    unified_host = 0,
    unified_fabric = 1,
    discrete_device = 2,
    streaming_only = 3,
};

pub const ResultCode = enum(u32) {
    ok = 0,
    err = 1,
    not_implemented = 2,
    invalid_param = 3,
    busy = 4,
    out_of_memory = 5,
    unsupported_precision = 6,
};

pub const CapabilityEntry = extern struct {
    class: KernelClass,
    prec_count: u32,
    prec_ptr: [*]const Precision, // borrowed; lives as long as the backend
    memory_model: MemoryModel,
    device_idx: i32, // -1 == no specific device
};

pub const BackendId = extern struct {
    vendor: [*:0]const u8,
    name: [*:0]const u8,
    major: u32,
    minor: u32,
};

/// Vtable mirror of Backends.Abstract.BackendImpl.
///
/// Function pointers may be null when the backend does not implement the
/// corresponding operation. The dispatcher checks each pointer before calling
/// and falls back to the reference backend on null.
pub const BackendImpl = extern struct {
    id: BackendId,
    cap_count: u32,
    cap_ptr: [*]const CapabilityEntry,

    // MVP-1
    canvas_new: ?*const fn (width: u32, height: u32, fmt: u32, bg_r: f32, bg_g: f32, bg_b: f32, bg_a: f32, out_canvas: *u64) callconv(.c) u32,
    canvas_resize: ?*const fn (canvas: u64, w: u32, h: u32, anchor_x: f64, anchor_y: f64) callconv(.c) u32,

    // MVP-2
    io_open: ?*const fn (path: [*:0]const u8, fmt: ?[*:0]const u8, out_canvas: *u64) callconv(.c) u32,
    io_save: ?*const fn (canvas: u64, path: [*:0]const u8, fmt: [*:0]const u8, opts_json: [*:0]const u8) callconv(.c) u32,

    // MVP-3
    // `points_len` is the number of elements the `points` buffer actually
    // holds (f64 count for pencil's flat x/y pairs, StrokePointC count for
    // brush/eraser). It lets the backend reject a `point_count` larger than the
    // real allocation instead of reading out of bounds — see SECURITY.md.
    tool_stroke_pencil: ?*const fn (canvas: u64, layer: u64, point_count: u32, points: [*]const f64, points_len: usize, colour: *const [4]f32) callconv(.c) u32,
    tool_stroke_brush: ?*const fn (canvas: u64, layer: u64, brush_state: *const BrushStateC, point_count: u32, points: [*]const StrokePointC, points_len: usize, colour: *const [4]f32) callconv(.c) u32,

    // MVP-4
    tool_stroke_eraser: ?*const fn (canvas: u64, layer: u64, brush_state: *const BrushStateC, point_count: u32, points: [*]const StrokePointC, points_len: usize, mode: u32) callconv(.c) u32,

    // MVP-5
    tool_sample_colour: ?*const fn (canvas: u64, at_x: f64, at_y: f64, area_px: u32, out_colour: *[4]f32) callconv(.c) u32,

    // MVP-6
    tool_fill: ?*const fn (canvas: u64, layer: u64, seed_x: f64, seed_y: f64, colour: *const [4]f32, tolerance: f64, contiguous: u32) callconv(.c) u32,

    // MVP-7
    selection_rect: ?*const fn (canvas: u64, x0: u32, y0: u32, x1: u32, y1: u32, out_mask: *u64) callconv(.c) u32,
    selection_lasso: ?*const fn (canvas: u64, point_count: u32, points: [*]const f64, out_mask: *u64) callconv(.c) u32,
    selection_invert: ?*const fn (canvas: u64, mask: u64, out_mask: *u64) callconv(.c) u32,
    selection_cut: ?*const fn (canvas: u64, layer: u64, mask: u64) callconv(.c) u32,
    selection_copy: ?*const fn (canvas: u64, layer: u64, mask: u64) callconv(.c) u32,
    selection_paste: ?*const fn (canvas: u64, layer: u64, dst_x: f64, dst_y: f64) callconv(.c) u32,

    // MVP-8
    shape_line: ?*const fn (canvas: u64, layer: u64, ax: f64, ay: f64, bx: f64, by: f64, width: f64, colour: *const [4]f32, aa_mode: u32) callconv(.c) u32,
    shape_rectangle: ?*const fn (canvas: u64, layer: u64, ax: f64, ay: f64, bx: f64, by: f64, stroke_width: f64, stroke_colour: *const [4]f32, fill_colour: *const [4]f32, has_stroke: u32, has_fill: u32, aa_mode: u32) callconv(.c) u32,
    shape_ellipse: ?*const fn (canvas: u64, layer: u64, cx: f64, cy: f64, rx: f64, ry: f64, stroke_width: f64, stroke_colour: *const [4]f32, fill_colour: *const [4]f32, has_stroke: u32, has_fill: u32, aa_mode: u32) callconv(.c) u32,
    shape_polygon: ?*const fn (canvas: u64, layer: u64, vertex_count: u32, vertices: [*]const f64, stroke_width: f64, stroke_colour: *const [4]f32, fill_colour: *const [4]f32, has_stroke: u32, has_fill: u32, aa_mode: u32) callconv(.c) u32,

    // MVP-9
    text_rasterise: ?*const fn (canvas: u64, layer: u64, origin_x: f64, origin_y: f64, text: [*:0]const u8, family: [*:0]const u8, size_points: f64, weight: u32, italic: u32, colour: *const [4]f32) callconv(.c) u32,

    // MVP-10
    history_record: ?*const fn (canvas: u64, opcode: [*:0]const u8, payload_len: u32, payload: [*]const u8, redo_cost: u64) callconv(.c) u32,
    history_undo: ?*const fn (canvas: u64) callconv(.c) u32,
    history_redo: ?*const fn (canvas: u64) callconv(.c) u32,

    // MVP-11
    viewport_set: ?*const fn (canvas: u64, zoom: f64, pan_x: f64, pan_y: f64, rotation: f64) callconv(.c) u32,
    viewport_fit: ?*const fn (canvas: u64, out_zoom: *f64, out_pan_x: *f64, out_pan_y: *f64) callconv(.c) u32,

    // MVP-12
    layer_new: ?*const fn (canvas: u64, after_layer: u64, has_after: u32, name: [*:0]const u8, out_layer: *u64) callconv(.c) u32,
    layer_delete: ?*const fn (canvas: u64, layer: u64) callconv(.c) u32,
    layer_reorder: ?*const fn (canvas: u64, layer: u64, new_index: u32) callconv(.c) u32,
    layer_set_visible: ?*const fn (canvas: u64, layer: u64, visible: u32) callconv(.c) u32,
    layer_set_opacity: ?*const fn (canvas: u64, layer: u64, opacity: f64) callconv(.c) u32,
    layer_set_blend: ?*const fn (canvas: u64, layer: u64, mode: u32) callconv(.c) u32,

    // MVP-12 (render): composite the visible layer stack with blend modes
    // into a caller-provided RGBA8 buffer.
    canvas_render_rgba8: ?*const fn (canvas: u64, x: u32, y: u32, w: u32, h: u32, out_buf: [*]u8, out_buf_len: usize) callconv(.c) u32,
};

pub const BrushStateC = extern struct {
    radius: f64,
    hardness: f64,
    opacity: f64,
    spacing: f64,
    profile: u32, // 0 = hard, 1 = soft, 2 = custom
};

pub const StrokePointC = extern struct {
    x: f64,
    y: f64,
    pressure: f64,
    tilt_x: f64,
    tilt_y: f64,
};

//==============================================================================
// 2. Registry + selection + fallback
//==============================================================================

const Registry = struct {
    allocator: std.mem.Allocator,
    backends: std.ArrayListUnmanaged(*const BackendImpl) = .empty,
    reference_index: usize = 0, // CpuReferenceBackend slot
    fallback_count: std.StringHashMapUnmanaged(u64) = .empty,
    self_healing_enabled: bool = true,

    fn init(alloc: std.mem.Allocator) Registry {
        return .{ .allocator = alloc };
    }

    fn deinit(self: *Registry) void {
        self.backends.deinit(self.allocator);
        self.fallback_count.deinit(self.allocator);
    }

    fn register(self: *Registry, impl: *const BackendImpl) !void {
        try self.backends.append(self.allocator, impl);
        const id = impl.id;
        if (std.mem.eql(u8, std.mem.span(id.vendor), "cpu") and
            std.mem.eql(u8, std.mem.span(id.name), "ref"))
        {
            self.reference_index = self.backends.items.len - 1;
        }
    }

    fn reference(self: *const Registry) *const BackendImpl {
        return self.backends.items[self.reference_index];
    }

    fn recordFallback(self: *Registry, op_name: []const u8) void {
        const gop = self.fallback_count.getOrPut(self.allocator, op_name) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
};

const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *SpinLock) void {
        while (self.state.swap(1, .acquire) == 1) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

var global_registry_lock: SpinLock = .{};
var global_registry: ?Registry = null;

pub fn init(allocator: std.mem.Allocator) !void {
    global_registry_lock.lock();
    defer global_registry_lock.unlock();
    if (global_registry != null) return;
    global_registry = Registry.init(allocator);
}

pub fn deinit() void {
    global_registry_lock.lock();
    defer global_registry_lock.unlock();
    if (global_registry) |*r| {
        r.deinit();
        global_registry = null;
    }
}

pub fn register(impl: *const BackendImpl) !void {
    global_registry_lock.lock();
    defer global_registry_lock.unlock();
    if (global_registry == null) return error.RegistryNotInitialised;
    try global_registry.?.register(impl);
}

//==============================================================================
// 3. Per-operation dispatch
//
//    Each operation has a tiny helper that picks a backend that implements it
//    (i.e. its function pointer is non-null and it reports the required kernel
//    class), invokes it, and on `not_implemented` falls back to the reference.
//
//    A single shared `dispatchOp` template would be cleaner with Zig comptime
//    reflection on the BackendImpl struct; for now we keep one helper per
//    operation so the call-site code generation from Idris2 has a one-to-one
//    target.
//==============================================================================

fn pickFor(comptime field_name: []const u8) ?*const BackendImpl {
    global_registry_lock.lock();
    defer global_registry_lock.unlock();
    var r = &global_registry.?;
    // Forward sweep: pick the first non-reference backend that implements the op.
    // (Selection-priority policy is a follow-up; for the MVP, registration
    //  order suffices and the reference is the last-resort fallback.)
    var i: usize = 0;
    while (i < r.backends.items.len) : (i += 1) {
        if (i == r.reference_index) continue;
        const b = r.backends.items[i];
        if (@field(b, field_name) != null) return b;
    }
    // Fall through to reference.
    return r.reference();
}

fn invokeOrFallback(
    comptime field_name: []const u8,
    chosen: *const BackendImpl,
    args: anytype,
) ResultCode {
    const fp_opt = @field(chosen, field_name);
    if (fp_opt) |fp| {
        const rc: u32 = @call(.auto, fp, args);
        if (rc == @intFromEnum(ResultCode.not_implemented)) {
            global_registry_lock.lock();
            defer global_registry_lock.unlock();
            global_registry.?.recordFallback(field_name);
            const ref = global_registry.?.reference();
            const rfp = @field(ref, field_name).?;
            return @enumFromInt(@as(u32, @call(.auto, rfp, args)));
        }
        return @enumFromInt(rc);
    }
    // Should not happen — pickFor either returns the reference or a backend
    // whose field is non-null. Belt-and-braces.
    global_registry_lock.lock();
    defer global_registry_lock.unlock();
    global_registry.?.recordFallback(field_name);
    const ref = global_registry.?.reference();
    const rfp = @field(ref, field_name).?;
    return @enumFromInt(@as(u32, @call(.auto, rfp, args)));
}

//==============================================================================
// 4. Public dispatch entry points
//
//    These are exported with a stable C ABI. The AffineScript runtime and the
//    unified API server call into these. They never name a backend directly.
//==============================================================================

pub export fn pt_canvas_new(
    width: u32,
    height: u32,
    fmt: u32,
    bg_r: f32,
    bg_g: f32,
    bg_b: f32,
    bg_a: f32,
    out_canvas: *u64,
) callconv(.c) u32 {
    const chosen = pickFor("canvas_new").?;
    return @intFromEnum(invokeOrFallback("canvas_new", chosen, .{ width, height, fmt, bg_r, bg_g, bg_b, bg_a, out_canvas }));
}

pub export fn pt_canvas_resize(canvas: u64, w: u32, h: u32, ax: f64, ay: f64) callconv(.c) u32 {
    const chosen = pickFor("canvas_resize").?;
    return @intFromEnum(invokeOrFallback("canvas_resize", chosen, .{ canvas, w, h, ax, ay }));
}

pub export fn pt_io_open(path: [*:0]const u8, fmt: ?[*:0]const u8, out_canvas: *u64) callconv(.c) u32 {
    const chosen = pickFor("io_open").?;
    return @intFromEnum(invokeOrFallback("io_open", chosen, .{ path, fmt, out_canvas }));
}

pub export fn pt_io_save(canvas: u64, path: [*:0]const u8, fmt: [*:0]const u8, opts: [*:0]const u8) callconv(.c) u32 {
    const chosen = pickFor("io_save").?;
    return @intFromEnum(invokeOrFallback("io_save", chosen, .{ canvas, path, fmt, opts }));
}

pub export fn pt_tool_stroke_pencil(canvas: u64, layer: u64, n: u32, points: [*]const f64, points_len: usize, colour: *const [4]f32) callconv(.c) u32 {
    const chosen = pickFor("tool_stroke_pencil").?;
    return @intFromEnum(invokeOrFallback("tool_stroke_pencil", chosen, .{ canvas, layer, n, points, points_len, colour }));
}

pub export fn pt_tool_stroke_brush(canvas: u64, layer: u64, state: *const BrushStateC, n: u32, points: [*]const StrokePointC, points_len: usize, colour: *const [4]f32) callconv(.c) u32 {
    const chosen = pickFor("tool_stroke_brush").?;
    return @intFromEnum(invokeOrFallback("tool_stroke_brush", chosen, .{ canvas, layer, state, n, points, points_len, colour }));
}

pub export fn pt_tool_stroke_eraser(canvas: u64, layer: u64, state: *const BrushStateC, n: u32, points: [*]const StrokePointC, points_len: usize, mode: u32) callconv(.c) u32 {
    const chosen = pickFor("tool_stroke_eraser").?;
    return @intFromEnum(invokeOrFallback("tool_stroke_eraser", chosen, .{ canvas, layer, state, n, points, points_len, mode }));
}

pub export fn pt_tool_sample_colour(canvas: u64, x: f64, y: f64, area: u32, out_colour: *[4]f32) callconv(.c) u32 {
    const chosen = pickFor("tool_sample_colour").?;
    return @intFromEnum(invokeOrFallback("tool_sample_colour", chosen, .{ canvas, x, y, area, out_colour }));
}

pub export fn pt_tool_fill(canvas: u64, layer: u64, sx: f64, sy: f64, colour: *const [4]f32, tol: f64, contig: u32) callconv(.c) u32 {
    const chosen = pickFor("tool_fill").?;
    return @intFromEnum(invokeOrFallback("tool_fill", chosen, .{ canvas, layer, sx, sy, colour, tol, contig }));
}

pub export fn pt_selection_rect(canvas: u64, x0: u32, y0: u32, x1: u32, y1: u32, out_mask: *u64) callconv(.c) u32 {
    const chosen = pickFor("selection_rect").?;
    return @intFromEnum(invokeOrFallback("selection_rect", chosen, .{ canvas, x0, y0, x1, y1, out_mask }));
}

pub export fn pt_selection_lasso(canvas: u64, n: u32, pts: [*]const f64, out_mask: *u64) callconv(.c) u32 {
    const chosen = pickFor("selection_lasso").?;
    return @intFromEnum(invokeOrFallback("selection_lasso", chosen, .{ canvas, n, pts, out_mask }));
}

pub export fn pt_selection_invert(canvas: u64, mask: u64, out_mask: *u64) callconv(.c) u32 {
    const chosen = pickFor("selection_invert").?;
    return @intFromEnum(invokeOrFallback("selection_invert", chosen, .{ canvas, mask, out_mask }));
}

pub export fn pt_selection_cut(canvas: u64, layer: u64, mask: u64) callconv(.c) u32 {
    const chosen = pickFor("selection_cut").?;
    return @intFromEnum(invokeOrFallback("selection_cut", chosen, .{ canvas, layer, mask }));
}

pub export fn pt_selection_copy(canvas: u64, layer: u64, mask: u64) callconv(.c) u32 {
    const chosen = pickFor("selection_copy").?;
    return @intFromEnum(invokeOrFallback("selection_copy", chosen, .{ canvas, layer, mask }));
}

pub export fn pt_selection_paste(canvas: u64, layer: u64, dx: f64, dy: f64) callconv(.c) u32 {
    const chosen = pickFor("selection_paste").?;
    return @intFromEnum(invokeOrFallback("selection_paste", chosen, .{ canvas, layer, dx, dy }));
}

pub export fn pt_shape_line(canvas: u64, layer: u64, ax: f64, ay: f64, bx: f64, by: f64, w: f64, colour: *const [4]f32, aa: u32) callconv(.c) u32 {
    const chosen = pickFor("shape_line").?;
    return @intFromEnum(invokeOrFallback("shape_line", chosen, .{ canvas, layer, ax, ay, bx, by, w, colour, aa }));
}

pub export fn pt_shape_rectangle(canvas: u64, layer: u64, ax: f64, ay: f64, bx: f64, by: f64, sw: f64, sc: *const [4]f32, fc: *const [4]f32, has_stroke: u32, has_fill: u32, aa: u32) callconv(.c) u32 {
    const chosen = pickFor("shape_rectangle").?;
    return @intFromEnum(invokeOrFallback("shape_rectangle", chosen, .{ canvas, layer, ax, ay, bx, by, sw, sc, fc, has_stroke, has_fill, aa }));
}

pub export fn pt_shape_ellipse(canvas: u64, layer: u64, cx: f64, cy: f64, rx: f64, ry: f64, sw: f64, sc: *const [4]f32, fc: *const [4]f32, has_stroke: u32, has_fill: u32, aa: u32) callconv(.c) u32 {
    const chosen = pickFor("shape_ellipse").?;
    return @intFromEnum(invokeOrFallback("shape_ellipse", chosen, .{ canvas, layer, cx, cy, rx, ry, sw, sc, fc, has_stroke, has_fill, aa }));
}

pub export fn pt_shape_polygon(canvas: u64, layer: u64, n: u32, verts: [*]const f64, sw: f64, sc: *const [4]f32, fc: *const [4]f32, has_stroke: u32, has_fill: u32, aa: u32) callconv(.c) u32 {
    const chosen = pickFor("shape_polygon").?;
    return @intFromEnum(invokeOrFallback("shape_polygon", chosen, .{ canvas, layer, n, verts, sw, sc, fc, has_stroke, has_fill, aa }));
}

pub export fn pt_text_rasterise(canvas: u64, layer: u64, ox: f64, oy: f64, text: [*:0]const u8, family: [*:0]const u8, size_points: f64, weight: u32, italic: u32, colour: *const [4]f32) callconv(.c) u32 {
    const chosen = pickFor("text_rasterise").?;
    return @intFromEnum(invokeOrFallback("text_rasterise", chosen, .{ canvas, layer, ox, oy, text, family, size_points, weight, italic, colour }));
}

pub export fn pt_history_record(canvas: u64, opcode: [*:0]const u8, payload_len: u32, payload: [*]const u8, redo_cost: u64) callconv(.c) u32 {
    const chosen = pickFor("history_record").?;
    return @intFromEnum(invokeOrFallback("history_record", chosen, .{ canvas, opcode, payload_len, payload, redo_cost }));
}

pub export fn pt_history_undo(canvas: u64) callconv(.c) u32 {
    const chosen = pickFor("history_undo").?;
    return @intFromEnum(invokeOrFallback("history_undo", chosen, .{canvas}));
}

pub export fn pt_history_redo(canvas: u64) callconv(.c) u32 {
    const chosen = pickFor("history_redo").?;
    return @intFromEnum(invokeOrFallback("history_redo", chosen, .{canvas}));
}

pub export fn pt_viewport_set(canvas: u64, zoom: f64, px: f64, py: f64, rot: f64) callconv(.c) u32 {
    const chosen = pickFor("viewport_set").?;
    return @intFromEnum(invokeOrFallback("viewport_set", chosen, .{ canvas, zoom, px, py, rot }));
}

pub export fn pt_viewport_fit(canvas: u64, oz: *f64, opx: *f64, opy: *f64) callconv(.c) u32 {
    const chosen = pickFor("viewport_fit").?;
    return @intFromEnum(invokeOrFallback("viewport_fit", chosen, .{ canvas, oz, opx, opy }));
}

pub export fn pt_layer_new(canvas: u64, after: u64, has_after: u32, name: [*:0]const u8, out_layer: *u64) callconv(.c) u32 {
    const chosen = pickFor("layer_new").?;
    return @intFromEnum(invokeOrFallback("layer_new", chosen, .{ canvas, after, has_after, name, out_layer }));
}

pub export fn pt_layer_delete(canvas: u64, layer: u64) callconv(.c) u32 {
    const chosen = pickFor("layer_delete").?;
    return @intFromEnum(invokeOrFallback("layer_delete", chosen, .{ canvas, layer }));
}

pub export fn pt_layer_reorder(canvas: u64, layer: u64, new_index: u32) callconv(.c) u32 {
    const chosen = pickFor("layer_reorder").?;
    return @intFromEnum(invokeOrFallback("layer_reorder", chosen, .{ canvas, layer, new_index }));
}

pub export fn pt_layer_set_visible(canvas: u64, layer: u64, visible: u32) callconv(.c) u32 {
    const chosen = pickFor("layer_set_visible").?;
    return @intFromEnum(invokeOrFallback("layer_set_visible", chosen, .{ canvas, layer, visible }));
}

pub export fn pt_layer_set_opacity(canvas: u64, layer: u64, opacity: f64) callconv(.c) u32 {
    const chosen = pickFor("layer_set_opacity").?;
    return @intFromEnum(invokeOrFallback("layer_set_opacity", chosen, .{ canvas, layer, opacity }));
}

pub export fn pt_layer_set_blend(canvas: u64, layer: u64, mode: u32) callconv(.c) u32 {
    const chosen = pickFor("layer_set_blend").?;
    return @intFromEnum(invokeOrFallback("layer_set_blend", chosen, .{ canvas, layer, mode }));
}

pub export fn pt_canvas_render_rgba8(canvas: u64, x: u32, y: u32, w: u32, h: u32, out_buf: [*]u8, out_buf_len: usize) callconv(.c) u32 {
    const chosen = pickFor("canvas_render_rgba8").?;
    return @intFromEnum(invokeOrFallback("canvas_render_rgba8", chosen, .{ canvas, x, y, w, h, out_buf, out_buf_len }));
}

//==============================================================================
// 5. Capability report (Axiom.jl analogue: gpu_capability_report)
//==============================================================================

/// Emit a structured capability report as JSON to the caller-provided buffer.
/// Returns the number of bytes written, or 0 on overflow.
pub export fn pt_capability_report(out_buf: [*]u8, out_cap: usize) callconv(.c) usize {
    global_registry_lock.lock();
    defer global_registry_lock.unlock();
    if (global_registry == null) return 0;
    var pos: usize = 0;
    const buf = out_buf[0..out_cap];

    const header = std.fmt.bufPrint(buf[pos..], "{{\"selfHealing\":{},\"backends\":[", .{global_registry.?.self_healing_enabled}) catch return 0;
    pos += header.len;

    var first = true;
    for (global_registry.?.backends.items) |b| {
        if (!first) {
            if (pos >= out_cap) return 0;
            buf[pos] = ',';
            pos += 1;
        }
        first = false;
        const entry = std.fmt.bufPrint(buf[pos..], "{{\"vendor\":\"{s}\",\"name\":\"{s}\",\"major\":{},\"minor\":{}}}", .{
            std.mem.span(b.id.vendor),
            std.mem.span(b.id.name),
            b.id.major,
            b.id.minor,
        }) catch return 0;
        pos += entry.len;
    }

    if (pos + 2 > out_cap) return 0;
    buf[pos] = ']';
    buf[pos + 1] = '}';
    return pos + 2;
}
