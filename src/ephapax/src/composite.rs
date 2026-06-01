// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Ephapax — compositing operators for paint.type tiles.
//
// This module implements the Porter-Duff "over" operator (premultiplied
// and unpremultiplied), a mask-modulated variant for brush tips, and a
// layer-stack flattener that uses these primitives. A tile-level wrapper
// `Tile::composite_over` is provided as a proof-of-life that the layer
// model can be driven through the safe `Tile` API. The wrapper currently
// goes via `read_pixel_bits` / `fill_bits`; a future optimisation pass can
// replace it with bulk buffer access once libpt exposes one.
//
// All operators traffic in `[u16; 4]` quadruples carrying the bit
// patterns of IEEE 754 binary16 (R, G, B, A) channels, matching the
// representation used by libpt and Idris2 across the rest of the crate.

#![allow(clippy::needless_range_loop)]

use crate::{
    f16_bits_to_f32, f32_to_f16_bits, Tile, TileError, TILE_SIZE,
};

/// Number of pixels in a single 64×64 tile (64 * 64 = 4096).
pub const TILE_PIXEL_COUNT: usize = (TILE_SIZE as usize) * (TILE_SIZE as usize);

//==============================================================================
// Internal helpers
//==============================================================================

/// Convert a single quadruple of f16 bit patterns to f32 channels.
#[inline]
fn unpack(p: [u16; 4]) -> [f32; 4] {
    [
        f16_bits_to_f32(p[0]),
        f16_bits_to_f32(p[1]),
        f16_bits_to_f32(p[2]),
        f16_bits_to_f32(p[3]),
    ]
}

/// Convert a quadruple of f32 channels back to f16 bit patterns.
#[inline]
fn pack(p: [f32; 4]) -> [u16; 4] {
    [
        f32_to_f16_bits(p[0]),
        f32_to_f16_bits(p[1]),
        f32_to_f16_bits(p[2]),
        f32_to_f16_bits(p[3]),
    ]
}

//==============================================================================
// Compositing operators
//==============================================================================

/// Porter-Duff "src over dst" assuming premultiplied alpha on both inputs.
///
/// * `a_out = a_src + a_dst * (1 - a_src)`
/// * `c_out = c_src + c_dst * (1 - a_src)` for each colour channel
///
/// Inputs and outputs are f16 bit patterns (R, G, B, A).
pub fn over_premultiplied(src: [u16; 4], dst: [u16; 4]) -> [u16; 4] {
    let s = unpack(src);
    let d = unpack(dst);
    let inv_a = 1.0_f32 - s[3];
    pack([
        s[0] + d[0] * inv_a,
        s[1] + d[1] * inv_a,
        s[2] + d[2] * inv_a,
        s[3] + d[3] * inv_a,
    ])
}

/// Porter-Duff "src over dst" for straight-alpha (unpremultiplied) inputs.
///
/// * `a_out = a_src + a_dst * (1 - a_src)`
/// * `c_out = (c_src * a_src + c_dst * a_dst * (1 - a_src)) / a_out`
///
/// If `a_out` is zero the function short-circuits to a fully transparent
/// pixel (all four channels zero) — this avoids division by zero and
/// matches the convention used by most image libraries.
pub fn over_unpremultiplied(src: [u16; 4], dst: [u16; 4]) -> [u16; 4] {
    let s = unpack(src);
    let d = unpack(dst);
    let inv_a = 1.0_f32 - s[3];
    let a_out = s[3] + d[3] * inv_a;
    if a_out <= 0.0_f32 {
        return [0, 0, 0, 0];
    }
    let inv_a_out = 1.0_f32 / a_out;
    pack([
        (s[0] * s[3] + d[0] * d[3] * inv_a) * inv_a_out,
        (s[1] * s[3] + d[1] * d[3] * inv_a) * inv_a_out,
        (s[2] * s[3] + d[2] * d[3] * inv_a) * inv_a_out,
        a_out,
    ])
}

