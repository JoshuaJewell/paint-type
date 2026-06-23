// SPDX-License-Identifier: AGPL-3.0-or-later
//
// paint.type — brush demo (MVP-3).
//
// Paints three strokes with different brush settings on a white canvas:
//   1. hard red:   radius=20, hardness=1.0, opacity=1.0, spacing=0.1
//   2. soft green: radius=20, hardness=0.0, opacity=0.7, spacing=0.1
//   3. mid blue:   radius=15, hardness=0.5, opacity=0.5, spacing=0.05
//
// Strokes are generated as a curved polyline (sine wave) so we see how the
// spacing interpolation fills in the path between supplied stroke points.
//
// Save goes through pt_io_save → cpu_io_save → encodePngRgba8 (same path as
// composite_demo), so the same dispatcher pipeline is exercised end-to-end.

const std = @import("std");
const dispatcher = @import("dispatcher");
const cpu = @import("cpu");

const W: u32 = 384;
const H: u32 = 256;

fn paintCurve(
    canvas: u64,
    layer: u64,
    state: *const dispatcher.BrushStateC,
    colour: [4]f32,
    y_centre: f64,
) !void {
    // 12 stroke points across the canvas, forming a sine curve.
    var pts: [12]dispatcher.StrokePointC = undefined;
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / 11.0;
        pts[i] = .{
            .x = 32.0 + t * (@as(f64, W) - 64.0),
            .y = y_centre + std.math.sin(t * std.math.pi * 2.0) * 24.0,
            .pressure = 1.0,
            .tilt_x = 0.0,
            .tilt_y = 0.0,
        };
    }
    const rc = dispatcher.pt_tool_stroke_brush(canvas, layer, state, pts.len, &pts, pts.len, &colour);
    if (rc != @intFromEnum(dispatcher.ResultCode.ok)) return error.BrushFailed;
}

pub fn main() !void {
    try dispatcher.init(std.heap.c_allocator);
    defer dispatcher.deinit();
    const reg_rc = cpu.pt_cpu_reference_register(null);
    if (reg_rc != @intFromEnum(dispatcher.ResultCode.ok)) return error.RegisterFailed;
    std.debug.print("dispatcher + CPU reference ready\n", .{});

    var canvas: u64 = 0;
    if (dispatcher.pt_canvas_new(W, H, 0, 1.0, 1.0, 1.0, 1.0, &canvas) != @intFromEnum(dispatcher.ResultCode.ok)) return error.CanvasNewFailed;
    std.debug.print("canvas {d}x{d} created (id={d})\n", .{ W, H, canvas });

    // Use the default Background layer (id=1) for all three strokes.
    const layer: u64 = 1;

    // 1. Hard red — sharp-edged disk, full opacity.
    {
        const state = dispatcher.BrushStateC{ .radius = 20.0, .hardness = 1.0, .opacity = 1.0, .spacing = 0.1, .profile = 0 };
        try paintCurve(canvas, layer, &state, .{ 1.0, 0.0, 0.0, 1.0 }, 64.0);
        std.debug.print("stroke 1: hard red (r=20, h=1.0, o=1.0)\n", .{});
    }

    // 2. Soft green — full smooth falloff, partial opacity.
    {
        const state = dispatcher.BrushStateC{ .radius = 20.0, .hardness = 0.0, .opacity = 0.7, .spacing = 0.1, .profile = 1 };
        try paintCurve(canvas, layer, &state, .{ 0.0, 0.8, 0.0, 1.0 }, 128.0);
        std.debug.print("stroke 2: soft green (r=20, h=0.0, o=0.7)\n", .{});
    }

    // 3. Mid blue — half-hard centre, smooth edge, low opacity, dense spacing.
    {
        const state = dispatcher.BrushStateC{ .radius = 15.0, .hardness = 0.5, .opacity = 0.5, .spacing = 0.05, .profile = 1 };
        try paintCurve(canvas, layer, &state, .{ 0.0, 0.3, 1.0, 1.0 }, 192.0);
        std.debug.print("stroke 3: half-hard blue (r=15, h=0.5, o=0.5)\n", .{});
    }

    // Save.
    if (dispatcher.pt_io_save(canvas, "brush_demo.png", "png", "") != @intFromEnum(dispatcher.ResultCode.ok)) return error.SaveFailed;
    std.debug.print("wrote brush_demo.png via pt_io_save\n", .{});
}
