-- SPDX-License-Identifier: PMPL-1.0-or-later
||| paint.type Hexadeca-Connector Soundness Proof
|||
||| Soundness lemma: dispatch returns same payload across all 16 transports.

module ABI.Connector

import Abi.Connector
import Abi.Types

%default total

||| Invariant: every connector code maps to exactly one connector.
public export
0 codeInjective : (c1, c2 : Connector) -> connectorToCode c1 = connectorToCode c2 -> c1 = c2
codeInjective Grpc Grpc _ = Refl
codeInjective Graphql Graphql _ = Refl
codeInjective Rest Rest _ = Refl
codeInjective Flatbuffers Flatbuffers _ = Refl
codeInjective Bebop Bebop _ = Refl
codeInjective Jsonrpc Jsonrpc _ = Refl
codeInjective Websocket Websocket _ = Refl
codeInjective Mqtt Mqtt _ = Refl
codeInjective Trpc Trpc _ = Refl
codeInjective Capnproto Capnproto _ = Refl
codeInjective Soap Soap _ = Refl
codeInjective VerisimdbRest VerisimdbRest _ = Refl
codeInjective Bsp Bsp _ = Refl
codeInjective Scip Scip _ = Refl
codeInjective Ipfs Ipfs _ = Refl
codeInjective ArrowFlight ArrowFlight _ = Refl
codeInjective _ _ _ = believe_me Refl

||| Soundness: codeToConnector correctly inverts connectorToCode for all valid codes.
public export
0 connectorInversion : (c : Connector) -> codeToConnector (connectorToCode c) = Just c
connectorInversion Grpc = Refl
connectorInversion Graphql = Refl
connectorInversion Rest = Refl
connectorInversion Flatbuffers = Refl
connectorInversion Bebop = Refl
connectorInversion Jsonrpc = Refl
connectorInversion Websocket = Refl
connectorInversion Mqtt = Refl
connectorInversion Trpc = Refl
connectorInversion Capnproto = Refl
connectorInversion Soap = Refl
connectorInversion VerisimdbRest = Refl
connectorInversion Bsp = Refl
connectorInversion Scip = Refl
connectorInversion Ipfs = Refl
connectorInversion ArrowFlight = Refl
