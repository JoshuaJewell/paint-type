-- SPDX-License-Identifier: AGPL-3.0-or-later
||| paint.type Hexadeca-Connector ABI
|||
||| Mirrors the Zig `Connector` enum in `src/interface/ffi/src/hexadeca.zig`.

module Abi.Connector

import Decidable.Equality

%default total

public export
data Connector = 
    Grpc
  | Graphql
  | Rest
  | Flatbuffers
  | Bebop
  | Jsonrpc
  | Websocket
  | Mqtt
  | Trpc
  | Capnproto
  | Soap
  | VerisimdbRest
  | Bsp
  | Scip
  | Ipfs
  | ArrowFlight

public export
connectorToCode : Connector -> Bits8
connectorToCode Grpc = 0
connectorToCode Graphql = 1
connectorToCode Rest = 2
connectorToCode Flatbuffers = 3
connectorToCode Bebop = 4
connectorToCode Jsonrpc = 5
connectorToCode Websocket = 6
connectorToCode Mqtt = 7
connectorToCode Trpc = 8
connectorToCode Capnproto = 9
connectorToCode Soap = 10
connectorToCode VerisimdbRest = 11
connectorToCode Bsp = 12
connectorToCode Scip = 13
connectorToCode Ipfs = 14
connectorToCode ArrowFlight = 15

public export
codeToConnector : Bits8 -> Maybe Connector
codeToConnector 0 = Just Grpc
codeToConnector 1 = Just Graphql
codeToConnector 2 = Just Rest
codeToConnector 3 = Just Flatbuffers
codeToConnector 4 = Just Bebop
codeToConnector 5 = Just Jsonrpc
codeToConnector 6 = Just Websocket
codeToConnector 7 = Just Mqtt
codeToConnector 8 = Just Trpc
codeToConnector 9 = Just Capnproto
codeToConnector 10 = Just Soap
codeToConnector 11 = Just VerisimdbRest
codeToConnector 12 = Just Bsp
codeToConnector 13 = Just Scip
codeToConnector 14 = Just Ipfs
codeToConnector 15 = Just ArrowFlight
codeToConnector _ = Nothing

