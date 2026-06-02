# MVP Increment 0: Walking Skeleton Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the first runnable paint.type: a Gossamer window hosting a web canvas, one soft-round brush that paints over the cross-language seam, and PNG save, on Linux.

**Architecture:** A pure `host_core` Rust library owns the document, the command protocol, the dispatch logic, and the PNG codec, depending only on `ephapax` (so it is fully unit-testable with no display). A thin `host` Rust binary wires `host_core` to the `gossamer-rs` webview shell: each JavaScript `__gossamer_invoke(name, payload)` call maps to one `host_core::dispatch` call whose JSON result carries the dirty rectangle back for the web UI to blit. The painting itself reuses the existing `ephapax` brush, layer, and compositing engine; the only new core capability is a region renderer that flattens the visible stack to RGBA8.

**Tech Stack:** Rust (host_core, host), `ephapax` crate (existing), `gossamer-rs` binding (vendored), Zig `libpt` and `libgossamer` (linked), `png` and `base64` crates, vanilla HTML/CSS/JS, `just`, GitHub Actions, `xvfb` for headless CI.

---

## Repository policy note (read before any commit step)

This repository's owner requires explicit, per-action authorisation for **every** git command. Each task below ends with a commit step for TDD discipline, but the executor MUST obtain the owner's explicit permission before running any `git` command, including `git add` and `git commit`. Do not run git unprompted, and do not pass git instructions to a subagent without that permission. If permission is withheld, complete the code and tests and leave the commit for the owner.

## Prerequisite system packages (Linux)

The `gossamer-rs` `build.rs` links `gtk-3`, `gdk-3`, and `webkit2gtk-4.1`. Install before Task 1:

```bash
sudo apt-get update
sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.1-dev pkg-config zig
```

Expected: all packages install without error. Confirm Zig 0.15+ with `zig version`.

## File structure (what each new file is responsible for)

- Create: `third_party/gossamer/` — vendored Gossamer (git submodule); source of `libgossamer` and the `gossamer-rs` crate.
- Create: `src/paint_core/src/render.rs` — `render_region`: flatten the visible layer stack over a rectangle into straight-alpha RGBA8 bytes. One responsibility: pixels out.
- Modify: `src/paint_core/src/lib.rs` — add `pub mod render;`.
- Create: `src/host_core/Cargo.toml`, `src/host_core/src/lib.rs` — pure library crate root.
- Create: `src/host_core/src/protocol.rs` — `Command` and `Response` serde types (the wire contract).
- Create: `src/host_core/src/document.rs` — `Document`: canvas state, brush state, stroke handling, tile-aware stamping, dirty tracking.
- Create: `src/host_core/src/dispatch.rs` — `dispatch(&mut Document, Command) -> Response`: the single entry point the GUI calls.
- Create: `src/host_core/src/codec.rs` — `save_png`: encode an RGBA8 buffer to a PNG file (and decode for round-trip tests).
- Create: `src/host/Cargo.toml`, `src/host/src/main.rs` — the Gossamer binary; maps invoke names to `dispatch`.
- Create: `src/ui/index.html`, `src/ui/style.css`, `src/ui/app.js` — the web front end (canvas, tool bar, blit loop).
- Modify: `Justfile` — build/run/test the new crates; add `run` that launches the host.
- Create: `tests/e2e/scenario_host_headless.sh` — boot-and-save smoke under `xvfb`.
- Modify: `tests/e2e.sh` — invoke the new scenario.
- Create: `.github/workflows/host.yml` — build host + run host_core tests + headless e2e on Linux.

The numeric contract used throughout: tiles are 64x64 (`ephapax::TILE_SIZE`), pixels are RGBA stored as four f16 bit patterns, premultiplied inside tiles. The canvas grid maps pixel `(px, py)` to tile `(px / 64, py / 64)` at tile-local `(px % 64, py % 64)`, exactly as `TileCoord` documents.

---

### Task 1: Vendor Gossamer and build libgossamer

**Files:**
- Create: `third_party/gossamer/` (git submodule)

- [ ] **Step 1: Add Gossamer as a submodule** (requires owner git authorisation)

```bash
git submodule add https://github.com/hyperpolymath/gossamer third_party/gossamer
git -C third_party/gossamer checkout v0.3.1
```

Expected: `third_party/gossamer/bindings/rust/Cargo.toml` exists.

- [ ] **Step 2: Build the Gossamer Zig FFI to produce libgossamer**

Run:
```bash
cd third_party/gossamer/src/interface/ffi && zig build
```
Expected: `third_party/gossamer/src/interface/ffi/zig-out/lib/libgossamer.a` (or `.so`) exists. This is the path `gossamer-rs/build.rs` searches (`../../src/interface/ffi/zig-out/lib`).

- [ ] **Step 3: Smoke-link the binding**

Create a throwaway check that the Rust binding links. Run:
```bash
cargo new --bin /tmp/gsmoke
cd /tmp/gsmoke
cat >> Cargo.toml <<'EOF'
gossamer-rs = { path = "REPO_ROOT/third_party/gossamer/bindings/rust" }
EOF
cat > src/main.rs <<'EOF'
fn main() { println!("gossamer {}", gossamer_rs::version()); }
EOF
cargo run
```
Replace `REPO_ROOT` with the absolute path to this repository. Expected: prints a version string such as `gossamer 0.3.1` with no link errors. If linking fails on `webkit2gtk-4.1`, confirm the prerequisite packages installed.

- [ ] **Step 4: Record the submodule** (requires owner git authorisation)

```bash
git add .gitmodules third_party/gossamer
git commit -m "build: vendor gossamer v0.3.1 as submodule for the desktop shell"
```

