// SPDX-License-Identifier: AGPL-3.0-or-later
//
// paint.type — compositing demo.
//
// Exercises the unified backend pattern end-to-end:
//   1. initialises the dispatcher and registers the CPU reference backend
//   2. creates a 256x256 canvas with a white background
//   3. adds three layers: red (Normal), green (Multiply 0.7), blue (Screen 0.7)
//   4. fills each layer with a 100x100 rectangle using the pencil operation
//      (which writes one pixel per stroke point — the MVP-3 stub)
//   5. composites the layer stack via canvas_render_rgba8
//   6. writes the result to composite_demo.ppm (P6 binary PPM, viewable in
//      most image viewers including IrfanView, ImageMagick, GIMP, mtPaint)
//   7. prints a few sample pixels and a tiny ASCII preview to stdout
//
// Build + run:
//   zig build demo
//   ./zig-out/bin/composite_demo

const std = @import("std");
const dispatcher = @import("dispatcher");
const cpu = @import("cpu");

const W: u32 = 256;
const H: u32 = 256;

/// Draws a filled rectangle on a given layer by feeding the pencil operation
/// one stroke point per pixel. This is intentionally inefficient — a future
/// MVP-8 (shape_rectangle) replaces it with a real raster — but it exercises
/// the full pencil → tile → composite path today.
fn fillRect(canvas: u64, layer: u64, x0: u32, y0: u32, x1: u32, y1: u32, colour: [4]f32) !void {
    const count: usize = @as(usize, x1 - x0) * @as(usize, y1 - y0);
    const buf = try std.heap.c_allocator.alloc(f64, count * 2);
    defer std.heap.c_allocator.free(buf);
    var i: usize = 0;
    var y: u32 = y0;
    while (y < y1) : (y += 1) {
        var x: u32 = x0;
        while (x < x1) : (x += 1) {
            buf[i * 2 + 0] = @floatFromInt(x);
            buf[i * 2 + 1] = @floatFromInt(y);
            i += 1;
        }
    }
    const rc = dispatcher.pt_tool_stroke_pencil(canvas, layer, @intCast(count), buf.ptr, buf.len, &colour);
    if (rc != @intFromEnum(dispatcher.ResultCode.ok)) return error.PencilFailed;
}

