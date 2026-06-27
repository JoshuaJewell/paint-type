// SPDX-License-Identifier: MPL-2.0
//
// paint.type desktop shell — WebKitGTK bootstrap (v0.3.0).
//
// A minimal Gossamer-grade webview host: a GTK 3 top-level window containing a
// WebKitGTK 4.1 web view that renders the empty paint canvas (src/shell/web/
// index.html, embedded at build time). This is the same GTK3 + WebKitGTK stack
// that hyperpolymath/gossamer's `webview_gtk.zig` wraps (create / loadHTML /
// show / run); the window/webview bring-up is isolated in `openShell` so the
// body can later be swapped to call libgossamer's entry points directly once
// the vendored Gossamer module's build graph is wired into paint-type.
//
// Smoke mode: with PT_SHELL_SMOKE set (or `--smoke`), the shell schedules a
// GTK timeout that quits the main loop shortly after the window is shown, so
// `tests/e2e.sh` can verify "open app -> empty canvas visible -> quit clean"
// headlessly under Xvfb. The two stderr markers (`canvas-ready`, `quit-clean`)
// are the harness's assertions.

const std = @import("std");

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("webkit2/webkit2.h");
});

/// The empty-canvas page, embedded so the shell has no runtime file dependency.
const INDEX_HTML: [*:0]const u8 = @embedFile("web/index.html");

/// GtkWidget "destroy" handler — quit the main loop when the window closes.
fn onWindowDestroy(_: ?*c.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    c.gtk_main_quit();
}

/// One-shot GSourceFunc used in smoke mode to quit the loop after the first
/// idle interval. Returns FALSE (G_SOURCE_REMOVE) so it does not repeat.
fn onSmokeTimeout(_: ?*anyopaque) callconv(.c) c_int {
    c.gtk_main_quit();
    return 0;
}

const ShellError = error{ GtkInitFailed, WindowCreateFailed, WebviewCreateFailed };

const Shell = struct {
    window: *c.GtkWidget,
    webview: *c.GtkWidget,
};

/// Bring up the GTK window + WebKitGTK view and load the canvas HTML. Mirrors
/// gossamer/webview_gtk.zig create()+loadHTML()+show().
fn openShell(title: [*:0]const u8, width: c_int, height: c_int) ShellError!Shell {
    if (c.gtk_init_check(null, null) == 0) return ShellError.GtkInitFailed;

    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) orelse
        return ShellError.WindowCreateFailed;
    c.gtk_window_set_title(@ptrCast(window), title);
    c.gtk_window_set_default_size(@ptrCast(window), width, height);

    const webview = c.webkit_web_view_new() orelse {
        c.gtk_widget_destroy(window);
        return ShellError.WebviewCreateFailed;
    };
    c.gtk_container_add(@ptrCast(window), webview);

    _ = c.g_signal_connect_data(
        @ptrCast(window),
        "destroy",
        @ptrCast(&onWindowDestroy),
        null,
        null,
        0,
    );

    c.webkit_web_view_load_html(@ptrCast(webview), INDEX_HTML, null);
    c.gtk_widget_show_all(window);

    return Shell{ .window = window, .webview = webview };
}

fn smokeRequested() bool {
    if (std.posix.getenv("PT_SHELL_SMOKE") != null) return true;
    var args = std.process.args();
    _ = args.next(); // argv[0]
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--smoke")) return true;
    }
    return false;
}

pub fn main() u8 {
    _ = openShell("paint.type", 1024, 768) catch |e| {
        std.debug.print("PT_SHELL: open-failed ({s})\n", .{@errorName(e)});
        return 1;
    };

    // Window + web view created and the canvas HTML submitted to WebKit.
    std.debug.print("PT_SHELL: canvas-ready\n", .{});

    if (smokeRequested()) {
        _ = c.g_timeout_add(800, @ptrCast(&onSmokeTimeout), null);
    }

    c.gtk_main();

    std.debug.print("PT_SHELL: quit-clean\n", .{});
    return 0;
}
