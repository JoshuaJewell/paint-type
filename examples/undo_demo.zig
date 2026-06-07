// SPDX-License-Identifier: AGPL-3.0-or-later
//
// paint.type — undo / redo demo (MVP-10).
//
// Sequence:
//   t0  blank canvas               → undo_t0_blank.png
//   t1  paint a red curve
//        record("stroke.brush 1")  → undo_t1_red.png
//   t2  paint a green curve
//        record("stroke.brush 2")  → undo_t2_red+green.png
//   t3  undo                       → undo_t3_after_undo.png   (back to t1)
//   t4  undo                       → undo_t4_after_2x_undo.png (back to t0)
//   t5  redo                       → undo_t5_after_redo.png   (forward to t1)
//
// The four expected-pairs:
//   t1 PNG  ==  t3 PNG  ==  t5 PNG   (state-after-red-stroke)
//   t0 PNG  ==  t4 PNG               (initial blank)
//
// The demo verifies they match byte-for-byte using std.mem.eql on the saved
// PNG bytes — that's a real round-trip check on the undo graph.

const std = @import("std");
const dispatcher = @import("dispatcher");
const cpu = @import("cpu");

const W: u32 = 256;
const H: u32 = 192;

fn paintCurve(canvas: u64, layer: u64, state: *const dispatcher.BrushStateC, colour: [4]f32, y_centre: f64) !void {
    var pts: [12]dispatcher.StrokePointC = undefined;
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / 11.0;
        pts[i] = .{
            .x = 24.0 + t * (@as(f64, W) - 48.0),
            .y = y_centre + std.math.sin(t * std.math.pi * 2.0) * 16.0,
            .pressure = 1.0,
            .tilt_x = 0.0,
            .tilt_y = 0.0,
        };
    }
    const rc = dispatcher.pt_tool_stroke_brush(canvas, layer, state, pts.len, &pts, &colour);
    if (rc != @intFromEnum(dispatcher.ResultCode.ok)) return error.BrushFailed;
}

fn savePng(canvas: u64, path: [*:0]const u8) !void {
    const rc = dispatcher.pt_io_save(canvas, path, "png", "");
    if (rc != @intFromEnum(dispatcher.ResultCode.ok)) return error.SaveFailed;
}

fn readAll(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const Cstdio = struct {
        extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
        extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
        extern "c" fn ftell(stream: *anyopaque) c_long;
        extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
        extern "c" fn fclose(stream: *anyopaque) c_int;
    };
    var cpath_buf: [256]u8 = undefined;
    if (path.len + 1 > cpath_buf.len) return error.PathTooLong;
    @memcpy(cpath_buf[0..path.len], path);
    cpath_buf[path.len] = 0;
    const cpath: [*:0]const u8 = @ptrCast(&cpath_buf[0]);
    const fh = Cstdio.fopen(cpath, "rb") orelse return error.OpenFailed;
    defer _ = Cstdio.fclose(fh);
    _ = Cstdio.fseek(fh, 0, 2);
    const sz: c_long = Cstdio.ftell(fh);
    if (sz < 0) return error.SeekFailed;
    _ = Cstdio.fseek(fh, 0, 0);
    const buf = try alloc.alloc(u8, @intCast(sz));
    _ = Cstdio.fread(buf.ptr, 1, buf.len, fh);
    return buf;
}

pub fn main() !void {
    try dispatcher.init(std.heap.c_allocator);
    defer dispatcher.deinit();
    _ = cpu.pt_cpu_reference_register(null);

    var canvas: u64 = 0;
    if (dispatcher.pt_canvas_new(W, H, 0, 1.0, 1.0, 1.0, 1.0, &canvas) != @intFromEnum(dispatcher.ResultCode.ok)) return error.CanvasNewFailed;

    const layer: u64 = 1;
    const red_state = dispatcher.BrushStateC{ .radius = 14.0, .hardness = 0.7, .opacity = 1.0, .spacing = 0.1, .profile = 1 };
    const green_state = dispatcher.BrushStateC{ .radius = 14.0, .hardness = 0.7, .opacity = 1.0, .spacing = 0.1, .profile = 1 };

    // t0 — initial blank state.
    try savePng(canvas, "undo_t0_blank.png");
    std.debug.print("t0 blank        -> undo_t0_blank.png\n", .{});

    // t1 — paint red, record.
    try paintCurve(canvas, layer, &red_state, .{ 1.0, 0.0, 0.0, 1.0 }, 64.0);
    _ = dispatcher.pt_history_record(canvas, "stroke.brush 1 (red)", 0, &[_]u8{}, 0);
    try savePng(canvas, "undo_t1_red.png");
    std.debug.print("t1 red+record   -> undo_t1_red.png\n", .{});

    // t2 — paint green, record.
    try paintCurve(canvas, layer, &green_state, .{ 0.0, 0.7, 0.0, 1.0 }, 128.0);
    _ = dispatcher.pt_history_record(canvas, "stroke.brush 2 (green)", 0, &[_]u8{}, 0);
    try savePng(canvas, "undo_t2_red_green.png");
    std.debug.print("t2 green+record -> undo_t2_red_green.png\n", .{});

    // t3 — undo once.
    _ = dispatcher.pt_history_undo(canvas);
    try savePng(canvas, "undo_t3_after_undo.png");
    std.debug.print("t3 after undo   -> undo_t3_after_undo.png\n", .{});

    // t4 — undo again (back to t0).
    _ = dispatcher.pt_history_undo(canvas);
    try savePng(canvas, "undo_t4_after_2x_undo.png");
    std.debug.print("t4 after 2xundo -> undo_t4_after_2x_undo.png\n", .{});

    // t5 — redo (forward to t1).
    _ = dispatcher.pt_history_redo(canvas);
    try savePng(canvas, "undo_t5_after_redo.png");
    std.debug.print("t5 after redo   -> undo_t5_after_redo.png\n", .{});

    // Verify equivalences via PNG byte equality.
    const alloc = std.heap.c_allocator;
    const t0 = try readAll(alloc, "undo_t0_blank.png");
    defer alloc.free(t0);
    const t1 = try readAll(alloc, "undo_t1_red.png");
    defer alloc.free(t1);
    const t3 = try readAll(alloc, "undo_t3_after_undo.png");
    defer alloc.free(t3);
    const t4 = try readAll(alloc, "undo_t4_after_2x_undo.png");
    defer alloc.free(t4);
    const t5 = try readAll(alloc, "undo_t5_after_redo.png");
    defer alloc.free(t5);

    std.debug.print("\nbyte-equality checks:\n", .{});
    std.debug.print("  t1 == t3 (undo restored t1)?    {s}\n", .{if (std.mem.eql(u8, t1, t3)) "PASS" else "FAIL"});
    std.debug.print("  t1 == t5 (redo returned to t1)? {s}\n", .{if (std.mem.eql(u8, t1, t5)) "PASS" else "FAIL"});
    std.debug.print("  t0 == t4 (2xundo back to root)? {s}\n", .{if (std.mem.eql(u8, t0, t4)) "PASS" else "FAIL"});
}
