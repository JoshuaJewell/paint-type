// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Ephapax — basic layer model for paint.type.
//
// A `Layer` owns a sparse collection of `Tile`s keyed by `TileCoord`.
// A `LayerStack` is a vertical stack of layers (index 0 = bottom).
// The compositing module (`composite::flatten_layer_stack`) consumes a
// flat per-pixel stack; this module is the structural counterpart that
// names layers, controls visibility / opacity, and orders them.
//
// At v0.1.0 the FFI surface (`pt_layer_*`) is NOT yet defined; this
// module is purely Rust. A follow-up PR will expose `pt_layer_*` exports
// in libpt once the layer model has stabilised. See issue #12.
//
// Invariants:
//   - Each `Layer` owns its `Tile`s linearly (Tile is !Copy, !Clone);
//     a tile can live in at most one Layer at a time.
//   - `LayerStack` indexes are stable across pushes / removes by ID
//     (`LayerId`), not by position. Reorder operations preserve IDs.

use crate::{Tile, TileError};
use std::collections::HashMap;

//==============================================================================
// TileCoord — public, hashable position on the canvas grid
//==============================================================================

/// Position of a tile in the canvas grid, in **tile units** (not pixel
/// units). Mirrors `Abi.Types.TileCoord` on the Idris2 side. Tile (1, 0)
/// starts at pixel (64, 0).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TileCoord {
    /// Horizontal tile index.
    pub x: u32,
    /// Vertical tile index.
    pub y: u32,
}

impl TileCoord {
    /// Construct a new tile coordinate.
    pub const fn new(x: u32, y: u32) -> Self {
        Self { x, y }
    }
}

//==============================================================================
// LayerId — opaque, stable identifier for a layer in a LayerStack
//==============================================================================

/// Stable identifier for a layer within a `LayerStack`. IDs are never
/// reused; deleting a layer permanently retires its ID. This is the
/// piece that makes "the undo graph can refer to a specific layer
/// across reorderings" work.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LayerId(u32);

impl LayerId {
    /// Read the underlying integer (mostly for diagnostics / serialisation).
    pub const fn as_u32(self) -> u32 {
        self.0
    }
}

//==============================================================================
// Layer
//==============================================================================

/// A single layer in a paint.type document.
///
/// Owns its `Tile`s. `opacity` is in `[0.0, 1.0]` and clamped on `set_opacity`.
/// `visible` is a boolean toggle that callers can use to skip layers when
/// flattening; this struct stores the flag but does not enforce it (the
/// renderer / flatten step looks at it).
pub struct Layer {
    /// Human-readable name (no uniqueness requirement; callers can
    /// dedupe if they want).
    pub name: String,
    /// Opacity multiplier applied to this layer's alpha channel when
    /// compositing. `[0.0, 1.0]`. Clamped on `set_opacity`.
    opacity: f32,
    /// Whether the layer participates in compositing.
    pub visible: bool,
    /// Sparse tile map keyed by canvas-grid coordinate.
    tiles: HashMap<TileCoord, Tile>,
}

impl Layer {
    /// Create a new, empty layer with the given name. Defaults: opacity
    /// 1.0, visible.
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            opacity: 1.0,
            visible: true,
            tiles: HashMap::new(),
        }
    }

    /// Current opacity (`0.0..=1.0`).
    pub fn opacity(&self) -> f32 {
        self.opacity
    }

    /// Set opacity. Inputs outside `[0.0, 1.0]` are clamped (NaN → 1.0).
    pub fn set_opacity(&mut self, opacity: f32) {
        self.opacity = if opacity.is_nan() {
            1.0
        } else {
            opacity.clamp(0.0, 1.0)
        };
    }

    /// Read-only access to the tile at `coord`, if any.
    pub fn tile(&self, coord: TileCoord) -> Option<&Tile> {
        self.tiles.get(&coord)
    }

    /// Number of tiles currently in this layer.
    pub fn tile_count(&self) -> usize {
        self.tiles.len()
    }

    /// Iterate over `(coord, &tile)` pairs. Iteration order is
    /// unspecified (`HashMap`); callers that need a stable order must
    /// sort by `TileCoord`.
    pub fn tiles(&self) -> impl Iterator<Item = (TileCoord, &Tile)> {
        self.tiles.iter().map(|(c, t)| (*c, t))
    }

    /// Insert or replace the tile at `coord`. Returns the previous tile
    /// at that position, if any.
    pub fn put_tile(&mut self, coord: TileCoord, tile: Tile) -> Option<Tile> {
        self.tiles.insert(coord, tile)
    }

    /// Remove and return the tile at `coord`, if any.
    pub fn remove_tile(&mut self, coord: TileCoord) -> Option<Tile> {
        self.tiles.remove(&coord)
    }

    /// True iff this layer contains no tiles.
    pub fn is_empty(&self) -> bool {
        self.tiles.is_empty()
    }
}