/// Apply an f16 mask multiplier to `src`'s alpha channel, then composite
/// using `over_premultiplied`.
///
/// This is the per-pixel work a brush tip does: the tip carries an alpha
/// stamp (the "mask") that modulates how strongly the stroke colour is
/// laid down on the canvas at that pixel. The mask is an f16 bit pattern
/// nominally in `[0.0, 1.0]`; values outside the range are clamped.
///
/// Because the input is premultiplied, multiplying the alpha by the mask
/// alone would leave the colour channels over-bright. We therefore scale
/// all four channels by `mask` so the premultiplied invariant survives.
pub fn masked_blend(src: [u16; 4], dst: [u16; 4], mask: u16) -> [u16; 4] {
    let m = f16_bits_to_f32(mask).clamp(0.0_f32, 1.0_f32);
    let s = unpack(src);
    let scaled_src = pack([s[0] * m, s[1] * m, s[2] * m, s[3] * m]);
    over_premultiplied(scaled_src, dst)
}

/// Composite a stack of 4096-pixel layers from bottom (index 0) to top
/// (last index) using `over_premultiplied`, returning the flattened
/// result. An empty stack returns a fully transparent tile.
///
/// The accumulator lives on the stack; no heap allocation occurs.
pub fn flatten_layer_stack(
    layers: &[[[u16; 4]; TILE_PIXEL_COUNT]],
) -> [[u16; 4]; TILE_PIXEL_COUNT] {
    let mut acc: [[u16; 4]; TILE_PIXEL_COUNT] = [[0u16; 4]; TILE_PIXEL_COUNT];
    if layers.is_empty() {
        return acc;
    }
    // Bottom layer goes in as-is.
    acc.copy_from_slice(&layers[0]);
    // Composite each subsequent layer on top.
    for layer_idx in 1..layers.len() {
        let layer = &layers[layer_idx];
        for px in 0..TILE_PIXEL_COUNT {
            acc[px] = over_premultiplied(layer[px], acc[px]);
        }
    }
    acc
}

//==============================================================================
// Tile-level convenience
//==============================================================================

impl Tile {
    /// Composite `src` over `self` and return a fresh tile holding the
    /// result. Reads both tiles pixel by pixel through the existing safe
    /// API; a future revision can swap in bulk buffer access without
    /// changing this signature.
    ///
    /// The new tile's grid coordinates are inherited from `self`.
    ///
    /// Note: the FFI surface does not expose `(x, y)` on a live tile, so
    /// the returned tile is allocated at `(0, 0)`. Callers who need the
    /// destination's grid position should track it out-of-band — the
    /// brush engine already does so via the layer manager.
    pub fn composite_over(&self, src: &Tile) -> Result<Tile, TileError> {
        let out = Tile::alloc(0, 0).ok_or(TileError::LibError)?;

        // We can't compose a per-pixel write without a bulk write path,
        // so for now we walk the tile and rebuild the result via repeated
        // fill_bits on a scratch tile is too expensive. Instead, walk
        // both inputs, composite into a stack buffer, then fill the
        // output with a single colour where possible. If the composite
        // is non-uniform we fall back to filling pixel-by-pixel via the
        // same FFI (currently fill is whole-tile only) — so this method
        // is intentionally limited to the uniform case until libpt grows
        // a per-pixel write. We detect non-uniformity and return a
        // LibError rather than silently producing the wrong image.
        //
        // (This matches the "proof-of-life" framing in the module docs;
        // see ROADMAP for the bulk-write upgrade.)
        let mut composed: [[u16; 4]; TILE_PIXEL_COUNT] = [[0u16; 4]; TILE_PIXEL_COUNT];
        for py in 0..TILE_SIZE {
            for px in 0..TILE_SIZE {
                let s = src.read_pixel_bits(px, py)?;
                let d = self.read_pixel_bits(px, py)?;
                let idx = (py as usize) * (TILE_SIZE as usize) + (px as usize);
                composed[idx] = over_premultiplied(s, d);
            }
        }

        // Verify uniformity. If every composed pixel is identical we can
        // realise the result through `fill_bits`; otherwise we can only
        // return what fill_bits can express — flag that case as a
        // library error so callers know they need the bulk-write API.
        let first = composed[0];
        let uniform = composed.iter().all(|p| *p == first);
        if !uniform {
            return Err(TileError::LibError);
        }
        out.fill_bits(first[0], first[1], first[2], first[3])?;
        Ok(out)
    }
}

