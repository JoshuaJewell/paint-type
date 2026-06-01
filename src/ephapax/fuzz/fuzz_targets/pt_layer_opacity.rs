// SPDX-License-Identifier: PMPL-1.0-or-later
//
// pt_layer_set_opacity / pt_layer_push fuzz target.
//
// Drives the layer-metadata FFI surface with arbitrary opacity bit
// patterns (every u32 IS a valid IEEE 754 binary32, so the fuzzer
// covers NaN, ±Inf, subnormals, and overshoot in one go) and arbitrary
// layer-name byte slices. Pushes up to a handful of layers, sets
// opacity on each, then reads it back.
//
// Invariants asserted (matching the documented clamp semantics in
// src/interface/ffi/src/main.zig::clamp_opacity):
//   * NaN  → reads back as 1.0
//   * v < 0  (incl. -Inf, -0.0) → reads back as 0.0
//   * v > 1  (incl. +Inf)       → reads back as 1.0
//   * v in [0, 1]               → reads back unchanged
//   * Every FFI call returns; libpt never aborts.

#![no_main]

use ephapax::{
    pt_layer_count, pt_layer_get_opacity, pt_layer_push, pt_layer_set_opacity, pt_layer_stack_free,
    pt_layer_stack_new, PT_LAYER_ID_NONE,
};
use libfuzzer_sys::fuzz_target;

const RESULT_OK: u32 = 0;

#[derive(arbitrary::Arbitrary, Debug)]
struct LayerInput {
    /// One opacity bit pattern per pushed layer.
    opacities: Vec<u32>,
    /// Raw bytes used as layer names. Truncated per-push to <= 64 bytes
    /// (the documented in-FFI cap is comparable; libpt is responsible
    /// for self-defending against oversize names).
    name_seed: Vec<u8>,
    /// Number of layers to push, bounded to PT_MAX_LAYERS (256) so the
    /// stack does not refuse all pushes after the first input.
    push_count: u8,
}

fuzz_target!(|input: LayerInput| {
    // SAFETY: pt_layer_stack_new returns either 0 (OOM) or a valid
    // PtLayerStack pointer. We bail on 0 and free on every other path.
    let stack = unsafe { pt_layer_stack_new() };
    if stack == 0 {
        return;
    }

    // Cap the push count so individual fuzz iterations stay fast and
    // we don't exhaust the 256-layer pool on the first input.
    let push_count = (input.push_count as usize).min(16);

    let mut ids: Vec<u32> = Vec::with_capacity(push_count);

    for i in 0..push_count {
        // Slice a window of the name seed for each push. An empty name
        // is legal and is also fuzzed via name_seed.is_empty().
        let name_slice: &[u8] = if input.name_seed.is_empty() {
            b""
        } else {
            let start = i.wrapping_mul(8) % input.name_seed.len();
            let end = (start + 16).min(input.name_seed.len());
            &input.name_seed[start..end]
        };

        // SAFETY: name_slice's pointer is valid for name_slice.len()
        // bytes for the duration of the call (the slice outlives the
        // FFI return). pt_layer_push validates the stack pointer and
        // copies the name internally.
        let id =
            unsafe { pt_layer_push(stack, name_slice.as_ptr() as u64, name_slice.len() as u32) };
        if id == PT_LAYER_ID_NONE {
            // Stack full / invalid name length — that is an in-spec
            // refusal, not a fuzzer-actionable bug.
            continue;
        }
        ids.push(id);
    }

    // SAFETY: stack is live.
    let count = unsafe { pt_layer_count(stack) };
    assert!(
        count as usize == ids.len(),
        "pt_layer_count {count} disagrees with successful pushes {}",
        ids.len()
    );

    // Pair each id with one opacity bit pattern (cycling if shorter).
    for (i, &id) in ids.iter().enumerate() {
        let bits = input
            .opacities
            .get(i % input.opacities.len().max(1))
            .copied()
            .unwrap_or(0x3F80_0000); // 1.0_f32

        // SAFETY: stack and id are live; opacity_bits accepts any u32.
        let rc = unsafe { pt_layer_set_opacity(stack, id, bits) };
        assert_eq!(rc, RESULT_OK, "set_opacity on live id {id} failed");

        // SAFETY: stack and id are live.
        let got_bits = unsafe { pt_layer_get_opacity(stack, id) };
        let got = f32::from_bits(got_bits);

        // Compute the expected clamp result mirroring libpt's
        // clamp_opacity (see src/interface/ffi/src/main.zig). We can NOT
        // use `input_f.clamp(0.0, 1.0)` here: f32::clamp would return NaN
        // for NaN input, whereas the documented libpt semantics map NaN
        // to 1.0.
        #[allow(clippy::manual_clamp)]
        let input_f = f32::from_bits(bits);
        #[allow(clippy::manual_clamp)]
        let expected: f32 = if input_f.is_nan() {
            1.0
        } else if input_f < 0.0 {
            0.0
        } else if input_f > 1.0 {
            1.0
        } else {
            input_f
        };

        // For non-NaN expected we compare exactly (bit-level for
        // ±0.0 normalisation purposes — both encodings are accepted
        // as "0.0" since the f32 comparison `< 0.0` is false for -0.0,
        // matching the Zig semantics).
        assert!(
            !got.is_nan(),
            "clamp output for input bits 0x{bits:08x} is NaN ({got})"
        );
        assert_eq!(
            got, expected,
            "clamp mismatch: input bits 0x{bits:08x} ({input_f}) → got {got}, expected {expected}"
        );
        assert!((0.0..=1.0).contains(&got), "clamp escaped [0,1]: {got}");
    }

    // SAFETY: stack is live; freeing it once is the contract.
    unsafe { pt_layer_stack_free(stack) };
});
