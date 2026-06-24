// SPDX-License-Identifier: AGPL-3.0-or-later
//
// paint.type — VeriSimDB storage backend.
//
// Talks to a hyperpolymath/verisimdb instance over HTTP/8080 (or gRPC/50051
// once the tonic-Zig client is in shape). Implements StorageImpl for the
// octad operations paint.type needs:
//
//   * createOctad      — POST /api/v1/octads
//   * getOctad         — GET  /api/v1/octads/{id}
//   * updateOctad      — PATCH /api/v1/octads/{id}
//   * temporalRecord   — POST /api/v1/octads/{id}/temporal
//   * temporalWalk     — GET  /api/v1/octads/{id}/temporal?at=<node_id>
//   * queryVQL         — POST /api/v1/query
//   * health           — GET  /api/v1/health
//
// Governed by ADR-0003. This file is intentionally light right now: the HTTP
// transport sits behind a `Transport` interface so the real implementation
// can land later without changing call sites. The default `Transport` logs
// what it would have sent (debug build) and returns `Unavailable`, which is
// the dispatcher's signal to fall back to `InMemoryStorage`.

const std = @import("std");

//==============================================================================
// 1. Capability descriptor
//==============================================================================

pub const Modality = enum(u32) {
    graph = 0,
    vector = 1,
    tensor = 2,
    semantic = 3,
    document = 4,
    temporal = 5,
    provenance = 6,
    spatial = 7,
};

pub const Persistence = enum(u32) {
    ephemeral = 0,
    durable = 1,
    replicated = 2,
};

pub const Consistency = enum(u32) {
    strong = 0,
    eventual = 1,
};

pub const StorageCapability = struct {
    modalities: []const Modality,
    persistence: Persistence,
    consistency: Consistency,
};

// VeriSimDB's full reach: all eight modalities, durable, eventually consistent
// at the federation layer (strong inside a single instance).
pub const verisimdb_capability = StorageCapability{
    .modalities = &.{ .graph, .vector, .tensor, .semantic, .document, .temporal, .provenance, .spatial },
    .persistence = .durable,
    .consistency = .eventual,
};

//==============================================================================
// 2. Result type
//==============================================================================

pub const StorageResult = enum(u32) {
    ok = 0,
    not_found = 1,
    invalid = 2,
    conflict = 3,
    unavailable = 4, // → dispatcher falls back to InMemoryStorage
    err = 5,
};

//==============================================================================
// 3. Transport abstraction
//
//    The transport layer is left open so the real implementation (tcp +
//    HTTP/1.1, or std.http once Zig 0.16's API stabilises, or libcurl, or
//    tonic-grpc) can plug in without rewriting call sites.
//==============================================================================

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (
            ctx: *anyopaque,
            method: []const u8,
            path: []const u8,
            body: []const u8,
            out_buf: []u8,
        ) anyerror!usize,
    };

    pub fn request(self: Transport, method: []const u8, path: []const u8, body: []const u8, out_buf: []u8) !usize {
        return self.vtable.request(self.ctx, method, path, body, out_buf);
    }
};

/// Default transport — logs the would-be request and returns Unavailable.
/// Used when no real HTTP transport has been plugged in.
pub const StubTransport = struct {
    pub fn make() Transport {
        return .{ .ctx = @constCast(@ptrCast(&dummy)), .vtable = &vt };
    }
    var dummy: u8 = 0;
    const vt = Transport.VTable{ .request = stubRequest };
    fn stubRequest(_: *anyopaque, method: []const u8, path: []const u8, body: []const u8, _: []u8) !usize {
        std.debug.print("[verisimdb stub] {s} {s} ({d} body bytes)\n", .{ method, path, body.len });
        return error.Unavailable;
    }
};

