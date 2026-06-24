// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Document -- canvas dimensions, the layer stack, the active layer, the
// current brush, and stroke state. Stamping is tile-aware: a dab is
// dispatched to every 64x64 tile its footprint overlaps, in tile-local
// coordinates, allocating tiles lazily.

use std::collections::{HashMap, VecDeque};

use paint_core::brush::{Brush, BrushTip, Stroke};
use paint_core::layer::{Layer, LayerId, LayerStack, TileCoord};
use paint_core::render::render_region;
use paint_core::{f16_bits_to_f32, f32_to_f16_bits, Tile, TILE_SCALARS, TILE_SIZE};

use crate::protocol::ToolKind;

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
    hardness: f32,
    stroke: Stroke,
    // The current brush is cached and rebuilt only when the colour,
    // diameter, or hardness changes; rebuilding allocates the tip mask,
    // so it must not happen per stamp on the painting hot path.
    brush: Brush,
    tool: ToolKind,
}

impl Document {
    /// Create a document with one empty layer named "Layer 1".
    pub fn new(width: u32, height: u32) -> Self {
        let mut stack = LayerStack::new();
        let active = stack.push(Layer::new("Layer 1"));
        let colour = [0.0, 0.0, 0.0, 1.0];
        let diameter = 16;
        let hardness = 0.0;
        Self {
            width,
            height,
            stack,
            active,
            colour,
            diameter,
            hardness,
            stroke: Stroke::new(),
            brush: build_brush(diameter, hardness, colour),
            tool: ToolKind::Brush,
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
        self.brush = build_brush(self.diameter, self.hardness, self.colour);
    }

    pub fn set_brush(&mut self, diameter: u32, hardness: f32) {
        self.diameter = diameter.clamp(1, TILE_SIZE);
        self.hardness = hardness;
        self.brush = build_brush(self.diameter, self.hardness, self.colour);
    }

    pub fn set_tool(&mut self, kind: ToolKind) {
        self.tool = kind;
    }

    /// Replace the document contents with the given RGBA8 image. Resets the
    /// layer stack to a single layer named "Layer 1" populated with tiles
    /// converted from the supplied pixel data. Returns a `Rect` covering the
    /// entire canvas so callers can trigger a full repaint.
    pub fn load_png(&mut self, rgba8: &[u8], w: u32, h: u32) -> Rect {
        self.width = w;
        self.height = h;
        self.stack = LayerStack::new();
        let active = self.stack.push(Layer::new("Layer 1"));
        self.active = active;

        let tiles_x = w.div_ceil(TILE_SIZE);
        let tiles_y = h.div_ceil(TILE_SIZE);

        for ty in 0..tiles_y {
            for tx in 0..tiles_x {
                let Some(tile) = Tile::alloc(tx, ty) else {
                    continue;
                };
                let mut buf = [0u16; TILE_SCALARS];
                // Populate the tile buffer from the source RGBA8 pixels.
                for row in 0..TILE_SIZE {
                    let canvas_y = ty * TILE_SIZE + row;
                    for col in 0..TILE_SIZE {
                        let canvas_x = tx * TILE_SIZE + col;
                        // Pixels outside the image bounds stay zero (transparent).
                        if canvas_x >= w || canvas_y >= h {
                            continue;
                        }
                        let src = ((canvas_y * w + canvas_x) * 4) as usize;
                        let dst = ((row * TILE_SIZE + col) * 4) as usize;
                        buf[dst]     = f32_to_f16_bits(rgba8[src]     as f32 / 255.0);
                        buf[dst + 1] = f32_to_f16_bits(rgba8[src + 1] as f32 / 255.0);
                        buf[dst + 2] = f32_to_f16_bits(rgba8[src + 2] as f32 / 255.0);
                        buf[dst + 3] = f32_to_f16_bits(rgba8[src + 3] as f32 / 255.0);
                    }
                }
                let _ = tile.write_buffer(&buf);
                if let Some(layer) = self.stack.get_mut(active) {
                    layer.put_tile(TileCoord::new(tx, ty), tile);
                }
            }
        }

        Rect { x: 0, y: 0, w, h }
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
                    if self.tool == ToolKind::Eraser {
                        let _ = self.brush.erase_stamp(tile, local_cx, local_cy);
                    } else {
                        let _ = self.brush.stamp(tile, local_cx, local_cy);
                    }
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

    /// Flood-fill from `(cx, cy)` with the current colour. Uses a BFS bounded
    /// at 4,000,000 pixels. Returns the union of all modified tile footprints
    /// clamped to the canvas, or a zero rect when nothing was filled.
    pub fn fill_at(&mut self, cx: f32, cy: f32) -> Rect {
        let seed_x = (cx as u32).min(self.width.saturating_sub(1));
        let seed_y = (cy as u32).min(self.height.saturating_sub(1));

        // Read seed colour from tile buffer.
        let seed_colour = self.pixel_rgba8(seed_x, seed_y);

        // Scratch buffers: one [u16; TILE_SCALARS] per touched tile, keyed by
        // (tile_x, tile_y). We read each tile once on first touch and collect
        // all writes, then flush all buffers at the end.
        let mut scratch: HashMap<(u32, u32), [u16; TILE_SCALARS]> = HashMap::new();
        // Tracks which tiles have been touched so we can return their rects.
        let mut touched_tiles: Vec<(u32, u32)> = Vec::new();

        // BFS.
        let mut visited: HashMap<(u32, u32), ()> = HashMap::new();
        let mut queue: VecDeque<(u32, u32)> = VecDeque::new();
        let mut pixel_count: u32 = 0;
        const MAX_PIXELS: u32 = 4_000_000;

        queue.push_back((seed_x, seed_y));
        visited.insert((seed_x, seed_y), ());

        while let Some((px, py)) = queue.pop_front() {
            if pixel_count >= MAX_PIXELS {
                break;
            }

            // Check tolerance against current canvas colour.
            let current = self.pixel_rgba8(px, py);
            if !colours_match(current, seed_colour) {
                continue;
            }

            pixel_count += 1;

            // Write the fill colour into the scratch buffer.
            let tile_x = px / TILE_SIZE;
            let tile_y = py / TILE_SIZE;
            let key = (tile_x, tile_y);

            if !scratch.contains_key(&key) {
                // First touch: read the tile (or zero-initialise if absent).
                let mut buf = [0u16; TILE_SCALARS];
                let active = self.active;
                if let Some(layer) = self.stack.get_mut(active) {
                    let coord = TileCoord::new(tile_x, tile_y);
                    if layer.tile(coord).is_none() {
                        if let Some(tile) = Tile::alloc(tile_x, tile_y) {
                            layer.put_tile(coord, tile);
                        }
                    }
                    if let Some(tile) = layer.tile(coord) {
                        let _ = tile.read_buffer(&mut buf);
                    }
                }
                scratch.insert(key, buf);
                touched_tiles.push(key);
            }

            if let Some(buf) = scratch.get_mut(&key) {
                let local_x = px % TILE_SIZE;
                let local_y = py % TILE_SIZE;
                let idx = ((local_y as usize) * TILE_SIZE as usize + (local_x as usize)) * 4;
                // Write straight-alpha colour as premultiplied f16.
                let a = self.colour[3];
                buf[idx]     = f32_to_f16_bits(self.colour[0] * a);
                buf[idx + 1] = f32_to_f16_bits(self.colour[1] * a);
                buf[idx + 2] = f32_to_f16_bits(self.colour[2] * a);
                buf[idx + 3] = f32_to_f16_bits(a);
            }

            // Enqueue neighbours within canvas bounds.
            let neighbours = [
                (px.wrapping_sub(1), py),
                (px + 1,             py),
                (px,                 py.wrapping_sub(1)),
                (px,                 py + 1),
            ];
            for (nx, ny) in neighbours {
                if nx < self.width && ny < self.height && !visited.contains_key(&(nx, ny)) {
                    visited.insert((nx, ny), ());
                    queue.push_back((nx, ny));
                }
            }
        }

        if touched_tiles.is_empty() {
            return Rect { x: 0, y: 0, w: 0, h: 0 };
        }

        // Flush scratch buffers back to their tiles.
        let active = self.active;
        for &(tile_x, tile_y) in &touched_tiles {
            if let Some(buf) = scratch.get(&(tile_x, tile_y)) {
                let coord = TileCoord::new(tile_x, tile_y);
                if let Some(layer) = self.stack.get_mut(active) {
                    if let Some(tile) = layer.tile(coord) {
                        let _ = tile.write_buffer(buf);
                    }
                }
            }
        }

        // Return the union of all modified tile footprints, clamped to canvas.
        touched_tiles
            .iter()
            .map(|&(tx, ty)| {
                let x = tx * TILE_SIZE;
                let y = ty * TILE_SIZE;
                let w = TILE_SIZE.min(self.width.saturating_sub(x));
                let h = TILE_SIZE.min(self.height.saturating_sub(y));
                Rect { x, y, w, h }
            })
            .filter(|r| r.w > 0 && r.h > 0)
            .reduce(union)
            .unwrap_or(Rect { x: 0, y: 0, w: 0, h: 0 })
    }

    /// Read the RGBA8 colour of a canvas pixel from the tile buffer. Tiles
    /// that do not exist are treated as transparent `[0, 0, 0, 0]`.
    fn pixel_rgba8(&self, px: u32, py: u32) -> [u8; 4] {
        let tile_x = px / TILE_SIZE;
        let tile_y = py / TILE_SIZE;
        let coord = TileCoord::new(tile_x, tile_y);
        // We need an immutable borrow here. `stack.get` returns an immutable
        // reference; we obtain the tile and read its pixel directly.
        let active = self.active;
        if let Some(layer) = self.stack.get(active) {
            if let Some(tile) = layer.tile(coord) {
                let local_x = px % TILE_SIZE;
                let local_y = py % TILE_SIZE;
                if let Ok(bits) = tile.read_pixel_bits(local_x, local_y) {
                    return [
                        (f16_bits_to_f32(bits[0]) * 255.0).round().clamp(0.0, 255.0) as u8,
                        (f16_bits_to_f32(bits[1]) * 255.0).round().clamp(0.0, 255.0) as u8,
                        (f16_bits_to_f32(bits[2]) * 255.0).round().clamp(0.0, 255.0) as u8,
                        (f16_bits_to_f32(bits[3]) * 255.0).round().clamp(0.0, 255.0) as u8,
                    ];
                }
            }
        }
        [0, 0, 0, 0]
    }
}

fn colours_match(a: [u8; 4], b: [u8; 4]) -> bool {
    (a[0] as i16 - b[0] as i16).abs() <= 2
        && (a[1] as i16 - b[1] as i16).abs() <= 2
        && (a[2] as i16 - b[2] as i16).abs() <= 2
        && (a[3] as i16 - b[3] as i16).abs() <= 2
}

fn build_brush(diameter: u32, hardness: f32, colour: [f32; 4]) -> Brush {
    let tip = if hardness >= 0.5 {
        BrushTip::hard_round(diameter)
    } else {
        BrushTip::soft_round(diameter)
    };
    Brush::new(tip, colour, 0.25)
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
