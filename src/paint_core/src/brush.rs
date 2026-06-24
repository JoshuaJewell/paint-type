// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Paint Core — brush engine for paint.type.
//
// Three concerns live here:
//
//   * **Tip masks.** `BrushTip` carries a square 2-D array of f16 alpha
//     values. `soft_round` produces a gaussian-falloff disc; `hard_round`
//     produces a near-flat disc with a one-pixel anti-aliased edge.
//     Other tip shapes (square, textured) are deliberately deferred.
//   * **Stroke sampling.** `Stroke` interpolates between sparse cursor
//     samples and emits stamp centres at the brush's spacing interval.
//     The first sample of a stroke always produces exactly one stamp at
//     that point so single-click dabs work; subsequent samples emit
//     `floor((distance_run) / spacing)` further stamps, with the leftover
//     distance carried into the next push.
//   * **Tile-local stamping.** `Brush::stamp` reads each pixel in the
//     tip's footprint, composites the brush colour modulated by the tip
//     mask using `composite::masked_blend`, and writes the result back.
//     Out-of-bounds pixels are silently clipped to the tile — cross-tile
//     stamping is the layer manager's responsibility, not the brush's.
//
// All operations work on the existing safe `Tile` API. No new FFI
// surface — the brush engine is pure-Rust above libpt.

use crate::{
    composite::masked_blend, f16_bits_to_f32, f32_to_f16_bits, Tile, TileError, TILE_SCALARS,
    TILE_SIZE,
};

//==============================================================================
// BrushTip
//==============================================================================

/// A square brush-tip mask. `mask.len() == (diameter as usize).pow(2)`
/// after every constructor call.
///
/// Mask values are f16 bit patterns nominally in `[0, 1]`: zero means
/// "no contribution at this pixel", one means "full contribution". Use
/// `BrushTip::sample` rather than indexing `mask` directly so callers
/// don't have to remember the row-major layout.
#[derive(Debug, Clone)]
pub struct BrushTip {
    diameter: u32,
    mask: Vec<u16>,
}

impl BrushTip {
    /// Build a soft round tip with gaussian falloff. The mask is `1.0`
    /// at the centre, falling to `~0.01` near the edge. `diameter` is
    /// clamped to `[1, TILE_SIZE]` — a tip larger than a tile would be
    /// unable to stamp cleanly without cross-tile compositing.
    pub fn soft_round(diameter: u32) -> Self {
        let d = diameter.clamp(1, TILE_SIZE);
        let size = d as usize;
        let mut mask = vec![0u16; size * size];

        if d == 1 {
            mask[0] = f32_to_f16_bits(1.0);
            return Self { diameter: d, mask };
        }

        // Centre of the disc in continuous coordinates. For an N-pixel
        // tip the pixel centres are at 0.5, 1.5, …, N-0.5.
        let centre = d as f32 * 0.5_f32;
        let radius = centre;
        // Falloff: a(r) = exp(-(r / sigma)^2) with sigma chosen so the
        // edge pixel sits at ~0.01 (sigma ≈ radius / 2.15).
        let sigma = radius / 2.15_f32;
        let inv_two_sigma_sq = 1.0_f32 / (2.0_f32 * sigma * sigma);

        for y in 0..size {
            for x in 0..size {
                let dx = (x as f32 + 0.5_f32) - centre;
                let dy = (y as f32 + 0.5_f32) - centre;
                let r_sq = dx * dx + dy * dy;
                if r_sq.sqrt() > radius {
                    // Outside the disc — zero contribution.
                    continue;
                }
                let a = (-r_sq * inv_two_sigma_sq).exp();
                mask[y * size + x] = f32_to_f16_bits(a);
            }
        }

        Self { diameter: d, mask }
    }