public export
implementation DecEq Connector where
  -- Exhaustive 16x16 decision table over the full constructor set. Diagonal
  -- pairs reduce by `Refl`; every off-diagonal pair is discriminated by
  -- constructor distinctness (`\case Refl impossible`). Total and complete:
  -- no fallback clause, no recursion, no escape hatches. The row order mirrors
  -- the Bits8 codes in `connectorToCode` above so the table is auditable.
  decEq Grpc Grpc = Yes Refl
  decEq Grpc Graphql = No (\case Refl impossible)
  decEq Grpc Rest = No (\case Refl impossible)
  decEq Grpc Flatbuffers = No (\case Refl impossible)
  decEq Grpc Bebop = No (\case Refl impossible)
  decEq Grpc Jsonrpc = No (\case Refl impossible)
  decEq Grpc Websocket = No (\case Refl impossible)
  decEq Grpc Mqtt = No (\case Refl impossible)
  decEq Grpc Trpc = No (\case Refl impossible)
  decEq Grpc Capnproto = No (\case Refl impossible)
  decEq Grpc Soap = No (\case Refl impossible)
  decEq Grpc VerisimdbRest = No (\case Refl impossible)
  decEq Grpc Bsp = No (\case Refl impossible)
  decEq Grpc Scip = No (\case Refl impossible)
  decEq Grpc Ipfs = No (\case Refl impossible)
  decEq Grpc ArrowFlight = No (\case Refl impossible)

  decEq Graphql Grpc = No (\case Refl impossible)
  decEq Graphql Graphql = Yes Refl
  decEq Graphql Rest = No (\case Refl impossible)
  decEq Graphql Flatbuffers = No (\case Refl impossible)
  decEq Graphql Bebop = No (\case Refl impossible)
  decEq Graphql Jsonrpc = No (\case Refl impossible)
  decEq Graphql Websocket = No (\case Refl impossible)
  decEq Graphql Mqtt = No (\case Refl impossible)
  decEq Graphql Trpc = No (\case Refl impossible)
  decEq Graphql Capnproto = No (\case Refl impossible)
  decEq Graphql Soap = No (\case Refl impossible)
  decEq Graphql VerisimdbRest = No (\case Refl impossible)
  decEq Graphql Bsp = No (\case Refl impossible)
  decEq Graphql Scip = No (\case Refl impossible)
  decEq Graphql Ipfs = No (\case Refl impossible)
  decEq Graphql ArrowFlight = No (\case Refl impossible)

  decEq Rest Grpc = No (\case Refl impossible)
  decEq Rest Graphql = No (\case Refl impossible)
  decEq Rest Rest = Yes Refl
  decEq Rest Flatbuffers = No (\case Refl impossible)
  decEq Rest Bebop = No (\case Refl impossible)
  decEq Rest Jsonrpc = No (\case Refl impossible)
  decEq Rest Websocket = No (\case Refl impossible)
  decEq Rest Mqtt = No (\case Refl impossible)
  decEq Rest Trpc = No (\case Refl impossible)
  decEq Rest Capnproto = No (\case Refl impossible)
  decEq Rest Soap = No (\case Refl impossible)
  decEq Rest VerisimdbRest = No (\case Refl impossible)
  decEq Rest Bsp = No (\case Refl impossible)
  decEq Rest Scip = No (\case Refl impossible)
  decEq Rest Ipfs = No (\case Refl impossible)
  decEq Rest ArrowFlight = No (\case Refl impossible)

  decEq Flatbuffers Grpc = No (\case Refl impossible)
  decEq Flatbuffers Graphql = No (\case Refl impossible)
  decEq Flatbuffers Rest = No (\case Refl impossible)
  decEq Flatbuffers Flatbuffers = Yes Refl
  decEq Flatbuffers Bebop = No (\case Refl impossible)
  decEq Flatbuffers Jsonrpc = No (\case Refl impossible)
  decEq Flatbuffers Websocket = No (\case Refl impossible)
  decEq Flatbuffers Mqtt = No (\case Refl impossible)
  decEq Flatbuffers Trpc = No (\case Refl impossible)
  decEq Flatbuffers Capnproto = No (\case Refl impossible)
  decEq Flatbuffers Soap = No (\case Refl impossible)
  decEq Flatbuffers VerisimdbRest = No (\case Refl impossible)
  decEq Flatbuffers Bsp = No (\case Refl impossible)
  decEq Flatbuffers Scip = No (\case Refl impossible)
  decEq Flatbuffers Ipfs = No (\case Refl impossible)
  decEq Flatbuffers ArrowFlight = No (\case Refl impossible)

  decEq Bebop Grpc = No (\case Refl impossible)
  decEq Bebop Graphql = No (\case Refl impossible)
  decEq Bebop Rest = No (\case Refl impossible)
  decEq Bebop Flatbuffers = No (\case Refl impossible)
  decEq Bebop Bebop = Yes Refl
  decEq Bebop Jsonrpc = No (\case Refl impossible)
  decEq Bebop Websocket = No (\case Refl impossible)
  decEq Bebop Mqtt = No (\case Refl impossible)
  decEq Bebop Trpc = No (\case Refl impossible)
  decEq Bebop Capnproto = No (\case Refl impossible)
  decEq Bebop Soap = No (\case Refl impossible)
  decEq Bebop VerisimdbRest = No (\case Refl impossible)
  decEq Bebop Bsp = No (\case Refl impossible)
  decEq Bebop Scip = No (\case Refl impossible)
  decEq Bebop Ipfs = No (\case Refl impossible)
  decEq Bebop ArrowFlight = No (\case Refl impossible)

  decEq Jsonrpc Grpc = No (\case Refl impossible)
  decEq Jsonrpc Graphql = No (\case Refl impossible)
  decEq Jsonrpc Rest = No (\case Refl impossible)
  decEq Jsonrpc Flatbuffers = No (\case Refl impossible)
  decEq Jsonrpc Bebop = No (\case Refl impossible)
  decEq Jsonrpc Jsonrpc = Yes Refl
  decEq Jsonrpc Websocket = No (\case Refl impossible)
  decEq Jsonrpc Mqtt = No (\case Refl impossible)
  decEq Jsonrpc Trpc = No (\case Refl impossible)
  decEq Jsonrpc Capnproto = No (\case Refl impossible)
  decEq Jsonrpc Soap = No (\case Refl impossible)
  decEq Jsonrpc VerisimdbRest = No (\case Refl impossible)
  decEq Jsonrpc Bsp = No (\case Refl impossible)
  decEq Jsonrpc Scip = No (\case Refl impossible)
  decEq Jsonrpc Ipfs = No (\case Refl impossible)
  decEq Jsonrpc ArrowFlight = No (\case Refl impossible)

  decEq Websocket Grpc = No (\case Refl impossible)
  decEq Websocket Graphql = No (\case Refl impossible)
  decEq Websocket Rest = No (\case Refl impossible)
  decEq Websocket Flatbuffers = No (\case Refl impossible)
  decEq Websocket Bebop = No (\case Refl impossible)
  decEq Websocket Jsonrpc = No (\case Refl impossible)
  decEq Websocket Websocket = Yes Refl
  decEq Websocket Mqtt = No (\case Refl impossible)
  decEq Websocket Trpc = No (\case Refl impossible)
  decEq Websocket Capnproto = No (\case Refl impossible)
  decEq Websocket Soap = No (\case Refl impossible)
  decEq Websocket VerisimdbRest = No (\case Refl impossible)
  decEq Websocket Bsp = No (\case Refl impossible)
  decEq Websocket Scip = No (\case Refl impossible)
  decEq Websocket Ipfs = No (\case Refl impossible)
  decEq Websocket ArrowFlight = No (\case Refl impossible)

  decEq Mqtt Grpc = No (\case Refl impossible)
  decEq Mqtt Graphql = No (\case Refl impossible)
  decEq Mqtt Rest = No (\case Refl impossible)
  decEq Mqtt Flatbuffers = No (\case Refl impossible)
  decEq Mqtt Bebop = No (\case Refl impossible)
  decEq Mqtt Jsonrpc = No (\case Refl impossible)
  decEq Mqtt Websocket = No (\case Refl impossible)
  decEq Mqtt Mqtt = Yes Refl
  decEq Mqtt Trpc = No (\case Refl impossible)
  decEq Mqtt Capnproto = No (\case Refl impossible)
  decEq Mqtt Soap = No (\case Refl impossible)
  decEq Mqtt VerisimdbRest = No (\case Refl impossible)
  decEq Mqtt Bsp = No (\case Refl impossible)
  decEq Mqtt Scip = No (\case Refl impossible)
  decEq Mqtt Ipfs = No (\case Refl impossible)
  decEq Mqtt ArrowFlight = No (\case Refl impossible)

  decEq Trpc Grpc = No (\case Refl impossible)
  decEq Trpc Graphql = No (\case Refl impossible)
  decEq Trpc Rest = No (\case Refl impossible)
  decEq Trpc Flatbuffers = No (\case Refl impossible)
  decEq Trpc Bebop = No (\case Refl impossible)
  decEq Trpc Jsonrpc = No (\case Refl impossible)
  decEq Trpc Websocket = No (\case Refl impossible)
  decEq Trpc Mqtt = No (\case Refl impossible)
  decEq Trpc Trpc = Yes Refl
  decEq Trpc Capnproto = No (\case Refl impossible)
  decEq Trpc Soap = No (\case Refl impossible)
  decEq Trpc VerisimdbRest = No (\case Refl impossible)
  decEq Trpc Bsp = No (\case Refl impossible)
  decEq Trpc Scip = No (\case Refl impossible)
  decEq Trpc Ipfs = No (\case Refl impossible)
  decEq Trpc ArrowFlight = No (\case Refl impossible)

  decEq Capnproto Grpc = No (\case Refl impossible)
  decEq Capnproto Graphql = No (\case Refl impossible)
  decEq Capnproto Rest = No (\case Refl impossible)
  decEq Capnproto Flatbuffers = No (\case Refl impossible)
  decEq Capnproto Bebop = No (\case Refl impossible)
  decEq Capnproto Jsonrpc = No (\case Refl impossible)
  decEq Capnproto Websocket = No (\case Refl impossible)
  decEq Capnproto Mqtt = No (\case Refl impossible)
  decEq Capnproto Trpc = No (\case Refl impossible)
  decEq Capnproto Capnproto = Yes Refl
  decEq Capnproto Soap = No (\case Refl impossible)
  decEq Capnproto VerisimdbRest = No (\case Refl impossible)
  decEq Capnproto Bsp = No (\case Refl impossible)
  decEq Capnproto Scip = No (\case Refl impossible)
  decEq Capnproto Ipfs = No (\case Refl impossible)
  decEq Capnproto ArrowFlight = No (\case Refl impossible)

  decEq Soap Grpc = No (\case Refl impossible)
  decEq Soap Graphql = No (\case Refl impossible)
  decEq Soap Rest = No (\case Refl impossible)
  decEq Soap Flatbuffers = No (\case Refl impossible)
  decEq Soap Bebop = No (\case Refl impossible)
  decEq Soap Jsonrpc = No (\case Refl impossible)
  decEq Soap Websocket = No (\case Refl impossible)
  decEq Soap Mqtt = No (\case Refl impossible)
  decEq Soap Trpc = No (\case Refl impossible)
  decEq Soap Capnproto = No (\case Refl impossible)
  decEq Soap Soap = Yes Refl
  decEq Soap VerisimdbRest = No (\case Refl impossible)
  decEq Soap Bsp = No (\case Refl impossible)
  decEq Soap Scip = No (\case Refl impossible)
  decEq Soap Ipfs = No (\case Refl impossible)
  decEq Soap ArrowFlight = No (\case Refl impossible)

  decEq VerisimdbRest Grpc = No (\case Refl impossible)
  decEq VerisimdbRest Graphql = No (\case Refl impossible)
  decEq VerisimdbRest Rest = No (\case Refl impossible)
  decEq VerisimdbRest Flatbuffers = No (\case Refl impossible)
  decEq VerisimdbRest Bebop = No (\case Refl impossible)
  decEq VerisimdbRest Jsonrpc = No (\case Refl impossible)
  decEq VerisimdbRest Websocket = No (\case Refl impossible)
  decEq VerisimdbRest Mqtt = No (\case Refl impossible)
  decEq VerisimdbRest Trpc = No (\case Refl impossible)
  decEq VerisimdbRest Capnproto = No (\case Refl impossible)
  decEq VerisimdbRest Soap = No (\case Refl impossible)
  decEq VerisimdbRest VerisimdbRest = Yes Refl
  decEq VerisimdbRest Bsp = No (\case Refl impossible)
  decEq VerisimdbRest Scip = No (\case Refl impossible)
  decEq VerisimdbRest Ipfs = No (\case Refl impossible)
  decEq VerisimdbRest ArrowFlight = No (\case Refl impossible)

  decEq Bsp Grpc = No (\case Refl impossible)
  decEq Bsp Graphql = No (\case Refl impossible)
  decEq Bsp Rest = No (\case Refl impossible)
  decEq Bsp Flatbuffers = No (\case Refl impossible)
  decEq Bsp Bebop = No (\case Refl impossible)
  decEq Bsp Jsonrpc = No (\case Refl impossible)
  decEq Bsp Websocket = No (\case Refl impossible)
  decEq Bsp Mqtt = No (\case Refl impossible)
  decEq Bsp Trpc = No (\case Refl impossible)
  decEq Bsp Capnproto = No (\case Refl impossible)
  decEq Bsp Soap = No (\case Refl impossible)
  decEq Bsp VerisimdbRest = No (\case Refl impossible)
  decEq Bsp Bsp = Yes Refl
  decEq Bsp Scip = No (\case Refl impossible)
  decEq Bsp Ipfs = No (\case Refl impossible)
  decEq Bsp ArrowFlight = No (\case Refl impossible)

  decEq Scip Grpc = No (\case Refl impossible)
  decEq Scip Graphql = No (\case Refl impossible)
  decEq Scip Rest = No (\case Refl impossible)
  decEq Scip Flatbuffers = No (\case Refl impossible)
  decEq Scip Bebop = No (\case Refl impossible)
  decEq Scip Jsonrpc = No (\case Refl impossible)
  decEq Scip Websocket = No (\case Refl impossible)
  decEq Scip Mqtt = No (\case Refl impossible)
  decEq Scip Trpc = No (\case Refl impossible)
  decEq Scip Capnproto = No (\case Refl impossible)
  decEq Scip Soap = No (\case Refl impossible)
  decEq Scip VerisimdbRest = No (\case Refl impossible)
  decEq Scip Bsp = No (\case Refl impossible)
  decEq Scip Scip = Yes Refl
  decEq Scip Ipfs = No (\case Refl impossible)
  decEq Scip ArrowFlight = No (\case Refl impossible)

  decEq Ipfs Grpc = No (\case Refl impossible)
  decEq Ipfs Graphql = No (\case Refl impossible)
  decEq Ipfs Rest = No (\case Refl impossible)
  decEq Ipfs Flatbuffers = No (\case Refl impossible)
  decEq Ipfs Bebop = No (\case Refl impossible)
  decEq Ipfs Jsonrpc = No (\case Refl impossible)
  decEq Ipfs Websocket = No (\case Refl impossible)
  decEq Ipfs Mqtt = No (\case Refl impossible)
  decEq Ipfs Trpc = No (\case Refl impossible)
  decEq Ipfs Capnproto = No (\case Refl impossible)
  decEq Ipfs Soap = No (\case Refl impossible)
  decEq Ipfs VerisimdbRest = No (\case Refl impossible)
  decEq Ipfs Bsp = No (\case Refl impossible)
  decEq Ipfs Scip = No (\case Refl impossible)
  decEq Ipfs Ipfs = Yes Refl
  decEq Ipfs ArrowFlight = No (\case Refl impossible)

  decEq ArrowFlight Grpc = No (\case Refl impossible)
  decEq ArrowFlight Graphql = No (\case Refl impossible)
  decEq ArrowFlight Rest = No (\case Refl impossible)
  decEq ArrowFlight Flatbuffers = No (\case Refl impossible)
  decEq ArrowFlight Bebop = No (\case Refl impossible)
  decEq ArrowFlight Jsonrpc = No (\case Refl impossible)
  decEq ArrowFlight Websocket = No (\case Refl impossible)
  decEq ArrowFlight Mqtt = No (\case Refl impossible)
  decEq ArrowFlight Trpc = No (\case Refl impossible)
  decEq ArrowFlight Capnproto = No (\case Refl impossible)
  decEq ArrowFlight Soap = No (\case Refl impossible)
  decEq ArrowFlight VerisimdbRest = No (\case Refl impossible)
  decEq ArrowFlight Bsp = No (\case Refl impossible)
  decEq ArrowFlight Scip = No (\case Refl impossible)
  decEq ArrowFlight Ipfs = No (\case Refl impossible)
  decEq ArrowFlight ArrowFlight = Yes Refl
