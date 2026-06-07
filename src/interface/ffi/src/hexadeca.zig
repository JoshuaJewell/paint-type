// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Joshua Jewell (JoshuaJewell) <paint-type@pm.me>
//
// paint.type Hexadeca-Connector — sixteen-protocol unified API surface.
//
// Implements a multi-transport surface wrapping the paint.type FFI core.
// The hexadeca pattern follows the estate standard established in Hypatia.
//
//   Core 12 protocols
//     1.  grpc
//     2.  graphql
//     3.  rest
//     4.  flatbuffers
//     5.  bebop
//     6.  jsonrpc
//     7.  websocket
//     8.  mqtt
//     9.  trpc
//     10. capnproto
//     11. soap
//     12. verisimdb-rest
//   Umoja-substrate 4
//     13. bsp           (Build Server Protocol)
//     14. scip          (Source Code Index Protocol)
//     15. ipfs
//     16. arrow-flight
//
// Each connector exposes a standard start/dispatch interface.

const std = @import("std");

pub const Connector = enum(u8) {
    grpc = 0,
    graphql = 1,
    rest = 2,
    flatbuffers = 3,
    bebop = 4,
    jsonrpc = 5,
    websocket = 6,
    mqtt = 7,
    trpc = 8,
    capnproto = 9,
    soap = 10,
    verisimdb_rest = 11,
    bsp = 12,
    scip = 13,
    ipfs = 14,
    arrow_flight = 15,

    pub fn name(self: Connector) [*:0]const u8 {
        return switch (self) {
            .grpc => "grpc",
            .graphql => "graphql",
            .rest => "rest",
            .flatbuffers => "flatbuffers",
            .bebop => "bebop",
            .jsonrpc => "jsonrpc",
            .websocket => "websocket",
            .mqtt => "mqtt",
            .trpc => "trpc",
            .capnproto => "capnproto",
            .soap => "soap",
            .verisimdb_rest => "verisimdb-rest",
            .bsp => "bsp",
            .scip => "scip",
            .ipfs => "ipfs",
            .arrow_flight => "arrow-flight",
        };
    }
};

pub const CONNECTOR_COUNT: usize = @typeInfo(Connector).@"enum".fields.len;

const grpc = @import("connectors/grpc.zig");
const graphql = @import("connectors/graphql.zig");
const rest = @import("connectors/rest.zig");
const flatbuffers = @import("connectors/flatbuffers.zig");
const bebop = @import("connectors/bebop.zig");
const jsonrpc = @import("connectors/jsonrpc.zig");
const websocket = @import("connectors/websocket.zig");
const mqtt = @import("connectors/mqtt.zig");
const trpc = @import("connectors/trpc.zig");
const capnproto = @import("connectors/capnproto.zig");
const soap = @import("connectors/soap.zig");
const verisimdb_rest = @import("connectors/verisimdb_rest.zig");
const bsp = @import("connectors/bsp.zig");
const scip = @import("connectors/scip.zig");
const ipfs = @import("connectors/ipfs.zig");
const arrow_flight = @import("connectors/arrow_flight.zig");

pub fn startAll(base_port: u16) void {
    grpc.start(base_port + 0);
    graphql.start(base_port + 1);
    rest.start(base_port + 2);
    flatbuffers.start(base_port + 3);
    bebop.start(base_port + 4);
    jsonrpc.start(base_port + 5);
    websocket.start(base_port + 6);
    mqtt.start(base_port + 7);
    trpc.start(base_port + 8);
    capnproto.start(base_port + 9);
    soap.start(base_port + 10);
    verisimdb_rest.start(base_port + 11);
    bsp.start(base_port + 12);
    scip.start(base_port + 13);
    ipfs.start(base_port + 14);
    arrow_flight.start(base_port + 15);
}

test "hexadeca count" {
    try std.testing.expectEqual(@as(usize, 16), CONNECTOR_COUNT);
}