    /// Build a hard round tip — flat alpha = 1 inside the disc, with a
    /// one-pixel-wide anti-aliased edge that grades linearly from 1 → 0.
    /// `diameter` is clamped to `[1, TILE_SIZE]`.
    pub fn hard_round(diameter: u32) -> Self {
        let d = diameter.clamp(1, TILE_SIZE);
        let size = d as usize;
        let mut mask = vec![0u16; size * size];

        if d == 1 {
            mask[0] = f32_to_f16_bits(1.0);
            return Self { diameter: d, mask };
        }

        let centre = d as f32 * 0.5_f32;
        let radius = centre;
        // The anti-aliased edge sits in `[radius - 1, radius]`.
        let edge_start = (radius - 1.0_f32).max(0.0_f32);

        for y in 0..size {
            for x in 0..size {
                let dx = (x as f32 + 0.5_f32) - centre;
                let dy = (y as f32 + 0.5_f32) - centre;
                let r = (dx * dx + dy * dy).sqrt();
                let a = if r <= edge_start {
                    1.0_f32
                } else if r >= radius {
                    0.0_f32
                } else {
                    1.0_f32 - (r - edge_start) / (radius - edge_start)
                };
                mask[y * size + x] = f32_to_f16_bits(a);
            }
        }

        Self { diameter: d, mask }
    }

    /// Edge length of the (square) mask, in pixels.
    pub fn diameter(&self) -> u32 {
        self.diameter
    }

    /// Mask value (f16 bit pattern) at tip-local `(x, y)`. Out-of-range
    /// queries return `0` rather than panicking.
    pub fn sample(&self, x: u32, y: u32) -> u16 {
        if x >= self.diameter || y >= self.diameter {
            return 0;
        }
        let idx = (y as usize) * (self.diameter as usize) + (x as usize);
        self.mask[idx]
    }
}

//==============================================================================
// Brush
//==============================================================================

/// A brush carries a tip mask, a premultiplied colour, and a spacing
/// ratio. Spacing is given as a fraction of the tip diameter — a value
/// of `0.25` means "stamp every 25% of the tip diameter along the
/// stroke", which is a common default in painting applications.
#[derive(Debug, Clone)]
pub struct Brush {
    tip: BrushTip,
    color: [u16; 4],
    spacing_ratio: f32,
}

