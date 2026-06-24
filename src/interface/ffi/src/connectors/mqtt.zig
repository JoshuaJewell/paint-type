// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Joshua Jewell (JoshuaJewell) <paint-type@pm.me>
//
// Connector module for mqtt. Stub fidelity; see `hexadeca.zig`.

const std = @import("std");

pub fn start(port: u16) void {
    std.debug.print("[hexadeca] mqtt connector starting on port {d}\n", .{port});
}

pub fn dispatch(req: []const u8) i32 {
    _ = req;
    return 0;
}
