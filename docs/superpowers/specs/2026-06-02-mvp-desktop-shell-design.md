# MVP: Desktop Shell (v0.3.0) Design

Date: 2026-06-02
Author: Joshua Jewell (with Claude Code)
Status: Draft, awaiting review

## Purpose

Turn paint-type from a verified library into a runnable image editor. Today the
repository holds a well-tested core (Rust compositing, brush, undo, and layer
maths; a Zig C ABI; a proven Idris2 ABI) but nothing that opens a window or puts
a pixel on a screen. This design brings the project to its own roadmap milestone
v0.3.0 (Desktop Shell): a real application a user can launch, paint in, and save
from.

The smallest honest definition of done for the MVP is the full v0.3.0 shell: a
Gossamer-hosted window with a web UI, an interactive canvas, the brush, eraser,
fill, and selection tools, a layer panel, PNG open and save, and cross-platform
builds for Linux, macOS, and Windows.

## Settled decisions (the brainstorm that produced this)

These were chosen deliberately and are the frame for everything below:

- MVP target: the full v0.3.0 Desktop Shell, not a headless core and not a
  library-only release.
- Shell: Gossamer. Verified ready upstream (v0.3.1, 173 integration tests,
  cross-platform, documented C FFI for embedding a webview, existing Rust
  bindings).
- Bridge: Gossamer FFI direct. The prescribed AffineScript to typed-wasm bridge
  is deferred because typed-wasm is pre-alpha and its producer-side access-site
  codegen is the explicit remaining gate (upstream ephapax#251, affinescript#462).
  The UI talks to the core over Gossamer's C FFI message channel instead.
- Sequencing: walking skeleton first, then increments. Prove the cross-language
  seam with one brush before building outward.
- Codec: the audited Rust `png` crate, chosen on memory-safety grounds rather
  than hand-rolling a parser on a known vulnerability surface.

## What exists today (the MVP builds on this, not from scratch)

- `src/paint_core/` (Rust): `Tile`, eleven compositing operators
  (`over_premultiplied`, `masked_blend`, `flatten_layer_stack`, `lerp`,
  `multiply`, `screen`, `in_op`, `out_op`, `atop`, `xor`, plus
  `Tile::composite_over`), a persistent branching `UndoGraph`, a `LayerStack`
  layer model, and a brush engine (`BrushTip`, `Brush::stamp`, `Stroke`).
  98 tests plus 1 doctest pass.
- `src/interface/ffi/` (Zig, `libpt`): 23 C ABI exports (`pt_tile_*`,
  `pt_layer_*`, slot helpers, `pt_last_error`, `pt_version`). 29 tests pass.
- `src/interface/Abi/` (Idris2): the ABI category, fully proven and CI-checked.
- `Justfile`: `just build` compiles Zig `libpt` then the Rust crate;
  `just run` currently only runs the Zig tests; there is no application binary.

The two capabilities the MVP must add to the core are small: a render-to-display
function, and pointer-to-stroke glue. Everything else is connective tissue.

## Architecture (MVP spine)

A new host binary becomes the application. It is the only new top-level piece.

```
  Gossamer window  --hosts-->  Web UI (HTML/CSS/JS, src/ui/)
        |                              |
        |  C FFI message channel       |  command-in / dirty-rect-out
        v                              v
  Host binary (src/host/, Rust)  -- owns Document, framebuffer, tool state
        |
        +-- ephapax (Rust): composite, brush, undo, layer maths
        +-- libpt (Zig, via ephapax): tile + layer primitives
```

The host owns a `Document`: canvas dimensions, a `LayerStack`, the active layer,
the current tool, colour, brush parameters, and an RGBA8 display framebuffer. It
boots a Gossamer window, loads the bundled web UI, and registers one message
handler. The UI never touches pixels directly; it sends commands and receives
dirty rectangles. This realises the README's "command-in, dirty-rect-out"
contract over Gossamer's FFI rather than the typed bridge. The framebuffer
crosses as a byte copy for the MVP; when typed-wasm matures, a zero-copy path
slots in behind the identical message shape with no protocol change.

## Components

### 1. `src/host/` (new, Rust binary)

Depends on `ephapax` (path dependency) and the Gossamer Rust bindings. Owns the
`Document` and the event loop. Translates inbound UI messages into `ephapax`
edits and outbound `ephapax` output into dirty-rect messages. The host is the
single owner of mutable document state, so the linear-ownership guarantees of
`ephapax` are preserved: tiles are never aliased across the boundary.

### 2. Render path (new, in `ephapax`)

`render_dirty(region) -> Vec<u8>` (RGBA8): composite the visible layer stack over
a region using the existing `flatten_layer_stack` and `composite_over`, then
downconvert RGBA16F to 8-bit for display. This is the one genuinely missing core
capability. It lives in `ephapax` (not the host) so it is unit-testable without a
window and reuses the existing compositing code.

### 3. Tool wiring (new glue over the existing engine)

`pointer_down` opens a `Stroke` at the mapped coordinate with the current colour
and brush; `pointer_move` extends it, stamping `Brush` onto the active layer's
tiles via the existing spacing-aware `Stroke`, accumulating dirty rectangles;
`pointer_up` commits one `UndoGraph` node. The eraser reuses `out_op`
(destination-out alpha). Fill is a new bounded scanline fill confined to the
canvas rectangle. Selection (increment 4) is a rectangular marquee that masks
subsequent edits.

### 4. `src/ui/` (new, vanilla HTML/CSS/JS)

A single page: a `<canvas>` viewport that blits incoming dirty rectangles as
`ImageData`; a tool bar (brush, eraser, fill, colour swatch, size, hardness); and
a layer panel bound to the layer commands. No framework and no Node build step,
to avoid dragging a JavaScript toolchain into an austere repository. The page
sends commands and receives events through the Gossamer JavaScript bridge.

### 5. Codec (new)

PNG decode and encode via the audited Rust `png` crate, plus the uncompressed
native RGBA16F format. The codec lives behind the host. Decode is bounded by a
maximum dimension to contain the decoder attack surface. File type is chosen by
extension on open and save.

### 6. Build and run (amend `Justfile` and CI)

`just run` launches the host binary; `just build` also builds it; `just test`
gains the host's tests. A CI job builds and smoke-boots the host (under `xvfb` on
Linux for any step that needs a display). The existing proof and test jobs stay
unchanged and green.