impl Brush {
    /// Construct a brush from an f32 RGBA colour and a tip. The colour
    /// is interpreted as **straight-alpha** and premultiplied internally.
    /// Channels outside `[0, 1]` are clamped; NaN is treated as zero.
    pub fn new(tip: BrushTip, color_rgba: [f32; 4], spacing_ratio: f32) -> Self {
        let mut c = color_rgba;
        for ch in &mut c {
            *ch = if ch.is_nan() { 0.0 } else { ch.clamp(0.0, 1.0) };
        }
        let premul = [c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3]];
        let color = [
            f32_to_f16_bits(premul[0]),
            f32_to_f16_bits(premul[1]),
            f32_to_f16_bits(premul[2]),
            f32_to_f16_bits(premul[3]),
        ];
        let spacing_ratio = if spacing_ratio.is_nan() || spacing_ratio <= 0.0 {
            0.25
        } else if spacing_ratio > 1.0 {
            1.0
        } else {
            spacing_ratio
        };
        Self {
            tip,
            color,
            spacing_ratio,
        }
    }

    /// Distance (in pixels) between consecutive stamps along a stroke.
    pub fn stamp_spacing(&self) -> f32 {
        (self.tip.diameter() as f32 * self.spacing_ratio).max(1.0_f32)
    }

    /// Stamp the tip onto `tile` centred at tile-local `(cx, cy)`. Pixels
    /// outside the tile are silently clipped. The compositing rule is
    /// `composite::masked_blend(brush_color, dst_pixel, mask_value)` per
    /// affected pixel.
    ///
    /// Returns the number of pixels actually written (after clipping).
    pub fn stamp(&self, tile: &Tile, cx: f32, cy: f32) -> Result<u32, TileError> {
        let d = self.tip.diameter() as i64;
        // Tip footprint in tile-local coordinates.
        let half = (d as f32) * 0.5_f32;
        let top_left_x = (cx - half).floor() as i64;
        let top_left_y = (cy - half).floor() as i64;

        // Read the whole tile once, blend the footprint in-process, and write
        // once. Per-pixel FFI (~13us/call) is unusable on the brush hot path.
        let mut buf = [0u16; TILE_SCALARS];
        tile.read_buffer(&mut buf)?;

        let mut written: u32 = 0;
        for ty in 0..d {
            let py = top_left_y + ty;
            if py < 0 || py >= TILE_SIZE as i64 {
                continue;
            }
            for tx in 0..d {
                let px = top_left_x + tx;
                if px < 0 || px >= TILE_SIZE as i64 {
                    continue;
                }
                let mask_value = self.tip.sample(tx as u32, ty as u32);
                if mask_value == 0 {
                    // Fully transparent — nothing to do.
                    continue;
                }
                let idx = ((py as usize) * TILE_SIZE as usize + (px as usize)) * 4;
                let dst = [buf[idx], buf[idx + 1], buf[idx + 2], buf[idx + 3]];
                let blended = masked_blend(self.color, dst, mask_value);
                buf[idx] = blended[0];
                buf[idx + 1] = blended[1];
                buf[idx + 2] = blended[2];
                buf[idx + 3] = blended[3];
                written += 1;
            }
        }

        if written > 0 {
            tile.write_buffer(&buf)?;
        }
        Ok(written)
    }

    /// Erase from `tile` centred at tile-local `(cx, cy)`. The tip mask
    /// drives the erase strength: each channel of the destination pixel is
    /// scaled by `(1 - mask_alpha)`, removing premultiplied colour and alpha
    /// in proportion to the tip. Pixels where the mask is zero are left
    /// untouched. Only calls `write_buffer` when at least one pixel changed.
    pub fn erase_stamp(&self, tile: &Tile, cx: f32, cy: f32) -> Result<u32, TileError> {
        let d = self.tip.diameter() as i64;
        let half = (d as f32) * 0.5_f32;
        let top_left_x = (cx - half).floor() as i64;
        let top_left_y = (cy - half).floor() as i64;

        let mut buf = [0u16; TILE_SCALARS];
        tile.read_buffer(&mut buf)?;

        let mut written: u32 = 0;
        for ty in 0..d {
            let py = top_left_y + ty;
            if py < 0 || py >= TILE_SIZE as i64 {
                continue;
            }
            for tx in 0..d {
                let px = top_left_x + tx;
                if px < 0 || px >= TILE_SIZE as i64 {
                    continue;
                }
                let mask_value = self.tip.sample(tx as u32, ty as u32);
                if mask_value == 0 {
                    continue;
                }
                let mask_alpha = f16_bits_to_f32(mask_value);
                let scale = 1.0_f32 - mask_alpha;
                let idx = ((py as usize) * TILE_SIZE as usize + (px as usize)) * 4;
                buf[idx]     = f32_to_f16_bits(f16_bits_to_f32(buf[idx])     * scale);
                buf[idx + 1] = f32_to_f16_bits(f16_bits_to_f32(buf[idx + 1]) * scale);
                buf[idx + 2] = f32_to_f16_bits(f16_bits_to_f32(buf[idx + 2]) * scale);
                buf[idx + 3] = f32_to_f16_bits(f16_bits_to_f32(buf[idx + 3]) * scale);
                written += 1;
            }
        }

        if written > 0 {
            tile.write_buffer(&buf)?;
        }
        Ok(written)
    }
}

//==============================================================================
// Stroke (point interpolation)
//==============================================================================

/// Stateful stroke sampler. The user pushes sparse cursor samples; the
/// stroke fills in stamp centres at the brush's spacing interval. State
/// is cheap to reset between strokes.
#[derive(Debug, Clone, Default)]
pub struct Stroke {
    last_point: Option<(f32, f32)>,
    /// Distance until the next scheduled stamp from `last_point`. When
    /// this drops to zero (or below) a stamp is emitted and the value is
    /// reset to the brush's spacing.
    distance_until_next: f32,
}

impl Stroke {
    /// Construct an empty `Stroke`. Equivalent to `Stroke::default()`;
    /// no sample has been seen and no stamps will be emitted until the
    /// first `push`.
    pub fn new() -> Self {
        Self::default()
    }