---

### Task 2: `render_region` in ephapax

**Files:**
- Create: `src/paint_core/src/render.rs`
- Modify: `src/paint_core/src/lib.rs` (add `pub mod render;`)
- Test: inline `#[cfg(test)]` in `render.rs`

- [ ] **Step 1: Write the failing test**

Create `src/paint_core/src/render.rs` with only the test module and a stub:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Ephapax — region renderer: flatten the visible layer stack over a
// rectangle into straight-alpha RGBA8 bytes for display and codecs.

use crate::composite::over_premultiplied;
use crate::layer::{LayerStack, TileCoord};
use crate::{f16_bits_to_f32, f32_to_f16_bits, Tile, TILE_SIZE};

/// Render the rectangle `[ox, ox + w) x [oy, oy + h)` of the visible
/// layer stack into straight-alpha RGBA8, row-major, length `w * h * 4`.
/// Layers are composited bottom-to-top; hidden layers are skipped and
/// each layer's opacity scales its premultiplied contribution.
pub fn render_region(stack: &LayerStack, ox: u32, oy: u32, w: u32, h: u32) -> Vec<u8> {
    unimplemented!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layer::Layer;

    #[test]
    fn empty_stack_renders_transparent() {
        let stack = LayerStack::new();
        let out = render_region(&stack, 0, 0, 2, 2);
        assert_eq!(out, vec![0u8; 2 * 2 * 4]);
    }

    #[test]
    fn single_opaque_pixel_round_trips_to_rgba8() {
        // A tile with one opaque red pixel at tile-local (0,0) must
        // render as (255,0,0,255) at canvas (0,0).
        let tile = match Tile::alloc(0, 0) {
            Some(t) => t,
            None => return, // libpt unavailable in this environment
        };
        // Premultiplied opaque red: r=1, g=0, b=0, a=1.
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
```

Add `pub mod render;` to `src/paint_core/src/lib.rs` next to the other `pub mod` declarations.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test --manifest-path src/paint_core/Cargo.toml render::`
Expected: FAIL — `not implemented` panic from `unimplemented!()` (or the empty-stack test fails first).

- [ ] **Step 3: Implement `render_region`**

Replace the body of `render_region`:

```rust
pub fn render_region(stack: &LayerStack, ox: u32, oy: u32, w: u32, h: u32) -> Vec<u8> {
    let mut out = vec![0u8; (w as usize) * (h as usize) * 4];

    for row in 0..h {
        for col in 0..w {
            let px = ox + col;
            let py = oy + row;
            let coord = TileCoord::new(px / TILE_SIZE, py / TILE_SIZE);
            let lx = px % TILE_SIZE;
            let ly = py % TILE_SIZE;

            // Composite visible layers bottom-to-top in premultiplied space.
            let mut acc = [0.0_f32; 4];
            for (_id, layer) in stack.iter() {
                if !layer.visible {
                    continue;
                }
                let Some(tile) = layer.tile(coord) else {
                    continue;
                };
                let Ok(bits) = tile.read_pixel_bits(lx, ly) else {
                    continue;
                };
                let opacity = layer.opacity();
                let src = [
                    f16_bits_to_f32(bits[0]) * opacity,
                    f16_bits_to_f32(bits[1]) * opacity,
                    f16_bits_to_f32(bits[2]) * opacity,
                    f16_bits_to_f32(bits[3]) * opacity,
                ];
                // over_premultiplied takes f16 bit patterns; convert,
                // composite, convert back to keep the accumulator in f32.
                let src_bits = [
                    f32_to_f16_bits(src[0]),
                    f32_to_f16_bits(src[1]),
                    f32_to_f16_bits(src[2]),
                    f32_to_f16_bits(src[3]),
                ];
                let acc_bits = [
                    f32_to_f16_bits(acc[0]),
                    f32_to_f16_bits(acc[1]),
                    f32_to_f16_bits(acc[2]),
                    f32_to_f16_bits(acc[3]),
                ];
                let blended = over_premultiplied(src_bits, acc_bits);
                acc = [
                    f16_bits_to_f32(blended[0]),
                    f16_bits_to_f32(blended[1]),
                    f16_bits_to_f32(blended[2]),
                    f16_bits_to_f32(blended[3]),
                ];
            }

            // Un-premultiply to straight alpha, clamp, quantise to u8.
            let a = acc[3].clamp(0.0, 1.0);
            let (r, g, b) = if a > 0.0 {
                (
                    (acc[0] / a).clamp(0.0, 1.0),
                    (acc[1] / a).clamp(0.0, 1.0),
                    (acc[2] / a).clamp(0.0, 1.0),
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path src/paint_core/Cargo.toml render::`
Expected: PASS (3 tests; the libpt-dependent two are no-ops only if libpt is unavailable, which it is not in CI).

- [ ] **Step 5: Verify the whole crate still passes**

Run: `cargo test --manifest-path src/paint_core/Cargo.toml`
Expected: the existing 98 tests plus the new render tests all PASS.

- [ ] **Step 6: Commit** (requires owner git authorisation)

```bash
git add src/paint_core/src/render.rs src/paint_core/src/lib.rs
git commit -m "feat(ephapax): add render_region to flatten the visible stack to RGBA8"
```

---

### Task 3: `host_core` crate — protocol, document, dispatch

**Files:**
- Create: `src/host_core/Cargo.toml`
- Create: `src/host_core/src/lib.rs`
- Create: `src/host_core/src/protocol.rs`
- Create: `src/host_core/src/document.rs`
- Create: `src/host_core/src/dispatch.rs`
- Test: inline `#[cfg(test)]` in `dispatch.rs`

- [ ] **Step 1: Create the crate manifest and root**

Create `src/host_core/Cargo.toml`:

```toml
# SPDX-License-Identifier: PMPL-1.0-or-later
[package]
name = "host_core"
version = "0.1.0"
edition = "2021"
license = "PMPL-1.0-or-later"

[lib]
path = "src/lib.rs"

[dependencies]
ephapax = { path = "../ephapax" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
base64 = "0.22"
png = "0.17"
```

Create `src/host_core/src/lib.rs`:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
//
// host_core — the display-independent heart of the paint.type desktop
// shell: the command protocol, the document model, the dispatch entry
// point, and the PNG codec. Depends only on ephapax, so the whole seam
// is unit-testable with no window and no WebKitGTK.

pub mod codec;
pub mod dispatch;
pub mod document;
pub mod protocol;
```

- [ ] **Step 2: Define the wire protocol**

Create `src/host_core/src/protocol.rs`:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
//
// The command/response contract between the web UI and the core. Each
// inbound JavaScript __gossamer_invoke maps to one Command; the Response
// is serialised straight back as the invoke's resolved value.

use serde::{Deserialize, Serialize};

/// A rectangle of freshly composited pixels the UI must blit.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DirtyRect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    /// base64 of `w * h * 4` straight-alpha RGBA8 bytes.
    pub rgba_base64: String,
}

/// Inbound commands. `#[serde(tag = "cmd")]` lets the UI send
/// `{"cmd":"pointer_down","x":10,"y":20}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    NewDoc { w: u32, h: u32 },
    SetColour { r: f32, g: f32, b: f32, a: f32 },
    SetBrush { diameter: u32 },
    PointerDown { x: f32, y: f32 },
    PointerMove { x: f32, y: f32 },
    PointerUp,
    SavePng { path: String },
}

/// Outbound responses, serialised as the invoke result.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "ok", rename_all = "snake_case")]
pub enum Response {
    /// Acknowledged, no pixels changed.
    Ack,
    /// One dirty rectangle to blit.
    Painted { dirty: DirtyRect },
    /// A file was written.
    Saved { path: String },
    /// Something failed; `message` is human-readable.
    Error { message: String },
}
```

- [ ] **Step 3: Write the failing dispatch test**

Create `src/host_core/src/dispatch.rs` with the entry point stubbed and the tests present:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
//
// dispatch — the single function the GUI calls. Pure: Document in,
// Response out, no I/O except SavePng which writes a file.

use crate::document::Document;
use crate::protocol::{Command, Response};

/// Apply one command to the document, returning the response to hand
/// back to the web UI. `doc` is `None` until the first NewDoc.
pub fn dispatch(doc: &mut Option<Document>, cmd: Command) -> Response {
    unimplemented!()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Command, Response};
    use base64::Engine;

    fn decode(dirty_b64: &str) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD
            .decode(dirty_b64)
            .expect("valid base64")
    }

    #[test]
    fn new_doc_then_stroke_paints_non_transparent_pixels() {
        let mut doc: Option<Document> = None;

        assert_eq!(
            dispatch(&mut doc, Command::NewDoc { w: 128, h: 128 }),
            Response::Ack
        );
        // Opaque red, diameter 16.
        assert_eq!(
            dispatch(
                &mut doc,
                Command::SetColour { r: 1.0, g: 0.0, b: 0.0, a: 1.0 }
            ),
            Response::Ack
        );
        assert_eq!(
            dispatch(&mut doc, Command::SetBrush { diameter: 16 }),
            Response::Ack
        );

        let down = dispatch(&mut doc, Command::PointerDown { x: 32.0, y: 32.0 });
        let Response::Painted { dirty } = down else {
            panic!("expected Painted, got {down:?}");
        };
        // The dirty rect must contain at least one fully opaque pixel.
        let bytes = decode(&dirty.rgba_base64);
        assert_eq!(bytes.len() as u32, dirty.w * dirty.h * 4);
        let has_opaque = bytes.chunks_exact(4).any(|p| p[3] == 255 && p[0] > 200);
        assert!(has_opaque, "expected an opaque red pixel in the dab");

        assert_eq!(dispatch(&mut doc, Command::PointerUp), Response::Ack);
    }

    #[test]
    fn commands_before_new_doc_error() {
        let mut doc: Option<Document> = None;
        let r = dispatch(&mut doc, Command::PointerDown { x: 1.0, y: 1.0 });
        assert!(matches!(r, Response::Error { .. }));
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cargo test --manifest-path src/host_core/Cargo.toml dispatch::`
Expected: FAIL — `not implemented` panic (the document module does not exist yet, so this will not even compile until Step 5). Compilation failure counts as a failing test here; proceed to Step 5.

- [ ] **Step 5: Implement the document model**

Create `src/host_core/src/document.rs`:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Document — canvas dimensions, the layer stack, the active layer, the
// current brush, and stroke state. Stamping is tile-aware: a dab is
// dispatched to every 64x64 tile its footprint overlaps, in tile-local
// coordinates, allocating tiles lazily.

use ephapax::brush::{Brush, BrushTip, Stroke};
use ephapax::layer::{Layer, LayerId, LayerStack, TileCoord};
use ephapax::render::render_region;
use ephapax::{Tile, TILE_SIZE};

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
}