//==============================================================================
// LayerStack
//==============================================================================

/// A vertical stack of `Layer`s. Index 0 is the bottom; the highest
/// index is on top. `LayerId`s are stable across position changes —
/// callers can hold an ID, reorder the stack arbitrarily, and the ID
/// will still point at the same logical layer.
pub struct LayerStack {
    layers: Vec<Layer>,
    /// Parallel array of IDs; `ids[i]` is the ID of `layers[i]`.
    ids: Vec<LayerId>,
    next_id: u32,
}

/// Errors returned by `LayerStack` operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerStackError {
    /// No layer with the given ID is present.
    UnknownLayer,
    /// `reorder_to` was called with `new_position >= len()`.
    PositionOutOfBounds,
    /// Underlying tile operation failed.
    Tile(TileError),
}

impl From<TileError> for LayerStackError {
    fn from(e: TileError) -> Self {
        LayerStackError::Tile(e)
    }
}

impl Default for LayerStack {
    fn default() -> Self {
        Self::new()
    }
}

impl LayerStack {
    /// Create an empty layer stack.
    pub fn new() -> Self {
        Self {
            layers: Vec::new(),
            ids: Vec::new(),
            next_id: 0,
        }
    }

    /// Number of layers in the stack.
    pub fn len(&self) -> usize {
        self.layers.len()
    }

    /// True iff `len() == 0`.
    pub fn is_empty(&self) -> bool {
        self.layers.is_empty()
    }

    /// Push a layer onto the top of the stack. Returns the new layer's
    /// stable `LayerId`.
    pub fn push(&mut self, layer: Layer) -> LayerId {
        let id = LayerId(self.next_id);
        self.next_id = self.next_id.saturating_add(1);
        self.layers.push(layer);
        self.ids.push(id);
        id
    }

    /// Look up the position of a layer by ID. Returns `None` if no
    /// layer with that ID is in the stack.
    pub fn position_of(&self, id: LayerId) -> Option<usize> {
        self.ids.iter().position(|&i| i == id)
    }

    /// Read-only access to a layer by ID.
    pub fn get(&self, id: LayerId) -> Option<&Layer> {
        self.position_of(id).map(|i| &self.layers[i])
    }

    /// Mutable access to a layer by ID.
    pub fn get_mut(&mut self, id: LayerId) -> Option<&mut Layer> {
        let pos = self.position_of(id)?;
        Some(&mut self.layers[pos])
    }

    /// Read-only access by position (0 = bottom).
    pub fn get_at(&self, position: usize) -> Option<&Layer> {
        self.layers.get(position)
    }

    /// Iterate over layers from bottom to top.
    pub fn iter(&self) -> impl Iterator<Item = (LayerId, &Layer)> {
        self.ids.iter().copied().zip(self.layers.iter())
    }

    /// Delete a layer by ID. Returns the removed layer, or `None` if
    /// the ID was unknown.
    pub fn delete(&mut self, id: LayerId) -> Option<Layer> {
        let pos = self.position_of(id)?;
        self.ids.remove(pos);
        Some(self.layers.remove(pos))
    }

    /// Move a layer to a new position. `new_position` is 0-indexed from
    /// the bottom. Returns the old position on success.
    pub fn reorder_to(
        &mut self,
        id: LayerId,
        new_position: usize,
    ) -> Result<usize, LayerStackError> {
        let old_pos = self.position_of(id).ok_or(LayerStackError::UnknownLayer)?;
        if new_position >= self.layers.len() {
            return Err(LayerStackError::PositionOutOfBounds);
        }
        if old_pos == new_position {
            return Ok(old_pos);
        }
        let layer = self.layers.remove(old_pos);
        let id = self.ids.remove(old_pos);
        self.layers.insert(new_position, layer);
        self.ids.insert(new_position, id);
        Ok(old_pos)
    }