    /// Forget any previous sample. Use this between distinct strokes.
    pub fn reset(&mut self) {
        self.last_point = None;
        self.distance_until_next = 0.0;
    }

    /// Push the next cursor sample at `(x, y)`. Returns the stamp centres
    /// that should be applied to the canvas between the previous sample
    /// and this one. The first call after `reset` always emits exactly
    /// one stamp at the input point so single-click dabs work.
    pub fn push(&mut self, x: f32, y: f32, brush: &Brush) -> Vec<(f32, f32)> {
        let spacing = brush.stamp_spacing();
        let mut stamps = Vec::new();

        let Some((lx, ly)) = self.last_point else {
            // First sample of a stroke: emit one dab here.
            stamps.push((x, y));
            self.last_point = Some((x, y));
            self.distance_until_next = spacing;
            return stamps;
        };

        let dx = x - lx;
        let dy = y - ly;
        let seg_len = (dx * dx + dy * dy).sqrt();
        if seg_len < f32::EPSILON {
            // Zero-length push — no new stamps.
            return stamps;
        }

        // Distance from (lx, ly) at which to place the next stamp.
        let mut next_at = self.distance_until_next;

        while next_at <= seg_len {
            let t = next_at / seg_len;
            stamps.push((lx + dx * t, ly + dy * t));
            next_at += spacing;
        }

        // Carry the unspent distance into `distance_until_next` so the
        // next push picks up where this one left off.
        self.distance_until_next = next_at - seg_len;
        self.last_point = Some((x, y));
        stamps
    }

    /// Whether the stroke has seen any samples since the last reset.
    pub fn has_started(&self) -> bool {
        self.last_point.is_some()
    }
}