impl Document {
    /// Create a document with one empty layer named "Layer 1".
    pub fn new(width: u32, height: u32) -> Self {
        let mut stack = LayerStack::new();
        let active = stack.push(Layer::new("Layer 1"));
        Self {
            width,
            height,
            stack,
            active,
            colour: [0.0, 0.0, 0.0, 1.0],
            diameter: 16,
            stroke: Stroke::new(),
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
    }

    pub fn set_brush(&mut self, diameter: u32) {
        self.diameter = diameter.clamp(1, TILE_SIZE);
    }

    fn brush(&self) -> Brush {
        let tip = BrushTip::soft_round(self.diameter);
        Brush::new(tip, self.colour, 0.25)
    }

    /// Ensure a tile exists at `coord` in the active layer, returning a
    /// shared reference. Returns None only if libpt allocation fails.
    fn ensure_tile(&mut self, coord: TileCoord) -> Option<()> {
        let layer = self.stack.get_mut(self.active)?;
        if layer.tile(coord).is_none() {
            let tile = Tile::alloc(coord.x, coord.y)?;
            layer.put_tile(coord, tile);
        }
        Some(())
    }

    /// Stamp the brush at canvas-pixel centre `(cx, cy)`, dispatching to
    /// each overlapped tile. Returns the canvas-pixel bounding rect of
    /// the footprint, clamped to the canvas.
    fn stamp_at(&mut self, cx: f32, cy: f32) -> Rect {
        let brush = self.brush();
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

        for ty in tile_y0..=tile_y1 {
            for tx in tile_x0..=tile_x1 {
                let coord = TileCoord::new(tx, ty);
                if self.ensure_tile(coord).is_none() {
                    continue;
                }
                let layer = match self.stack.get_mut(self.active) {
                    Some(l) => l,
                    None => continue,
                };
                if let Some(tile) = layer.tile(coord) {
                    let local_cx = cx - (tx * TILE_SIZE) as f32;
                    let local_cy = cy - (ty * TILE_SIZE) as f32;
                    let _ = brush.stamp(tile, local_cx, local_cy);
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
        let brush = self.brush();
        let stamps = self.stroke.push(x, y, &brush);
        self.apply_stamps(&stamps)
    }

    /// Continue a stroke. Stamps every interpolated dab since the last
    /// sample and returns the union of their footprints.
    pub fn pointer_move(&mut self, x: f32, y: f32) -> Rect {
        let brush = self.brush();
        let stamps = self.stroke.push(x, y, &brush);
        self.apply_stamps(&stamps)
    }

    fn apply_stamps(&mut self, stamps: &[(f32, f32)]) -> Rect {
        let mut acc: Option<Rect> = None;
        for &(cx, cy) in stamps {
            let r = self.stamp_at(cx, cy);
            if r.w == 0 || r.h == 0 {
                continue;
            }
            acc = Some(match acc {
                None => r,
                Some(a) => union(a, r),
            });
        }
        acc.unwrap_or(Rect { x: 0, y: 0, w: 0, h: 0 })
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
```

This requires `ephapax`'s modules to be public. Confirm `src/paint_core/src/lib.rs` declares `pub mod brush;`, `pub mod layer;`, `pub mod composite;`, and (from Task 2) `pub mod render;`, and that `Tile`, `TileError`, `TILE_SIZE`, `f16_bits_to_f32`, `f32_to_f16_bits` are `pub`. They are already used across modules, so they are public; if any module is declared `mod` rather than `pub mod`, change it to `pub mod` in this step and note it in the commit.

- [ ] **Step 6: Implement dispatch**

Replace the `dispatch` body in `src/host_core/src/dispatch.rs`:

```rust
pub fn dispatch(doc: &mut Option<Document>, cmd: Command) -> Response {
    use base64::Engine;

    if let Command::NewDoc { w, h } = cmd {
        *doc = Some(Document::new(w, h));
        return Response::Ack;
    }

    let Some(document) = doc.as_mut() else {
        return Response::Error {
            message: "no document; send new_doc first".to_string(),
        };
    };

    match cmd {
        Command::NewDoc { .. } => unreachable!("handled above"),
        Command::SetColour { r, g, b, a } => {
            document.set_colour(r, g, b, a);
            Response::Ack
        }
        Command::SetBrush { diameter } => {
            document.set_brush(diameter);
            Response::Ack
        }
        Command::PointerDown { x, y } => paint(document, document_pointer_down(document, x, y)),
        Command::PointerMove { x, y } => paint(document, document_pointer_move(document, x, y)),
        Command::PointerUp => Response::Ack,
        Command::SavePng { path } => {
            let rgba = document.render_all();
            match crate::codec::save_png(&path, &rgba, document.width(), document.height()) {
                Ok(()) => Response::Saved { path },
                Err(e) => Response::Error { message: e },
            }
        }
    }
}

// Small shims so the match arms above read cleanly; they exist because we
// cannot borrow `document` mutably twice in one expression.
fn document_pointer_down(doc: &mut Document, x: f32, y: f32) -> crate::document::Rect {
    doc.pointer_down(x, y)
}
fn document_pointer_move(doc: &mut Document, x: f32, y: f32) -> crate::document::Rect {
    doc.pointer_move(x, y)
}

fn paint(doc: &Document, rect: crate::document::Rect) -> Response {
    use base64::Engine;
    if rect.w == 0 || rect.h == 0 {
        return Response::Ack;
    }
    let rgba = doc.render(rect);
    let rgba_base64 = base64::engine::general_purpose::STANDARD.encode(&rgba);
    Response::Painted {
        dirty: crate::protocol::DirtyRect {
            x: rect.x,
            y: rect.y,
            w: rect.w,
            h: rect.h,
            rgba_base64,
        },
    }
}
```

Note: the `paint(document, document_pointer_down(document, ...))` form borrows `document` mutably for the inner call, which completes before `paint` borrows it immutably, so it compiles. If the borrow checker objects, split into two statements: `let r = document.pointer_down(x, y); paint(document, r)`.

- [ ] **Step 7: Run the dispatch tests to verify they pass**

Run: `cargo test --manifest-path src/host_core/Cargo.toml`
Expected: PASS — `new_doc_then_stroke_paints_non_transparent_pixels` and `commands_before_new_doc_error`.

- [ ] **Step 8: Commit** (requires owner git authorisation)

```bash
git add src/host_core
git commit -m "feat(host_core): protocol, document, and dispatch for the brush seam"
```

---

### Task 4: PNG codec in host_core

**Files:**
- Create: `src/host_core/src/codec.rs`
- Test: inline `#[cfg(test)]` in `codec.rs`

- [ ] **Step 1: Write the failing test**

Create `src/host_core/src/codec.rs`:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
//
// codec — PNG encode/decode for straight-alpha RGBA8 buffers. Decode is
// bounded by MAX_DIM to contain the decoder attack surface.

/// Maximum width or height accepted on decode (guards against
/// decompression-bomb dimensions).
pub const MAX_DIM: u32 = 16_384;

/// Encode `rgba` (length `w * h * 4`, straight alpha) to a PNG file.
pub fn save_png(path: &str, rgba: &[u8], w: u32, h: u32) -> Result<(), String> {
    unimplemented!()
}

/// Decode a PNG file into `(rgba, w, h)`, rejecting oversized images.
pub fn load_png(path: &str) -> Result<(Vec<u8>, u32, u32), String> {
    unimplemented!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_preserves_pixels() {
        let w = 3;
        let h = 2;
        let src: Vec<u8> = (0..(w * h * 4) as u8).collect();
        let path = std::env::temp_dir().join("pt_codec_roundtrip.png");
        let path = path.to_str().unwrap();

        save_png(path, &src, w, h).expect("save");
        let (out, ow, oh) = load_png(path).expect("load");
        assert_eq!((ow, oh), (w, h));
        assert_eq!(out, src);
    }

    #[test]
    fn save_rejects_wrong_length() {
        let r = save_png("/tmp/unused.png", &[0, 0, 0], 10, 10);
        assert!(r.is_err());
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test --manifest-path src/host_core/Cargo.toml codec::`
Expected: FAIL — `not implemented`.

- [ ] **Step 3: Implement the codec**

Replace the two function bodies:

```rust
pub fn save_png(path: &str, rgba: &[u8], w: u32, h: u32) -> Result<(), String> {
    let expected = (w as usize) * (h as usize) * 4;
    if rgba.len() != expected {
        return Err(format!(
            "buffer length {} does not match {}x{}x4 = {}",
            rgba.len(),
            w,
            h,
            expected
        ));
    }
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let writer = std::io::BufWriter::new(file);
    let mut encoder = png::Encoder::new(writer, w, h);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(rgba).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn load_png(path: &str) -> Result<(Vec<u8>, u32, u32), String> {
    let file = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let decoder = png::Decoder::new(std::io::BufReader::new(file));
    let mut reader = decoder.read_info().map_err(|e| e.to_string())?;
    let info = reader.info();
    if info.width > MAX_DIM || info.height > MAX_DIM {
        return Err(format!(
            "image {}x{} exceeds MAX_DIM {}",
            info.width, info.height, MAX_DIM
        ));
    }
    let mut buf = vec![0u8; reader.output_buffer_size()];
    let frame = reader.next_frame(&mut buf).map_err(|e| e.to_string())?;
    let w = frame.width;
    let h = frame.height;
    buf.truncate(frame.buffer_size());
    // Normalise to RGBA8 regardless of source colour type.
    let rgba = match frame.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => {
            let mut out = Vec::with_capacity((w * h * 4) as usize);
            for px in buf.chunks_exact(3) {
                out.extend_from_slice(&[px[0], px[1], px[2], 255]);
            }
            out
        }
        other => return Err(format!("unsupported colour type {other:?}")),
    };
    Ok((rgba, w, h))
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path src/host_core/Cargo.toml codec::`
Expected: PASS — both tests.

- [ ] **Step 5: Run the full host_core suite**

Run: `cargo test --manifest-path src/host_core/Cargo.toml`
Expected: dispatch and codec tests all PASS.

- [ ] **Step 6: Commit** (requires owner git authorisation)

```bash
git add src/host_core/src/codec.rs
git commit -m "feat(host_core): bounded PNG encode/decode for save and load"
```

---

### Task 5: `host` binary — Gossamer wiring

**Files:**
- Create: `src/host/Cargo.toml`
- Create: `src/host/src/main.rs`

This task is integration glue verified by a smoke run, not by unit tests; the logic it calls is already tested in Task 3.

- [ ] **Step 1: Create the binary manifest**

Create `src/host/Cargo.toml`:

```toml
# SPDX-License-Identifier: PMPL-1.0-or-later
[package]
name = "host"
version = "0.1.0"
edition = "2021"
license = "PMPL-1.0-or-later"

[[bin]]
name = "paint-type"
path = "src/main.rs"

[dependencies]
host_core = { path = "../host_core" }
gossamer-rs = { path = "../../third_party/gossamer/bindings/rust" }
serde_json = "1"
```

- [ ] **Step 2: Write main.rs**

Create `src/host/src/main.rs`:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
//
// paint-type desktop host. Boots a Gossamer window, loads the bundled
// web UI, and registers one IPC command per protocol message. Each
// __gossamer_invoke("dispatch", payload) call deserialises a Command,
// runs host_core::dispatch against the shared document, and returns the
// Response as JSON for the web UI to act on.

use gossamer_rs::App;
use host_core::dispatch::dispatch;
use host_core::document::Document;
use host_core::protocol::Command;
use std::sync::{Arc, Mutex};

fn main() -> Result<(), gossamer_rs::Error> {
    let mut app = App::new("paint.type", 1024, 768)?;

    // Shared document, guarded for the Send + 'static handler.
    let doc: Arc<Mutex<Option<Document>>> = Arc::new(Mutex::new(None));

    let doc_for_cmd = Arc::clone(&doc);
    app.command("dispatch", move |payload| {
        let cmd: Command = serde_json::from_value(payload)
            .map_err(|e| format!("bad command: {e}"))?;
        let mut guard = doc_for_cmd.lock().map_err(|_| "document lock poisoned".to_string())?;
        let response = dispatch(&mut guard, cmd);
        serde_json::to_value(&response).map_err(|e| e.to_string())
    });

    // Lock the webview down to its own origin plus inline UI script.
    app.set_csp("default-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'")?;

    // Load the bundled UI. The HTML inlines its CSS and JS so a single
    // load_html call is self-contained (no asset server needed for the
    // skeleton). UI_HTML is produced at build time from src/ui/.
    app.load_html(UI_HTML)?;

    app.run();
    Ok(())
}

// The UI is embedded at compile time. After Task 6 creates src/ui/, this
// include path resolves; the build step in Task 7 keeps index.html as the
// single self-contained document.
const UI_HTML: &str = include_str!("../../ui/index.html");
```

- [ ] **Step 3: Build the binary** (after Task 6 has created `src/ui/index.html`; if running tasks in order, create a one-line placeholder `src/ui/index.html` containing `<!doctype html><title>paint.type</title>` first so this compiles, then Task 6 fills it in)

Run:
```bash
cargo build --manifest-path src/host/Cargo.toml
```
Expected: links against `libgossamer`, `host_core`, and `ephapax`/`libpt` with no errors. If the link fails on `libpt`, ensure `just build` has been run so `src/interface/ffi/zig-out/lib/libpt.*` exists; if it fails on `libgossamer`, ensure Task 1 Step 2 built it.

- [ ] **Step 4: Commit** (requires owner git authorisation)

```bash
git add src/host
git commit -m "feat(host): gossamer binary wiring invoke->dispatch with a shared document"
```

---

### Task 6: Web UI

**Files:**
- Create: `src/ui/index.html` (self-contained: inlines CSS and JS)
- Create: `src/ui/style.css` (source of truth; copied inline by the build step)
- Create: `src/ui/app.js` (source of truth; copied inline by the build step)

For the skeleton the shipped artifact is a single `index.html` with inline `<style>` and `<script>`; `style.css` and `app.js` are kept as readable sources. Keep them in sync by hand for increment 0 (a build step to inline them is deferred to increment 1).

- [ ] **Step 1: Create index.html**

Create `src/ui/index.html`:

```html
<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<title>paint.type</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; font-family: system-ui, sans-serif; background: #1e1e1e; color: #ddd; display: flex; height: 100vh; }
  #toolbar { width: 200px; padding: 12px; background: #252526; display: flex; flex-direction: column; gap: 10px; }
  #toolbar label { display: flex; flex-direction: column; font-size: 12px; gap: 4px; }
  #stage { flex: 1; display: grid; place-items: center; overflow: auto; }
  #canvas { background: #fff; box-shadow: 0 0 0 1px #000, 0 8px 24px rgba(0,0,0,.5); image-rendering: pixelated; cursor: crosshair; }
  button { padding: 6px 10px; background: #0e639c; color: #fff; border: 0; border-radius: 3px; cursor: pointer; }
  #status { font-size: 11px; color: #888; min-height: 14px; }
</style>
</head>
<body>
  <div id="toolbar">
    <strong>paint.type</strong>
    <label>Colour <input id="colour" type="color" value="#cc0000"></label>
    <label>Brush size <input id="size" type="range" min="1" max="64" value="16"></label>
    <button id="save">Save PNG…</button>
    <div id="status"></div>
  </div>
  <div id="stage"><canvas id="canvas" width="1024" height="768"></canvas></div>
<script>
(function () {
  "use strict";
  const canvas = document.getElementById("canvas");
  const ctx = canvas.getContext("2d");
  const status = document.getElementById("status");
  const DOC_W = canvas.width, DOC_H = canvas.height;

  function invoke(payload) {
    if (!window.__gossamer_invoke) {
      return Promise.reject(new Error("Gossamer runtime unavailable"));
    }
    return window.__gossamer_invoke("dispatch", payload);
  }

  function hexToRgba(hex) {
    const r = parseInt(hex.slice(1, 3), 16) / 255;
    const g = parseInt(hex.slice(3, 5), 16) / 255;
    const b = parseInt(hex.slice(5, 7), 16) / 255;
    return { r, g, b, a: 1.0 };
  }

  function blit(dirty) {
    if (!dirty) return;
    const bin = atob(dirty.rgba_base64);
    const bytes = new Uint8ClampedArray(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const img = new ImageData(bytes, dirty.w, dirty.h);
    ctx.putImageData(img, dirty.x, dirty.y);
  }

  function canvasPos(ev) {
    const rect = canvas.getBoundingClientRect();
    return {
      x: (ev.clientX - rect.left) * (DOC_W / rect.width),
      y: (ev.clientY - rect.top) * (DOC_H / rect.height)
    };
  }

  async function boot() {
    await invoke({ cmd: "new_doc", w: DOC_W, h: DOC_H });
    const c = hexToRgba(document.getElementById("colour").value);
    await invoke({ cmd: "set_colour", r: c.r, g: c.g, b: c.b, a: c.a });
    await invoke({ cmd: "set_brush", diameter: Number(document.getElementById("size").value) });
    status.textContent = "Ready.";
  }

  document.getElementById("colour").addEventListener("input", (e) => {
    const c = hexToRgba(e.target.value);
    invoke({ cmd: "set_colour", r: c.r, g: c.g, b: c.b, a: c.a });
  });
  document.getElementById("size").addEventListener("input", (e) => {
    invoke({ cmd: "set_brush", diameter: Number(e.target.value) });
  });

  let painting = false;
  canvas.addEventListener("pointerdown", async (ev) => {
    painting = true;
    canvas.setPointerCapture(ev.pointerId);
    const p = canvasPos(ev);
    const res = await invoke({ cmd: "pointer_down", x: p.x, y: p.y });
    if (res && res.ok === "painted") blit(res.dirty);
  });
  canvas.addEventListener("pointermove", async (ev) => {
    if (!painting) return;
    const p = canvasPos(ev);
    const res = await invoke({ cmd: "pointer_move", x: p.x, y: p.y });
    if (res && res.ok === "painted") blit(res.dirty);
  });
  canvas.addEventListener("pointerup", async (ev) => {
    painting = false;
    await invoke({ cmd: "pointer_up" });
  });

  document.getElementById("save").addEventListener("click", async () => {
    let path = "/tmp/painting.png";
    if (window.__gossamer_invoke) {
      try {
        const chosen = await window.__gossamer_invoke("__gossamer_dialog_save", { defaultPath: path });
        if (chosen && typeof chosen === "string") path = chosen;
      } catch (e) { /* fall back to default path */ }
    }
    const res = await invoke({ cmd: "save_png", path });
    status.textContent = res && res.ok === "saved" ? "Saved " + res.path : "Save failed";
  });

  boot();
})();
</script>
</body>
</html>
```

- [ ] **Step 2: Mirror the JS and CSS into source files**

Create `src/ui/app.js` containing the contents of the `<script>` body above (between the IIFE parentheses), and `src/ui/style.css` containing the contents of the `<style>` block above. These are the readable sources; `index.html` is the shipped, inlined artifact. Add a comment at the top of each noting they are mirrored into `index.html` by hand for increment 0.

- [ ] **Step 3: Manual smoke run**

Run:
```bash
just build
cargo run --manifest-path src/host/Cargo.toml
```
Expected: a window titled "paint.type" opens with a white canvas and a tool bar. Dragging on the canvas paints a red stroke. Clicking "Save PNG…" writes a file and the status line shows the path. Open the saved PNG in any viewer and confirm the stroke is present.

- [ ] **Step 4: Commit** (requires owner git authorisation)

```bash
git add src/ui
git commit -m "feat(ui): canvas, brush controls, and save for the walking skeleton"
```

---

### Task 7: Build wiring, headless e2e, and CI

**Files:**
- Modify: `Justfile`
- Create: `tests/e2e/scenario_host_headless.sh`
- Modify: `tests/e2e.sh`
- Create: `.github/workflows/host.yml`

- [ ] **Step 1: Extend the Justfile build, test, and run recipes**

In `Justfile`, change the `build` recipe to also build the host crates, and the `test` recipe to run `host_core` tests. Replace the existing `build` and `test` recipe bodies with:

```just
# Build the project (debug mode): Zig FFI library + Rust crates + host
build *args:
    @echo "Building {{project}} (debug)..."
    cd src/interface/ffi && zig build {{args}}
    cargo build --manifest-path src/paint_core/Cargo.toml {{args}}
    cargo build --manifest-path src/host_core/Cargo.toml {{args}}
    cargo build --manifest-path src/host/Cargo.toml {{args}}
    @echo "Build complete"

# Run all tests (Zig + Rust ephapax + host_core)
test *args:
    @echo "Running tests..."
    cd src/interface/ffi && zig build test {{args}}
    cargo test --manifest-path src/paint_core/Cargo.toml {{args}}
    cargo test --manifest-path src/host_core/Cargo.toml {{args}}
    @echo "Tests passed!"
```

Replace the `run` recipe body so it launches the application:

```just
# Run the application (the Gossamer desktop host)
run *args: build
    cargo run --manifest-path src/host/Cargo.toml {{args}}
```

- [ ] **Step 2: Verify build and test still pass**

Run: `just test`
Expected: Zig 29/29, ephapax suite (incl. render), and host_core (dispatch + codec) all PASS.

- [ ] **Step 3: Write the headless e2e scenario**

Create `tests/e2e/scenario_host_headless.sh`:

```bash
#!/usr/bin/env bash
# Headless boot-and-save smoke for the desktop host. Runs the host_core
# dispatch path through a tiny Rust example with no window, asserting a
# PNG is written with a painted stroke. This proves the seam logic end to
# end without a display; the GUI itself is smoke-tested manually.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d)/headless.png"

# Drive host_core via a one-shot cargo test binary target.
cargo test --manifest-path "$ROOT/src/host_core/Cargo.toml" \
    --test headless_save -- --nocapture

# The integration test writes its PNG to $PT_HEADLESS_OUT if set.
PT_HEADLESS_OUT="$OUT" cargo test --manifest-path "$ROOT/src/host_core/Cargo.toml" \
    --test headless_save -- --nocapture

if [ ! -s "$OUT" ]; then
    echo "FAIL: headless save produced no PNG at $OUT"
    exit 1
fi
echo "PASS: headless host wrote $OUT ($(wc -c < "$OUT") bytes)"
```

Create the integration test it drives, `src/host_core/tests/headless_save.rs`:

```rust
// SPDX-License-Identifier: PMPL-1.0-or-later
// Headless end-to-end: new_doc -> stroke -> save_png, no window.
use host_core::dispatch::dispatch;
use host_core::document::Document;
use host_core::protocol::{Command, Response};

#[test]
fn headless_new_doc_stroke_save() {
    let out = std::env::var("PT_HEADLESS_OUT")
        .unwrap_or_else(|_| std::env::temp_dir().join("pt_headless.png").to_string_lossy().into_owned());

    let mut doc: Option<Document> = None;
    assert_eq!(dispatch(&mut doc, Command::NewDoc { w: 128, h: 128 }), Response::Ack);
    dispatch(&mut doc, Command::SetColour { r: 0.0, g: 0.4, b: 1.0, a: 1.0 });
    dispatch(&mut doc, Command::SetBrush { diameter: 24 });
    dispatch(&mut doc, Command::PointerDown { x: 30.0, y: 30.0 });
    dispatch(&mut doc, Command::PointerMove { x: 90.0, y: 90.0 });
    dispatch(&mut doc, Command::PointerUp);

    let res = dispatch(&mut doc, Command::SavePng { path: out.clone() });
    assert!(matches!(res, Response::Saved { .. }), "got {res:?}");

    let meta = std::fs::metadata(&out).expect("png exists");
    assert!(meta.len() > 0, "png is non-empty");
}
```

Make the scenario executable: `chmod +x tests/e2e/scenario_host_headless.sh`.

- [ ] **Step 4: Wire the scenario into tests/e2e.sh**

In `tests/e2e.sh`, add a stage that runs the new scenario near the other `scenario_*.sh` invocations:

```bash
bash "$(dirname "$0")/e2e/scenario_host_headless.sh"
```

- [ ] **Step 5: Run the e2e suite**

Run: `bash tests/e2e.sh`
Expected: existing stages pass and the new "headless host wrote ..." line appears with a PASS.

- [ ] **Step 6: Create the CI workflow**

Create `.github/workflows/host.yml`:

```yaml
# SPDX-License-Identifier: PMPL-1.0-or-later
name: host
on:
  push:
    paths:
      - 'src/host/**'
      - 'src/host_core/**'
      - 'src/paint_core/**'
      - 'src/ui/**'
      - 'third_party/gossamer/**'
      - '.github/workflows/host.yml'
  pull_request:
permissions:
  contents: read
jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y libgtk-3-dev libwebkit2gtk-4.1-dev xvfb
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.1
      - uses: dtolnay/rust-toolchain@stable
      - name: Build libpt and libgossamer
        run: |
          cd src/interface/ffi && zig build && cd -
          cd third_party/gossamer/src/interface/ffi && zig build && cd -
      - name: host_core tests
        run: cargo test --manifest-path src/host_core/Cargo.toml
      - name: Build host binary
        run: cargo build --manifest-path src/host/Cargo.toml
      - name: Headless e2e
        run: xvfb-run -a bash tests/e2e/scenario_host_headless.sh
```

- [ ] **Step 7: Commit** (requires owner git authorisation)

```bash
git add Justfile tests/e2e.sh tests/e2e/scenario_host_headless.sh src/host_core/tests/headless_save.rs .github/workflows/host.yml
git commit -m "ci(host): build, headless e2e, and CI for the walking skeleton"
```

---

## Self-review

**Spec coverage** (against `2026-06-02-mvp-desktop-shell-design.md`, increment 0): host crate (Task 5), Gossamer window (Tasks 1, 5), web canvas (Task 6), framebuffer round-trip (Tasks 2, 3, 6), one brush (Task 3), `new_doc` (Task 3), save PNG (Tasks 4, 6), headless protocol test (Tasks 3, 7), Linux-only (Task 1, CI). The render path (component 2), tool wiring (component 3), codec (component 5), and build/run amendments (component 6) each map to a task. Error handling: dispatch returns `Response::Error` for pre-document commands and codec failures; the Gossamer handler converts lock and deserialisation failures to error strings. Deferred items (open PNG, eraser, fill, layer panel, selection, cross-platform) are explicitly out of increment 0 and belong to later plans.

**Placeholder scan:** no "TBD"/"TODO"/"handle appropriately". Every code step shows complete code; every command shows expected output. The one ordering caveat (a one-line placeholder `index.html` so Task 5 compiles before Task 6) is called out explicitly with the exact content.

**Type consistency:** `Command`/`Response` (snake_case serde tags `cmd`/`ok`) are produced in `protocol.rs` and consumed identically in `dispatch.rs`, `app.js` (`res.ok === "painted"`/`"saved"`), and the integration test. `Rect` is defined once in `document.rs` and referenced via `crate::document::Rect` in `dispatch.rs`. `render_region(stack, ox, oy, w, h)` has one signature used in `document.rs`. `save_png(path, rgba, w, h)` and `load_png(path)` match between `codec.rs`, `dispatch.rs`, and the tests. `Document` methods (`new`, `set_colour`, `set_brush`, `pointer_down`, `pointer_move`, `render`, `render_all`, `width`, `height`) are defined in `document.rs` and called consistently. `ephapax` items used (`brush::{Brush, BrushTip, Stroke}`, `layer::{Layer, LayerId, LayerStack, TileCoord}`, `Tile`, `TILE_SIZE`, `f16_bits_to_f32`, `f32_to_f16_bits`, `composite::over_premultiplied`, `render::render_region`) match the verified signatures, contingent on `ephapax`'s modules being `pub` (checked in Task 3 Step 5).

One known risk flagged for the executor: the `gossamer-rs` `build.rs` hard-links GTK/WebKit and a relative in-tree lib path, so this plan is Linux-only by construction and assumes the vendored Gossamer tree builds its Zig FFI in place. Cross-platform support is increment 5 and will require upstream binding changes.