    /// Flatten the stack: for each tile coordinate that appears in any
    /// visible layer, produce the bottom-up composite of the per-tile
    /// stack. Returns a fresh `Layer` named `name` whose tiles are
    /// freshly-allocated composites.
    ///
    /// Layers with `visible == false` or `opacity == 0.0` are skipped.
    /// A NaN opacity is treated as 1.0 (matches `Layer::set_opacity`).
    ///
    /// Errors: returns the first `TileError` produced by an underlying
    /// `Tile::composite_over` call; partial results are dropped.
    pub fn flatten(&self, name: impl Into<String>) -> Result<Layer, LayerStackError> {
        // Collect the set of coords touched by any visible layer.
        let mut coords: Vec<TileCoord> = Vec::new();
        for layer in &self.layers {
            if !layer.visible || layer.opacity == 0.0 {
                continue;
            }
            for (c, _) in layer.tiles() {
                if !coords.contains(&c) {
                    coords.push(c);
                }
            }
        }

        let mut out = Layer::new(name);
        for coord in coords {
            // Composite bottom-up. We can't easily get an owned starting
            // tile; instead we walk visible layers and for each layer that
            // has a tile at `coord`, composite_over the running result.
            let mut acc: Option<Tile> = None;
            for layer in &self.layers {
                if !layer.visible || layer.opacity == 0.0 {
                    continue;
                }
                if let Some(src) = layer.tile(coord) {
                    let new_acc = match acc {
                        None => {
                            // First contributor — allocate a fresh tile and
                            // copy `src` into it (so we own the running
                            // accumulator). Since we don't have a copy-tile
                            // FFI, simulate via composite_over against an
                            // empty (transparent) base.
                            let base = Tile::alloc(coord.x, coord.y)
                                .ok_or(LayerStackError::Tile(TileError::LibError))?;
                            base.composite_over(src)?
                        }
                        Some(running) => running.composite_over(src)?,
                    };
                    acc = Some(new_acc);
                }
            }
            if let Some(tile) = acc {
                out.put_tile(coord, tile);
            }
        }
        Ok(out)
    }
}