//==============================================================================
// Tests
//==============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f32, b: f32) -> bool {
        (a - b).abs() < 1.0e-2_f32
    }

    // ─── BrushTip ──────────────────────────────────────────────────────

    #[test]
    fn soft_round_centre_is_full_alpha() {
        let tip = BrushTip::soft_round(8);
        // For an 8-pixel tip the brightest pixels straddle (3, 3) / (4, 3) /
        // (3, 4) / (4, 4). Sample (4, 4) — closest to (centre, centre).
        let centre = tip.sample(4, 4);
        let centre_f = f16_bits_to_f32(centre);
        // Gaussian centre should be very close to 1.0.
        assert!(centre_f > 0.9_f32, "centre alpha = {}", centre_f);
    }

    #[test]
    fn soft_round_corner_is_zero() {
        let tip = BrushTip::soft_round(8);
        assert_eq!(tip.sample(0, 0), 0);
        assert_eq!(tip.sample(7, 0), 0);
        assert_eq!(tip.sample(0, 7), 0);
        assert_eq!(tip.sample(7, 7), 0);
    }

    #[test]
    fn soft_round_clamps_diameter_to_tile_size() {
        let tip = BrushTip::soft_round(9999);
        assert_eq!(tip.diameter(), TILE_SIZE);
    }

    #[test]
    fn soft_round_clamps_zero_to_one() {
        let tip = BrushTip::soft_round(0);
        assert_eq!(tip.diameter(), 1);
        assert!(f16_bits_to_f32(tip.sample(0, 0)) > 0.99_f32);
    }

    #[test]
    fn hard_round_interior_is_full_alpha() {
        let tip = BrushTip::hard_round(12);
        let inside = tip.sample(6, 6); // centre
        assert!(approx(f16_bits_to_f32(inside), 1.0_f32));
    }

    #[test]
    fn hard_round_corner_is_zero() {
        let tip = BrushTip::hard_round(12);
        // Sample exactly at the corner of the square mask.
        assert_eq!(tip.sample(0, 0), 0);
        assert_eq!(tip.sample(11, 11), 0);
    }

    #[test]
    fn brush_tip_sample_oob_is_zero() {
        let tip = BrushTip::soft_round(4);
        assert_eq!(tip.sample(4, 0), 0);
        assert_eq!(tip.sample(0, 4), 0);
        assert_eq!(tip.sample(100, 100), 0);
    }

    // ─── Brush construction ────────────────────────────────────────────

    #[test]
    fn brush_clamps_overshoot_colours() {
        let tip = BrushTip::soft_round(2);
        let b = Brush::new(tip, [2.0, -1.0, f32::NAN, 1.0], 0.25);
        // After clamp + premultiply: r=1*1=1, g=0*1=0, b=0*1=0, a=1.
        let expect = [
            f32_to_f16_bits(1.0),
            f32_to_f16_bits(0.0),
            f32_to_f16_bits(0.0),
            f32_to_f16_bits(1.0),
        ];
        assert_eq!(b.color, expect);
    }

    #[test]
    fn brush_clamps_spacing_ratio() {
        let tip = BrushTip::soft_round(8);
        let b = Brush::new(tip, [0.0; 4], -0.5);
        // Negative spacing falls back to 0.25.
        assert!(approx(b.spacing_ratio, 0.25));

        let tip2 = BrushTip::soft_round(8);
        let b2 = Brush::new(tip2, [0.0; 4], 1.5);
        assert!(approx(b2.spacing_ratio, 1.0));
    }

    #[test]
    fn brush_stamp_spacing_never_less_than_one() {
        let tip = BrushTip::soft_round(1);
        let b = Brush::new(tip, [0.0; 4], 0.1);
        // 1 * 0.1 = 0.1 → clamped to 1.0.
        assert!(approx(b.stamp_spacing(), 1.0));
    }

    // ─── Brush::stamp (integration with libpt) ─────────────────────────

    #[test]
    fn stamp_writes_pixels_inside_footprint() {
        let tile = match Tile::alloc(0, 0) {
            Some(t) => t,
            None => return, // libpt unavailable in this environment
        };
        let tip = BrushTip::hard_round(8);
        let brush = Brush::new(tip, [1.0, 0.0, 0.0, 1.0], 0.25);

        // Stamp centred at (32, 32) — well inside the 64x64 tile.
        let written = brush.stamp(&tile, 32.0, 32.0).expect("stamp");
        assert!(written > 0, "expected at least one pixel written");
        assert!(written <= 8 * 8, "wrote more than footprint ({written})");
    }

    #[test]
    fn stamp_clips_at_tile_boundary() {
        let tile = match Tile::alloc(0, 0) {
            Some(t) => t,
            None => return,
        };
        let tip = BrushTip::hard_round(16);
        let brush = Brush::new(tip, [1.0, 1.0, 1.0, 1.0], 0.25);

        // Stamp far outside the tile — nothing should be written.
        let written = brush.stamp(&tile, -200.0, -200.0).expect("stamp");
        assert_eq!(written, 0);

        // Stamp half-off the edge — fewer pixels written than the
        // full footprint.
        let written2 = brush.stamp(&tile, 0.0, 0.0).expect("stamp2");
        assert!(written2 > 0);
        assert!(
            (written2 as usize) <= (16 * 16) / 2 + 16,
            "expected boundary clipping to shrink the footprint, got {written2}"
        );
    }

    #[test]
    fn stamp_zero_mask_skips_pixels() {
        let tile = match Tile::alloc(0, 0) {
            Some(t) => t,
            None => return,
        };
        // Diameter 4 soft-round tip → corner mask values are exactly 0.
        // After stamping at (32, 32), the four corner pixels of the
        // footprint should still read as transparent (untouched).
        let tip = BrushTip::soft_round(4);
        let brush = Brush::new(tip, [1.0, 1.0, 1.0, 1.0], 0.25);
        brush.stamp(&tile, 32.0, 32.0).expect("stamp");

        // (30, 30) is the top-left of the 4x4 footprint centred at
        // (32, 32) — that corner has mask = 0, so the tile pixel should
        // remain (0, 0, 0, 0).
        let p = tile.read_pixel_bits(30, 30).expect("read");
        assert_eq!(p, [0, 0, 0, 0]);
    }

    // ─── Stroke (point interpolation) ──────────────────────────────────

    #[test]
    fn first_push_emits_one_stamp() {
        let mut s = Stroke::new();
        let tip = BrushTip::soft_round(8);
        let b = Brush::new(tip, [0.0; 4], 0.25);
        let stamps = s.push(10.0, 20.0, &b);
        assert_eq!(stamps.len(), 1);
        assert!(approx(stamps[0].0, 10.0) && approx(stamps[0].1, 20.0));
    }

    #[test]
    fn zero_motion_emits_no_extra_stamps() {
        let mut s = Stroke::new();
        let tip = BrushTip::soft_round(8);
        let b = Brush::new(tip, [0.0; 4], 0.25);
        let _ = s.push(10.0, 20.0, &b);
        // Push the same point again — no movement → no new stamps.
        let stamps = s.push(10.0, 20.0, &b);
        assert!(stamps.is_empty());
    }

    #[test]
    fn long_motion_emits_correct_number_of_stamps() {
        let mut s = Stroke::new();
        let tip = BrushTip::soft_round(8);
        // spacing = 8 * 0.25 = 2.0
        let b = Brush::new(tip, [0.0; 4], 0.25);
        let _ = s.push(0.0, 0.0, &b);
        // Move 10 pixels horizontally → spacing 2.0 means 5 stamps fit.
        let stamps = s.push(10.0, 0.0, &b);
        assert_eq!(stamps.len(), 5);
        // First further stamp lands at x = 2.0.
        assert!(approx(stamps[0].0, 2.0) && approx(stamps[0].1, 0.0));
        // Last lands at x = 10.0.
        assert!(approx(stamps[4].0, 10.0) && approx(stamps[4].1, 0.0));
    }

    #[test]
    fn stamps_distribute_along_diagonal() {
        let mut s = Stroke::new();
        let tip = BrushTip::soft_round(8);
        // spacing = 2.0
        let b = Brush::new(tip, [0.0; 4], 0.25);
        let _ = s.push(0.0, 0.0, &b);
        // sqrt(8^2 + 6^2) = 10 along the diagonal → 5 stamps.
        let stamps = s.push(8.0, 6.0, &b);
        assert_eq!(stamps.len(), 5);
        // Stamps should lie along the (4, 3)/5-direction line.
        for stamp in &stamps {
            // For a point on the line from (0,0) to (8,6) at distance d:
            // x = (4/5)*d, y = (3/5)*d. So y/x = 0.75.
            let (x, y) = *stamp;
            assert!(x > 0.0);
            assert!(approx(y / x, 0.75_f32));
        }
    }

    #[test]
    fn reset_clears_state() {
        let mut s = Stroke::new();
        let tip = BrushTip::soft_round(8);
        let b = Brush::new(tip, [0.0; 4], 0.25);
        let _ = s.push(0.0, 0.0, &b);
        assert!(s.has_started());
        s.reset();
        assert!(!s.has_started());
        // Next push behaves like a fresh first sample.
        let stamps = s.push(5.0, 5.0, &b);
        assert_eq!(stamps.len(), 1);
        assert!(approx(stamps[0].0, 5.0) && approx(stamps[0].1, 5.0));
    }

    #[test]
    fn carry_over_between_pushes() {
        let mut s = Stroke::new();
        let tip = BrushTip::soft_round(8);
        // spacing = 2.0
        let b = Brush::new(tip, [0.0; 4], 0.25);
        let _ = s.push(0.0, 0.0, &b);
        // Move 3 pixels → 1 stamp at x=2.0, carry 1.0.
        let s1 = s.push(3.0, 0.0, &b);
        assert_eq!(s1.len(), 1);
        assert!(approx(s1[0].0, 2.0));
        // Move 5 more pixels (now at x=8.0): spacing remaining was 1.0
        // so first new stamp at x = 4.0, then 6.0, 8.0 → 3 stamps.
        let s2 = s.push(8.0, 0.0, &b);
        assert_eq!(s2.len(), 3);
        assert!(approx(s2[0].0, 4.0));
        assert!(approx(s2[1].0, 6.0));
        assert!(approx(s2[2].0, 8.0));
    }
}
