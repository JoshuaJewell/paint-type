// SPDX-License-Identifier: AGPL-3.0-or-later
//
// INV-1b — encode∘decode byte-stability on fuzzer-found canvases. For ANY byte
// slice the decoder accepts, re-encoding the decoded canvas and decoding that
// again must reach a FIXPOINT: the two encodings are byte-identical. This is
// issue #13's byte-equality criterion (and the estate's "equivalence as
// identity", doctrine #13) — the canonical notion of "same canvas" for a
// bit-preserving format crate. The hand-written unit tests check it on a few
// crafted canvases; this exercises it on whatever structurally-valid inputs the
// fuzzer finds (degenerate dims, odd tile keys, edge half-float bits).
//
// We deliberately do NOT assert `decode(encode(c)) == c` via the derived
// `PartialEq`: `Canvas.background` is `[f32; 4]`, and IEEE-754 makes `NaN !=
// NaN`, so structural equality is non-reflexive for any canvas with a NaN-bit
// background even though the bytes round-trip perfectly. (The INV-1 fuzzer
// found exactly such a 52-byte input.) Byte-equality is the robust invariant;
// structural `==` is a finite-data convenience and must not be reinstated here.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Only structurally-valid inputs exercise the property; reject the rest.
    let canvas = match ptype_format::decode(data) {
        Ok(c) => c,
        Err(_) => return,
    };

    // Our own encoder output must always decode back (well-formed by
    // construction); a failure here is a real encode/decode asymmetry.
    let once = ptype_format::encode(&canvas);
    let redecoded = ptype_format::decode(&once).expect("encode() output must decode back");

    // The fixpoint property: re-encoding the re-decoded canvas is byte-identical.
    let twice = ptype_format::encode(&redecoded);
    assert_eq!(once, twice, "encode∘decode was not byte-stable");
});