//==============================================================================
// Tests
//==============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layer_new_is_empty() {
        let l = Layer::new("background");
        assert_eq!(l.name, "background");
        assert!((l.opacity() - 1.0).abs() < 1e-6);
        assert!(l.visible);
        assert_eq!(l.tile_count(), 0);
        assert!(l.is_empty());
    }

    #[test]
    fn layer_set_opacity_clamps() {
        let mut l = Layer::new("x");
        l.set_opacity(-1.0);
        assert_eq!(l.opacity(), 0.0);
        l.set_opacity(2.0);
        assert_eq!(l.opacity(), 1.0);
        l.set_opacity(0.5);
        assert_eq!(l.opacity(), 0.5);
        l.set_opacity(f32::NAN);
        assert_eq!(l.opacity(), 1.0);
    }

    #[test]
    fn layer_put_remove_tile() {
        let mut l = Layer::new("x");
        let t = Tile::alloc(0, 0).expect("tile alloc");
        let coord = TileCoord::new(0, 0);
        assert!(l.put_tile(coord, t).is_none());
        assert!(l.tile(coord).is_some());
        assert_eq!(l.tile_count(), 1);
        let removed = l.remove_tile(coord);
        assert!(removed.is_some());
        assert!(l.tile(coord).is_none());
    }

    #[test]
    fn layer_put_replace_returns_old() {
        let mut l = Layer::new("x");
        let t1 = Tile::alloc(0, 0).unwrap();
        let t2 = Tile::alloc(0, 0).unwrap();
        let coord = TileCoord::new(0, 0);
        assert!(l.put_tile(coord, t1).is_none());
        let old = l.put_tile(coord, t2);
        assert!(old.is_some(), "first put's tile should be returned");
    }

    #[test]
    fn stack_new_is_empty() {
        let s = LayerStack::new();
        assert_eq!(s.len(), 0);
        assert!(s.is_empty());
    }

    #[test]
    fn stack_push_returns_distinct_ids() {
        let mut s = LayerStack::new();
        let a = s.push(Layer::new("bg"));
        let b = s.push(Layer::new("fg"));
        assert_ne!(a, b);
        assert_eq!(s.len(), 2);
    }

    #[test]
    fn stack_get_by_id_after_reorder() {
        let mut s = LayerStack::new();
        let bg = s.push(Layer::new("bg"));
        let fg = s.push(Layer::new("fg"));
        s.reorder_to(bg, 1).expect("reorder");
        assert_eq!(s.position_of(bg), Some(1));
        assert_eq!(s.position_of(fg), Some(0));
        // Names still match the original IDs.
        assert_eq!(s.get(bg).map(|l| l.name.as_str()), Some("bg"));
        assert_eq!(s.get(fg).map(|l| l.name.as_str()), Some("fg"));
    }

    #[test]
    fn stack_delete_returns_layer_and_removes_id() {
        let mut s = LayerStack::new();
        let id = s.push(Layer::new("doomed"));
        let removed = s.delete(id);
        assert!(removed.is_some());
        assert_eq!(removed.unwrap().name, "doomed");
        assert!(s.get(id).is_none());
        assert!(s.is_empty());
    }

    #[test]
    fn stack_delete_unknown_id_is_none() {
        let mut s = LayerStack::new();
        let _id = s.push(Layer::new("a"));
        // Construct an ID we never issued.
        let fake = LayerId(99_999);
        assert!(s.delete(fake).is_none());
    }

    #[test]
    fn stack_reorder_out_of_bounds_errors() {
        let mut s = LayerStack::new();
        let a = s.push(Layer::new("a"));
        s.push(Layer::new("b"));
        let err = s.reorder_to(a, 99);
        assert_eq!(err, Err(LayerStackError::PositionOutOfBounds));
    }

    #[test]
    fn stack_reorder_unknown_id_errors() {
        let mut s = LayerStack::new();
        s.push(Layer::new("a"));
        let err = s.reorder_to(LayerId(99_999), 0);
        assert_eq!(err, Err(LayerStackError::UnknownLayer));
    }

    #[test]
    fn stack_iter_bottom_up() {
        let mut s = LayerStack::new();
        s.push(Layer::new("bg"));
        s.push(Layer::new("mid"));
        s.push(Layer::new("fg"));
        let names: Vec<&str> = s.iter().map(|(_, l)| l.name.as_str()).collect();
        assert_eq!(names, vec!["bg", "mid", "fg"]);
    }

    #[test]
    fn stack_ids_never_reused() {
        let mut s = LayerStack::new();
        let a = s.push(Layer::new("a"));
        s.delete(a);
        let b = s.push(Layer::new("b"));
        assert_ne!(a, b, "deleted IDs must not be reused");
    }

    #[test]
    fn stack_flatten_skips_invisible_layers() {
        let mut s = LayerStack::new();
        // Bottom: opaque red filled tile at (0,0)
        let mut bg = Layer::new("bg");
        let bg_tile = Tile::alloc(0, 0).unwrap();
        bg_tile.fill_f32(1.0, 0.0, 0.0, 1.0).unwrap();
        bg.put_tile(TileCoord::new(0, 0), bg_tile);
        s.push(bg);
        // Top: opaque blue, but visible=false
        let mut fg = Layer::new("fg");
        fg.visible = false;
        let fg_tile = Tile::alloc(0, 0).unwrap();
        fg_tile.fill_f32(0.0, 0.0, 1.0, 1.0).unwrap();
        fg.put_tile(TileCoord::new(0, 0), fg_tile);
        s.push(fg);

        let flat = s.flatten("flat").expect("flatten");
        let result_tile = flat.tile(TileCoord::new(0, 0)).expect("tile present");
        let pixel = result_tile.read_pixel_f32(0, 0).expect("read pixel");
        assert!(
            (pixel[0] - 1.0).abs() < 1e-2,
            "red preserved when fg invisible"
        );
        assert!(pixel[2].abs() < 1e-2, "no blue contribution");
    }

    #[test]
    fn stack_flatten_skips_zero_opacity_layers() {
        let mut s = LayerStack::new();
        let mut bg = Layer::new("bg");
        let bg_tile = Tile::alloc(0, 0).unwrap();
        bg_tile.fill_f32(1.0, 0.0, 0.0, 1.0).unwrap();
        bg.put_tile(TileCoord::new(0, 0), bg_tile);
        s.push(bg);
        // Top layer with opacity 0 still skipped.
        let mut fg = Layer::new("fg");
        fg.set_opacity(0.0);
        let fg_tile = Tile::alloc(0, 0).unwrap();
        fg_tile.fill_f32(0.0, 0.0, 1.0, 1.0).unwrap();
        fg.put_tile(TileCoord::new(0, 0), fg_tile);
        s.push(fg);

        let flat = s.flatten("flat").expect("flatten");
        let result_tile = flat.tile(TileCoord::new(0, 0)).expect("tile present");
        let pixel = result_tile.read_pixel_f32(0, 0).expect("read pixel");
        assert!((pixel[0] - 1.0).abs() < 1e-2);
        assert!(pixel[2].abs() < 1e-2);
    }
}
