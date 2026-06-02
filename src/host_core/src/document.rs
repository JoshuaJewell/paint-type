// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Document -- canvas dimensions, the layer stack, the active layer, the
// current brush, and stroke state. Stamping is tile-aware: a dab is
// dispatched to every 64x64 tile its footprint overlaps, in tile-local
// coordinates, allocating tiles lazily.

use paint_core::brush::{Brush, BrushTip, Stroke};
use paint_core::layer::{Layer, LayerId, LayerStack, TileCoord};
use paint_core::render::render_region;
use paint_core::{Tile, TILE_SIZE};

/// An axis-aligned dirty rectangle in canvas pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

pub struct Document {
    width: u32,
    height: u32,
    stack: LayerStack,
    active: LayerId,
    colour: [f32; 4],
    diameter: u32,
    stroke: Stroke,
    // The current brush is cached and rebuilt only when the colour or
    // diameter changes; rebuilding allocates the tip mask, so it must not
    // happen per stamp on the painting hot path.
    brush: Brush,
}

impl Document {
    /// Create a document with one empty layer named "Layer 1".
    pub fn new(width: u32, height: u32) -> Self {
        let mut stack = LayerStack::new();
        let active = stack.push(Layer::new("Layer 1"));
        let colour = [0.0, 0.0, 0.0, 1.0];
        let diameter = 16;
        Self {
            width,
            height,
            stack,
            active,
            colour,
            diameter,
            stroke: Stroke::new(),
            brush: build_brush(diameter, colour),
        }
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    pub fn set_colour(&mut self, r: f32, g: f32, b: f32, a: f32) {
        self.colour = [r, g, b, a];
        self.brush = build_brush(self.diameter, self.colour);
    }

    pub fn set_brush(&mut self, diameter: u32) {
        self.diameter = diameter.clamp(1, TILE_SIZE);
        self.brush = build_brush(self.diameter, self.colour);
    }

    /// Stamp the brush at canvas-pixel centre `(cx, cy)`, dispatching to
    /// each overlapped tile. Returns the canvas-pixel bounding rect of
    /// the footprint, clamped to the canvas.
    fn stamp_at(&mut self, cx: f32, cy: f32) -> Rect {
        let half = self.diameter as f32 * 0.5;
        let min_x = (cx - half).floor().max(0.0) as u32;
        let min_y = (cy - half).floor().max(0.0) as u32;
        let max_x = ((cx + half).ceil() as i64).clamp(0, self.width as i64) as u32;
        let max_y = ((cy + half).ceil() as i64).clamp(0, self.height as i64) as u32;

        if max_x <= min_x || max_y <= min_y {
            return Rect { x: 0, y: 0, w: 0, h: 0 };
        }

        let tile_x0 = min_x / TILE_SIZE;
        let tile_y0 = min_y / TILE_SIZE;
        let tile_x1 = (max_x - 1) / TILE_SIZE;
        let tile_y1 = (max_y - 1) / TILE_SIZE;
        let active = self.active;

        for ty in tile_y0..=tile_y1 {
            for tx in tile_x0..=tile_x1 {
                let coord = TileCoord::new(tx, ty);
                // Resolve the active layer once per tile, allocating the
                // tile lazily on first touch.
                let Some(layer) = self.stack.get_mut(active) else {
                    continue;
                };
                if layer.tile(coord).is_none() {
                    let Some(tile) = Tile::alloc(coord.x, coord.y) else {
                        continue;
                    };
                    layer.put_tile(coord, tile);
                }
                if let Some(tile) = layer.tile(coord) {
                    let local_cx = cx - (tx * TILE_SIZE) as f32;
                    let local_cy = cy - (ty * TILE_SIZE) as f32;
                    let _ = self.brush.stamp(tile, local_cx, local_cy);
                }
            }
        }

        Rect {
            x: min_x,
            y: min_y,
            w: max_x - min_x,
            h: max_y - min_y,
        }
    }

    /// Begin a stroke. Resets stroke state and stamps the first dab.
    pub fn pointer_down(&mut self, x: f32, y: f32) -> Rect {
        self.stroke.reset();
        let stamps = self.stroke.push(x, y, &self.brush);
        self.apply_stamps(&stamps)
    }

    /// Continue a stroke. Stamps every interpolated dab since the last
    /// sample and returns the union of their footprints.
    pub fn pointer_move(&mut self, x: f32, y: f32) -> Rect {
        let stamps = self.stroke.push(x, y, &self.brush);
        self.apply_stamps(&stamps)
    }

    fn apply_stamps(&mut self, stamps: &[(f32, f32)]) -> Rect {
        stamps
            .iter()
            .map(|&(cx, cy)| self.stamp_at(cx, cy))
            .filter(|r| r.w > 0 && r.h > 0)
            .reduce(union)
            .unwrap_or(Rect { x: 0, y: 0, w: 0, h: 0 })
    }

    /// Render a canvas rectangle to straight-alpha RGBA8.
    pub fn render(&self, r: Rect) -> Vec<u8> {
        render_region(&self.stack, r.x, r.y, r.w, r.h)
    }

    /// Render the whole canvas (used for save and full repaints).
    pub fn render_all(&self) -> Vec<u8> {
        render_region(&self.stack, 0, 0, self.width, self.height)
    }
}

fn build_brush(diameter: u32, colour: [f32; 4]) -> Brush {
    Brush::new(BrushTip::soft_round(diameter), colour, 0.25)
}

fn union(a: Rect, b: Rect) -> Rect {
    let x0 = a.x.min(b.x);
    let y0 = a.y.min(b.y);
    let x1 = (a.x + a.w).max(b.x + b.w);
    let y1 = (a.y + a.h).max(b.y + b.h);
    Rect {
        x: x0,
        y: y0,
        w: x1 - x0,
        h: y1 - y0,
    }
}