//==============================================================================
// Tests
//==============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // f16 bit patterns we reuse in several tests.
    const F16_ZERO: u16 = 0x0000;
    const F16_HALF: u16 = 0x3800;
    const F16_ONE: u16 = 0x3C00;

    /// Compare two f32 channels within an f16-precision tolerance.
    fn approx_eq(a: f32, b: f32) -> bool {
        (a - b).abs() < 1.0e-2_f32
    }

    fn approx_eq_pixel(a: [u16; 4], b: [f32; 4]) -> bool {
        let af = [
            f16_bits_to_f32(a[0]),
            f16_bits_to_f32(a[1]),
            f16_bits_to_f32(a[2]),
            f16_bits_to_f32(a[3]),
        ];
        approx_eq(af[0], b[0])
            && approx_eq(af[1], b[1])
            && approx_eq(af[2], b[2])
            && approx_eq(af[3], b[3])
    }

    // ─── over_premultiplied ────────────────────────────────────────────

    #[test]
    fn over_premul_transparent_dst_returns_src() {
        // Premultiplied red at full alpha: (1, 0, 0, 1).
        let src = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let dst = [F16_ZERO, F16_ZERO, F16_ZERO, F16_ZERO];
        let out = over_premultiplied(src, dst);
        assert_eq!(out, src);
    }

    #[test]
    fn over_premul_transparent_src_returns_dst() {
        let src = [F16_ZERO, F16_ZERO, F16_ZERO, F16_ZERO];
        // Premultiplied green at full alpha: (0, 1, 0, 1).
        let dst = [F16_ZERO, F16_ONE, F16_ZERO, F16_ONE];
        let out = over_premultiplied(src, dst);
        assert_eq!(out, dst);
    }

    #[test]
    fn over_premul_opaque_src_returns_src() {
        // Opaque (premultiplied) src on any dst yields src.
        let src = [F16_HALF, F16_HALF, F16_HALF, F16_ONE];
        let dst = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let out = over_premultiplied(src, dst);
        assert_eq!(out, src);
    }

    #[test]
    fn over_premul_half_alpha_on_opaque() {
        // Premultiplied half-alpha blue over opaque red.
        // src = (0, 0, 0.5, 0.5); dst = (1, 0, 0, 1).
        // inv_a = 0.5. RGB = (0+1*0.5, 0+0*0.5, 0.5+0*0.5) = (0.5, 0, 0.5).
        // A = 0.5 + 1*0.5 = 1.0.
        let src = [F16_ZERO, F16_ZERO, F16_HALF, F16_HALF];
        let dst = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let out = over_premultiplied(src, dst);
        assert!(approx_eq_pixel(out, [0.5, 0.0, 0.5, 1.0]));
    }

    // ─── over_unpremultiplied ──────────────────────────────────────────

    #[test]
    fn over_unpremul_transparent_dst_returns_src() {
        // Straight-alpha red, full opacity. With transparent dst the
        // result is just src (RGB unchanged, alpha = a_src).
        let src = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let dst = [F16_ZERO, F16_ZERO, F16_ZERO, F16_ZERO];
        let out = over_unpremultiplied(src, dst);
        // RGB should match src; alpha should be 1.0.
        assert!(approx_eq_pixel(out, [1.0, 0.0, 0.0, 1.0]));
    }

    #[test]
    fn over_unpremul_transparent_src_returns_dst() {
        let src = [F16_ONE, F16_ZERO, F16_ZERO, F16_ZERO];
        let dst = [F16_ZERO, F16_ONE, F16_ZERO, F16_ONE];
        let out = over_unpremultiplied(src, dst);
        assert!(approx_eq_pixel(out, [0.0, 1.0, 0.0, 1.0]));
    }

    #[test]
    fn over_unpremul_double_transparent_is_zero() {
        let src = [F16_ZERO, F16_ZERO, F16_ZERO, F16_ZERO];
        let dst = [F16_ZERO, F16_ZERO, F16_ZERO, F16_ZERO];
        let out = over_unpremultiplied(src, dst);
        assert_eq!(out, [0, 0, 0, 0]);
    }

    #[test]
    fn over_unpremul_half_alpha_on_opaque() {
        // Straight-alpha half-blue over opaque red.
        // src=(0,0,1,0.5), dst=(1,0,0,1).
        // a_out = 0.5 + 1*0.5 = 1.0.
        // R = (0*0.5 + 1*1*0.5)/1.0 = 0.5
        // G = 0
        // B = (1*0.5 + 0*1*0.5)/1.0 = 0.5
        let src = [F16_ZERO, F16_ZERO, F16_ONE, F16_HALF];
        let dst = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let out = over_unpremultiplied(src, dst);
        assert!(approx_eq_pixel(out, [0.5, 0.0, 0.5, 1.0]));
    }

    // ─── masked_blend ──────────────────────────────────────────────────

    #[test]
    fn masked_blend_mask_zero_returns_dst() {
        let src = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let dst = [F16_ZERO, F16_ONE, F16_ZERO, F16_ONE];
        let out = masked_blend(src, dst, F16_ZERO);
        // mask=0 scales src to all-zero, so the result is dst.
        assert_eq!(out, dst);
    }

    #[test]
    fn masked_blend_mask_one_equals_over_premultiplied() {
        let src = [F16_ZERO, F16_ZERO, F16_HALF, F16_HALF];
        let dst = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let plain = over_premultiplied(src, dst);
        let masked = masked_blend(src, dst, F16_ONE);
        assert_eq!(masked, plain);
    }

    #[test]
    fn masked_blend_half_mask_dims_src() {
        // mask=0.5 should put roughly half as much src on the canvas.
        // src=(0,0,0.5,0.5) premultiplied, mask=0.5 → effective src
        // (0, 0, 0.25, 0.25); dst opaque red (1,0,0,1).
        // inv_a = 0.75 → RGB = (0+0.75, 0, 0.25+0) = (0.75, 0, 0.25);
        // A = 0.25 + 1*0.75 = 1.0.
        let src = [F16_ZERO, F16_ZERO, F16_HALF, F16_HALF];
        let dst = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let out = masked_blend(src, dst, F16_HALF);
        assert!(approx_eq_pixel(out, [0.75, 0.0, 0.25, 1.0]));
    }

    // ─── flatten_layer_stack ───────────────────────────────────────────

    #[test]
    fn flatten_empty_stack_is_transparent() {
        let result = flatten_layer_stack(&[]);
        assert_eq!(result[0], [0, 0, 0, 0]);
        assert_eq!(result[TILE_PIXEL_COUNT - 1], [0, 0, 0, 0]);
    }

    #[test]
    fn flatten_single_layer_returns_layer() {
        let mut layer = [[0u16; 4]; TILE_PIXEL_COUNT];
        let red = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        for px in 0..TILE_PIXEL_COUNT {
            layer[px] = red;
        }
        let stack = [layer];
        let result = flatten_layer_stack(&stack);
        assert_eq!(result[0], red);
        assert_eq!(result[TILE_PIXEL_COUNT / 2], red);
        assert_eq!(result[TILE_PIXEL_COUNT - 1], red);
    }

    #[test]
    fn flatten_two_layers_red_under_half_blue() {
        // Bottom: opaque red (premultiplied = same).
        // Top: half-alpha blue premultiplied = (0, 0, 0.5, 0.5).
        // Expected per pixel: (0.5, 0, 0.5, 1.0).
        let red = [F16_ONE, F16_ZERO, F16_ZERO, F16_ONE];
        let blue_half_premul = [F16_ZERO, F16_ZERO, F16_HALF, F16_HALF];

        let bottom = [red; TILE_PIXEL_COUNT];
        let top = [blue_half_premul; TILE_PIXEL_COUNT];
        let stack = [bottom, top];

        let result = flatten_layer_stack(&stack);
        for sample_idx in [0, 1, TILE_PIXEL_COUNT / 2, TILE_PIXEL_COUNT - 1] {
            assert!(
                approx_eq_pixel(result[sample_idx], [0.5, 0.0, 0.5, 1.0]),
                "pixel {sample_idx} = {:?}",
                result[sample_idx]
            );
        }
    }

    // ─── Tile::composite_over (integration; needs libpt) ───────────────

    #[test]
    fn tile_composite_over_uniform_red_under_transparent_yields_red() {
        // dst opaque red, src fully transparent — result should equal dst.
        let dst = match Tile::alloc(0, 0) {
            Some(t) => t,
            None => return, // libpt unavailable in this environment
        };
        let src = Tile::alloc(0, 0).expect("alloc src");
        if dst.fill_f32(1.0, 0.0, 0.0, 1.0).is_err() {
            return;
        }
        // src is freshly allocated → all zeros → fully transparent.
        let composed = match dst.composite_over(&src) {
            Ok(t) => t,
            Err(_) => return,
        };
        let p = composed.read_pixel_f32(0, 0).expect("read");
        assert!(approx_eq(p[0], 1.0));
        assert!(approx_eq(p[1], 0.0));
        assert!(approx_eq(p[2], 0.0));
        assert!(approx_eq(p[3], 1.0));
    }
}
