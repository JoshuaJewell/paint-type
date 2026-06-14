-- SPDX-License-Identifier: AGPL-3.0-or-later
||| paint.type Hexadeca-Connector Soundness Proof
|||
||| Soundness lemma: the connector-code mapping is injective, so dispatch
||| over the 16 transports can never alias two distinct connectors to one
||| wire code.

module ABI.Connector

import Abi.Connector
import Abi.Types

%default total

||| `Just` is injective — discharged by matching `Refl`.
justInjective : Just a = Just b -> a = b
justInjective Refl = Refl

||| Round-trip inverse: decoding a connector's code recovers the connector.
||| Each case reduces by `Refl` because `connectorToCode` then `codeToConnector`
||| both compute on the concrete `Bits8` literal.
codeRoundTrip : (c : Connector) -> codeToConnector (connectorToCode c) = Just c
codeRoundTrip Grpc = Refl
codeRoundTrip Graphql = Refl
codeRoundTrip Rest = Refl
codeRoundTrip Flatbuffers = Refl
codeRoundTrip Bebop = Refl
codeRoundTrip Jsonrpc = Refl
codeRoundTrip Websocket = Refl
codeRoundTrip Mqtt = Refl
codeRoundTrip Trpc = Refl
codeRoundTrip Capnproto = Refl
codeRoundTrip Soap = Refl
codeRoundTrip VerisimdbRest = Refl
codeRoundTrip Bsp = Refl
codeRoundTrip Scip = Refl
codeRoundTrip Ipfs = Refl
codeRoundTrip ArrowFlight = Refl

||| Invariant: every connector code maps to exactly one connector.
|||
||| Proved through the round-trip inverse `codeToConnector`, so there is no
||| per-pair case analysis and no `absurd` applied to a non-absurd proof:
||| `Just c1 = decode (code c1) = decode (code c2) = Just c2`, then `Just`
||| injectivity gives `c1 = c2`.
public export
0 codeInjective : (c1, c2 : Connector) -> connectorToCode c1 = connectorToCode c2 -> c1 = c2
codeInjective c1 c2 prf =
  justInjective
    (trans (sym (codeRoundTrip c1))
           (trans (cong codeToConnector prf) (codeRoundTrip c2)))