pub fn main() !void {
    // 1. Initialise the dispatcher + register the CPU reference backend.
    try dispatcher.init(std.heap.c_allocator);
    defer dispatcher.deinit();
    const reg_rc = cpu.pt_cpu_reference_register(null);
    if (reg_rc != @intFromEnum(dispatcher.ResultCode.ok)) return error.RegisterFailed;
    std.debug.print("dispatcher initialised; CPU reference backend registered\n", .{});

    // 2. Create a 256x256 canvas with white background.
    var canvas: u64 = 0;
    {
        const rc = dispatcher.pt_canvas_new(W, H, 0, 1.0, 1.0, 1.0, 1.0, &canvas);
        if (rc != @intFromEnum(dispatcher.ResultCode.ok)) return error.CanvasNewFailed;
    }
    std.debug.print("canvas {d} created: {d}x{d}, white background\n", .{ canvas, W, H });

    // The canvas comes with a default "Background" layer at index 1.
    // 3a. Add red layer (Normal) — id 2.
    var red_layer: u64 = 0;
    _ = dispatcher.pt_layer_new(canvas, 0, 0, "Red Normal", &red_layer);
    _ = dispatcher.pt_layer_set_blend(canvas, red_layer, cpu_blend_normal);

    // 3b. Add green layer (Multiply, opacity 0.7) — id 3.
    var green_layer: u64 = 0;
    _ = dispatcher.pt_layer_new(canvas, 0, 0, "Green Multiply", &green_layer);
    _ = dispatcher.pt_layer_set_blend(canvas, green_layer, cpu_blend_multiply);
    _ = dispatcher.pt_layer_set_opacity(canvas, green_layer, 0.7);

    // 3c. Add blue layer (Screen, opacity 0.7) — id 4.
    var blue_layer: u64 = 0;
    _ = dispatcher.pt_layer_new(canvas, 0, 0, "Blue Screen", &blue_layer);
    _ = dispatcher.pt_layer_set_blend(canvas, blue_layer, cpu_blend_screen);
    _ = dispatcher.pt_layer_set_opacity(canvas, blue_layer, 0.7);

    std.debug.print("layers: {{Background, Red(Normal), Green(Multiply 0.7), Blue(Screen 0.7)}}\n", .{});

    // 4. Fill rectangles on each non-background layer.
    //    Red: top-left.  Green: centre.  Blue: bottom-right. Overlaps reveal blend modes.
    try fillRect(canvas, red_layer, 30, 30, 130, 130, .{ 1.0, 0.0, 0.0, 1.0 });
    try fillRect(canvas, green_layer, 80, 80, 180, 180, .{ 0.0, 1.0, 0.0, 1.0 });
    try fillRect(canvas, blue_layer, 130, 130, 230, 230, .{ 0.0, 0.0, 1.0, 1.0 });
    std.debug.print("three 100x100 rectangles drawn (red TL, green centre, blue BR)\n", .{});

    // 5. Composite the layer stack.
    const out_buf = try std.heap.c_allocator.alloc(u8, @as(usize, W) * @as(usize, H) * 4);
    defer std.heap.c_allocator.free(out_buf);
    {
        const rc = dispatcher.pt_canvas_render_rgba8(canvas, 0, 0, W, H, out_buf.ptr, out_buf.len);
        if (rc != @intFromEnum(dispatcher.ResultCode.ok)) {
            std.debug.print("render rc = {d}\n", .{rc});
            return error.RenderFailed;
        }
    }
    std.debug.print("composited {d} pixels via canvas_render_rgba8\n", .{out_buf.len / 4});

    // 6. Save through the dispatcher → CpuReferenceBackend → PNG encoder.
    //    This is MVP-2 in action: io_save goes through the abstract surface
    //    just like every other operation. Same call, swap "png" for "ppm".
    {
        const rc = dispatcher.pt_io_save(canvas, "composite_demo.png", "png", "");
        if (rc != @intFromEnum(dispatcher.ResultCode.ok)) {
            std.debug.print("pt_io_save (png) rc = {d}\n", .{rc});
            return error.SaveFailed;
        }
    }
    {
        const rc = dispatcher.pt_io_save(canvas, "composite_demo.ppm", "ppm", "");
        if (rc != @intFromEnum(dispatcher.ResultCode.ok)) {
            std.debug.print("pt_io_save (ppm) rc = {d}\n", .{rc});
            return error.SaveFailed;
        }
    }
    std.debug.print("wrote composite_demo.png + composite_demo.ppm via pt_io_save\n", .{});

    // 7. Sample pixels at known overlap points + a tiny ASCII preview.
    const samples = [_]struct { name: []const u8, x: u32, y: u32 }{
        .{ .name = "background       ", .x = 10, .y = 10 },
        .{ .name = "red only         ", .x = 50, .y = 50 },
        .{ .name = "red+green (mult) ", .x = 100, .y = 100 },
        .{ .name = "green only       ", .x = 100, .y = 150 },
        .{ .name = "green+blue (scr) ", .x = 150, .y = 150 },
        .{ .name = "blue only        ", .x = 200, .y = 200 },
    };
    std.debug.print("\nsample pixels (RGBA):\n", .{});
    for (samples) |s| {
        const idx: usize = (@as(usize, s.y) * @as(usize, W) + @as(usize, s.x)) * 4;
        std.debug.print("  ({d:>3},{d:>3}) {s} -> ({d:>3}, {d:>3}, {d:>3}, {d:>3})\n", .{
            s.x, s.y, s.name, out_buf[idx], out_buf[idx + 1], out_buf[idx + 2], out_buf[idx + 3],
        });
    }

    std.debug.print("\nASCII preview (downsampled 32x16, brightness->char):\n", .{});
    const charset = " .:-=+*#%@";
    const cw: u32 = 32;
    const ch: u32 = 16;
    var py: u32 = 0;
    while (py < ch) : (py += 1) {
        var px: u32 = 0;
        while (px < cw) : (px += 1) {
            const sx: u32 = px * W / cw;
            const sy: u32 = py * H / ch;
            const sidx: usize = (@as(usize, sy) * @as(usize, W) + @as(usize, sx)) * 4;
            const lum: u32 = (@as(u32, out_buf[sidx]) + @as(u32, out_buf[sidx + 1]) + @as(u32, out_buf[sidx + 2])) / 3;
            const ci: usize = @intCast((lum * (charset.len - 1)) / 255);
            std.debug.print("{c}", .{charset[ci]});
        }
        std.debug.print("\n", .{});
    }
}

// Blend-mode constants matching the BlendMode enum in src/backends/cpu/main.zig.
// They are not exported from cpu/main.zig (it's the backend module, not a public
// API); we redeclare the integer values here to keep this example self-contained.
const cpu_blend_normal: u32 = 0;
const cpu_blend_multiply: u32 = 1;
const cpu_blend_screen: u32 = 2;