## Data flow (one brush stroke, end to end)

1. The webview captures a pointer press on the `<canvas>`, maps CSS coordinates
   to document coordinates, and sends `pointer_down{x,y}`.
2. The host opens a `Stroke` with the current colour and brush, stamps the first
   dab onto the active layer, and computes the dirty rectangle.
3. The host composites the visible stack over that region into RGBA8 and emits
   `dirty_rect{x,y,w,h,bytes}`.
4. The webview wraps the bytes in `ImageData` and blits them at `(x,y)`.
5. `pointer_move` extends the stroke (the `Stroke` type carries spacing between
   dabs); `pointer_up` commits one `UndoGraph` node.

Save flattens the stack and encodes PNG or native RGBA16F by file extension; open
decodes into tiles and emits one full-canvas dirty rectangle. The message shape
never changes: commands in, dirty rectangles out.

### Message protocol (initial set)

UI to core: `new_doc{w,h}`, `open{path}`, `save{path}`, `select_tool{kind}`,
`set_colour{r,g,b,a}`, `set_brush{size,hardness}`, `pointer_down{x,y}`,
`pointer_move{x,y}`, `pointer_up`, `add_layer`, `select_layer{id}`,
`set_layer_visible{id,bool}`, `set_layer_opacity{id,value}`,
`reorder_layer{id,position}`, `undo`, `redo`.

Core to UI: `dirty_rect{x,y,w,h,bytes}`, `doc_state{layers,active,dimensions}`,
`error{message}`. Encoding is JSON for control messages; dirty-rect pixel
payloads are transferred as raw bytes alongside their header to avoid base64
inflation where the bridge allows it.

## Error handling