//==============================================================================
// 4. Client
//==============================================================================

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    transport: Transport,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, transport: Transport) Client {
        return .{ .allocator = allocator, .base_url = base_url, .transport = transport };
    }

    pub fn health(self: *Client) StorageResult {
        var buf: [256]u8 = undefined;
        const n = self.transport.request("GET", "/api/v1/health", "", buf[0..]) catch return .unavailable;
        _ = n;
        return .ok;
    }

    /// Create an octad with the supplied JSON payload. Returns the octad ID
    /// via out_id on success.
    pub fn createOctad(self: *Client, payload_json: []const u8, out_id: *[64]u8) StorageResult {
        var buf: [4096]u8 = undefined;
        const n = self.transport.request("POST", "/api/v1/octads", payload_json, buf[0..]) catch return .unavailable;
        if (n == 0) return .err;
        const max_copy: usize = if (n > out_id.len) out_id.len else n;
        @memcpy(out_id[0..max_copy], buf[0..max_copy]);
        return .ok;
    }

    pub fn getOctad(self: *Client, id: []const u8, out_buf: []u8) struct { rc: StorageResult, n: usize } {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/octads/{s}", .{id}) catch return .{ .rc = .invalid, .n = 0 };
        const n = self.transport.request("GET", path, "", out_buf) catch return .{ .rc = .unavailable, .n = 0 };
        return .{ .rc = .ok, .n = n };
    }

    /// Record one entry in the Temporal modality of the given canvas octad.
    /// Maps to MVP-10 history_record when the storage axis is wired.
    pub fn temporalRecord(self: *Client, canvas_id: []const u8, op_name: []const u8, payload_json: []const u8) StorageResult {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/octads/{s}/temporal", .{canvas_id}) catch return .invalid;

        // Wrap the op_name and the payload into a Temporal-modality entry.
        var body_buf: [8192]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"op_name":"{s}","payload":{s}}}
        , .{ op_name, payload_json }) catch return .invalid;

        var resp_buf: [512]u8 = undefined;
        _ = self.transport.request("POST", path, body, resp_buf[0..]) catch return .unavailable;
        return .ok;
    }

    /// Walk to a specific temporal node. The canonical "undo" / "redo" walk
    /// is expressed in VQL via:
    ///     SELECT TEMPORAL.* FROM HEXAD '{canvas_id}' WHERE TEMPORAL.NODE = '{at}'
    /// and the canvas state is reconstructed from the snapshot stored at
    /// that node.
    pub fn temporalWalk(self: *Client, canvas_id: []const u8, at_node: []const u8, out_buf: []u8) struct { rc: StorageResult, n: usize } {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/octads/{s}/temporal?at={s}", .{ canvas_id, at_node }) catch return .{ .rc = .invalid, .n = 0 };
        const n = self.transport.request("GET", path, "", out_buf) catch return .{ .rc = .unavailable, .n = 0 };
        return .{ .rc = .ok, .n = n };
    }

    /// Issue a VQL or VQL-DT query. paint.type uses VQL for cross-modal
    /// reads (e.g. "find every layer named 'background' across every canvas
    /// in this session") and VQL-DT when the result must carry a proof
    /// certificate (collaborative editing, plugin permission grants).
    pub fn queryVQL(self: *Client, vql: []const u8, out_buf: []u8) struct { rc: StorageResult, n: usize } {
        var body_buf: [8192]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"query":"{s}"}}
        , .{vql}) catch return .{ .rc = .invalid, .n = 0 };
        const n = self.transport.request("POST", "/api/v1/query", body, out_buf) catch return .{ .rc = .unavailable, .n = 0 };
        return .{ .rc = .ok, .n = n };
    }
};

//==============================================================================
// 5. Convenience: a Client wired with the stub transport.
//==============================================================================

pub fn newStubClient(allocator: std.mem.Allocator) Client {
    return Client.init(allocator, "http://localhost:8080", StubTransport.make());
}

//==============================================================================
// 6. Tests
//==============================================================================

test "stub transport returns Unavailable for every endpoint" {
    var client = newStubClient(std.testing.allocator);
    try std.testing.expectEqual(StorageResult.unavailable, client.health());

    var oid: [64]u8 = undefined;
    try std.testing.expectEqual(StorageResult.unavailable, client.createOctad("{}", &oid));

    var buf: [256]u8 = undefined;
    const got = client.getOctad("test-id", buf[0..]);
    try std.testing.expectEqual(StorageResult.unavailable, got.rc);

    try std.testing.expectEqual(StorageResult.unavailable, client.temporalRecord("c1", "stroke.brush", "{}"));

    const walked = client.temporalWalk("c1", "node-5", buf[0..]);
    try std.testing.expectEqual(StorageResult.unavailable, walked.rc);

    const queried = client.queryVQL("SELECT * FROM octads LIMIT 1", buf[0..]);
    try std.testing.expectEqual(StorageResult.unavailable, queried.rc);
}
