// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Paint Core -- region renderer: flatten the visible layer stack over a
// rectangle into straight-alpha RGBA8 bytes for display and codecs.

use crate::composite::over_premultiplied;
use crate::layer::{LayerStack, TileCoord};
use crate::{f16_bits_to_f32, f32_to_f16_bits, TILE_SCALARS, TILE_SIZE};
use std::collections::HashMap;

/// Render the rectangle `[ox, ox + w) x [oy, oy + h)` of the visible
/// layer stack into straight-alpha RGBA8, row-major, length `w * h * 4`.
/// Layers are composited bottom-to-top; hidden layers are skipped and
/// each layer's opacity scales its premultiplied contribution.
pub fn render_region(stack: &LayerStack, ox: u32, oy: u32, w: u32, h: u32) -> Vec<u8> {
    let mut out = vec![0u8; (w as usize) * (h as usize) * 4];
    // Cache each touched tile's full buffer so the FFI crossing happens once
    // per tile per layer, not once per pixel (per-pixel reads cost ~13us each).
    let mut cache: HashMap<(usize, TileCoord), Box<[u16; TILE_SCALARS]>> = HashMap::new();

    for row in 0..h {
        for col in 0..w {
            let px = ox + col;
            let py = oy + row;
            let coord = TileCoord::new(px / TILE_SIZE, py / TILE_SIZE);
            let lx = (px % TILE_SIZE) as usize;
            let ly = (py % TILE_SIZE) as usize;
            let pixel_idx = (ly * TILE_SIZE as usize + lx) * 4;

            // Composite visible layers bottom-to-top, keeping the
            // accumulator in premultiplied f16 bits so over_premultiplied
            // (which works in f16) is called without a needless f32 detour.
            let mut acc = [0u16; 4];
            for (li, (_id, layer)) in stack.iter().enumerate() {
                if !layer.visible {
                    continue;
                }
                let Some(tile) = layer.tile(coord) else {
                    continue;
                };
                // Read this tile's buffer once; reuse it for every pixel.
                let buf = cache.entry((li, coord)).or_insert_with(|| {
                    let mut b = Box::new([0u16; TILE_SCALARS]);
                    let _ = tile.read_buffer(&mut b);
                    b
                });
                let bits = [
                    buf[pixel_idx],
                    buf[pixel_idx + 1],
                    buf[pixel_idx + 2],
                    buf[pixel_idx + 3],
                ];
                let opacity = layer.opacity();
                // Scale the premultiplied source by the layer opacity.
                let src = [
                    f32_to_f16_bits(f16_bits_to_f32(bits[0]) * opacity),
                    f32_to_f16_bits(f16_bits_to_f32(bits[1]) * opacity),
                    f32_to_f16_bits(f16_bits_to_f32(bits[2]) * opacity),
                    f32_to_f16_bits(f16_bits_to_f32(bits[3]) * opacity),
                ];
                acc = over_premultiplied(src, acc);
            }

            // Un-premultiply the f16 accumulator to straight alpha, clamp,
            // and quantise to u8.
            let a = f16_bits_to_f32(acc[3]).clamp(0.0, 1.0);
            let (r, g, b) = if a > 0.0 {
                (
                    (f16_bits_to_f32(acc[0]) / a).clamp(0.0, 1.0),
                    (f16_bits_to_f32(acc[1]) / a).clamp(0.0, 1.0),
                    (f16_bits_to_f32(acc[2]) / a).clamp(0.0, 1.0),
                )
            } else {
                (0.0, 0.0, 0.0)
            };
            let base = ((row as usize) * (w as usize) + (col as usize)) * 4;
            out[base] = (r * 255.0 + 0.5) as u8;
            out[base + 1] = (g * 255.0 + 0.5) as u8;
            out[base + 2] = (b * 255.0 + 0.5) as u8;
            out[base + 3] = (a * 255.0 + 0.5) as u8;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layer::Layer;
    use crate::Tile;

    #[test]
    fn empty_stack_renders_transparent() {
        let stack = LayerStack::new();
        let out = render_region(&stack, 0, 0, 2, 2);
        assert_eq!(out, vec![0u8; 2 * 2 * 4]);
    }

    #[test]
    fn single_opaque_pixel_round_trips_to_rgba8() {
        let tile = match Tile::alloc(0, 0) {
            Some(t) => t,
            None => return,
        };
        tile.write_pixel_bits(
            0,
            0,
            f32_to_f16_bits(1.0),
            f32_to_f16_bits(0.0),
            f32_to_f16_bits(0.0),
            f32_to_f16_bits(1.0),
        )
        .expect("write");

        let mut layer = Layer::new("L1");
        layer.put_tile(TileCoord::new(0, 0), tile);
        let mut stack = LayerStack::new();
        stack.push(layer);

        let out = render_region(&stack, 0, 0, 1, 1);
        assert_eq!(out, vec![255, 0, 0, 255]);
    }

    #[test]
    fn hidden_layer_is_skipped() {
        let tile = match Tile::alloc(0, 0) {
            Some(t) => t,
            None => return,
        };
        tile.write_pixel_bits(
            0,
            0,
            f32_to_f16_bits(1.0),
            f32_to_f16_bits(1.0),
            f32_to_f16_bits(1.0),
            f32_to_f16_bits(1.0),
        )
        .expect("write");
        let mut layer = Layer::new("hidden");
        layer.visible = false;
        layer.put_tile(TileCoord::new(0, 0), tile);
        let mut stack = LayerStack::new();
        stack.push(layer);

        let out = render_region(&stack, 0, 0, 1, 1);
        assert_eq!(out, vec![0, 0, 0, 0]);
    }
}