Every `libpt` call returns a status with `pt_last_error`; the host surfaces these
as `error{message}` events in a UI status line and never lets a failure cross the
FFI as a panic. Codec failures (corrupt or oversized PNG) are caught in the host
and bounded by a maximum decode dimension. Malformed protocol messages are logged
and ignored rather than treated as fatal. The host wraps `ephapax` calls so that
a panic in a handler is caught at the boundary (`catch_unwind`) and converted to
an error event; the window survives a bad edit. Document edits that would violate
layer or tile invariants return a `Result` the host reports rather than crashing.

## Testing

The existing suites stay green: cargo 98/98 plus 1 doctest, zig 29/29, Idris2
`--check`, aspect tests, and `tests/e2e.sh`.

New coverage:

- Unit: `render_dirty` correctness (a known stack yields known RGBA8 bytes),
  fill bounds, eraser alpha reduction.
- Codec: an encode then decode round-trip equals the source within tolerance;
  a decode of a deliberately oversized header is rejected.
- Integration: a headless host test that drives the full message protocol with
  no real window. It injects commands and asserts the dirty-rect output and the
  saved file bytes, so the seam is testable in CI without a display.
- Fuzz: the existing cargo-fuzz harness gains a PNG-decode target.
- E2E: `tests/e2e.sh` gains a scenario that boots the host headless, sends
  `new_doc` plus a brush stroke plus `save`, and asserts a non-empty PNG.

A change is complete only when these are green; evidence before assertion.

## Increment cut lines (walking skeleton outward)

- Increment 0, spine: host crate, Gossamer window, web canvas, framebuffer
  round-trip, one brush, `new_doc`, save PNG; Linux only; headless protocol
  test. Proves the seam.
- Increment 1: open PNG; colour picker, brush size and hardness controls.
- Increment 2: eraser and bounded fill.
- Increment 3: layer panel wired to the layer commands (add, select, visibility,
  opacity, reorder); multi-layer display.
- Increment 4: selection tool (rectangular marquee, masked editing).
- Increment 5: macOS and Windows CI and packaging; cross-platform smoke boot.

A usable editor exists at increment 3; full v0.3.0 lands at increment 5. If
appetite ever forces a line, increments 0 to 3 are a defensible public MVP with 4
and 5 as fast-follow. This spec plans for all six because the agreed target is the
full shell. The implementation plan will likely carry one milestone per
increment.

## Out of scope and honesty notes

- The AffineScript to typed-wasm bridge stays stubbed (`src/bridges/`,
  `src/interface/generated/`) by upstream necessity, not preference. Recorded so
  no reader mistakes the deferral for an oversight.
- The framebuffer crosses the bridge as a copy until the typed-wasm zero-copy
  path matures. The message shape is designed so that upgrade changes no
  protocol.
- There are two layer models: the Rust `LayerStack` in `layer.rs` and the Zig
  `pt_layer_*` handle API. The brush and compositor operate on the Rust tiles, so
  the host treats the Rust `LayerStack` as the document's canonical model and
  regards `pt_layer_*` as its C ABI mirror. Full reconciliation of the two is
  noted but kept out of MVP scope.
- No collaboration (Burble, Groove), no plugin system, and no AffineScript
  scripting surface; those are v0.4.0 and later.
- No new formal proofs; the MVP is application code, and the proven ABI is
  consumed, not extended.

## Verification

After each increment the build and all gates must pass:

- `just build` compiles `libpt`, `ephapax`, and the new host binary.
- `just test` runs zig, cargo (including `render_dirty`, codec, and the headless
  protocol test), and leaves the Idris2 `--check` job green.
- `bash tests/e2e.sh` passes, including the new headless boot-and-save scenario.
- The kept governance gates (dogfood-gate, aspect tests, static analysis) stay
  green; the new host crate is added to the relevant CI matrices.

## Sequencing

Build increment 0 first and prove the seam end to end before any tool beyond the
single brush. Each later increment attaches to the same message interface and is
independently verifiable. Detailed step ordering is deferred to the
implementation plan.
