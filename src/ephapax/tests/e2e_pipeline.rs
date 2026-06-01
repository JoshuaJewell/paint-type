// SPDX-License-Identifier: PMPL-1.0-or-later
//
// End-to-end pipeline integration test for paint.type.
//
// This test exercises the full editing pipeline that v0.2.0 ships:
//
//   1. Tile lifecycle via the safe `Tile` wrapper (which calls libpt's
//      `pt_tile_alloc` / `pt_tile_fill` / `pt_tile_read_pixel` /
//      `pt_tile_write_pixel` / `pt_tile_free` under the hood).
//   2. Compositing — `Tile::composite_over` (which itself drives
//      `composite::over_premultiplied` pixel-by-pixel).
//   3. The `UndoGraph<RevSnapshot>` non-destructive revision store
//      capturing snapshots between edit steps.
//   4. Layer-stack metadata via the `pt_layer_*` cross-language FFI:
//      `pt_layer_stack_new`, `pt_layer_push`, `pt_layer_reorder_to`,
//      `pt_layer_get_name`, `pt_layer_get_id_at`, `pt_layer_count`,
//      `pt_layer_stack_free`.
//   5. The brush engine — a `BrushTip::hard_round` tip wrapped in a
//      `Brush` and driven through a `Stroke` that emits at least five
//      stamps; each stamp goes through `composite::masked_blend` and
//      mutates the tile through `pt_tile_write_pixel`.
//
// The test verifies pixel values at multiple probe points after each
// stage and asserts the revision graph monotonicity invariant
// (PROOF-NEEDS INV-2) by reading old snapshots after later edits.
//
// Test paths use `expect()` with clear messages, as permitted by aspect
// test #4 (panic-safety bans unwrap/expect/panic only in production).

#![allow(clippy::float_cmp)]

use ephapax::undo::{RevId, UndoGraph};
use ephapax::{
    brush::{Brush, BrushTip, Stroke},
    layer::{Layer, LayerStack, TileCoord},
    pt_layer_count, pt_layer_get_id_at, pt_layer_get_name, pt_layer_push, pt_layer_reorder_to,
    pt_layer_stack_free, pt_layer_stack_new, Tile, TILE_SIZE,
};

const APPROX_EPS: f32 = 1.0e-2_f32;

fn approx_eq(a: f32, b: f32) -> bool {
    (a - b).abs() < APPROX_EPS
}

/// One revision snapshot — a 4-channel sample of the canvas at three
/// probe coordinates plus a textual label. Cheap to clone and to keep
/// in the undo graph.
#[derive(Clone, Debug)]
struct RevSnapshot {
    label: &'static str,
    p00: [f32; 4],
    p_mid: [f32; 4],
    p_corner: [f32; 4],
}

fn snapshot(label: &'static str, tile: &Tile) -> RevSnapshot {
    let p00 = tile.read_pixel_f32(0, 0).expect("snapshot: read (0, 0)");
    let p_mid = tile
        .read_pixel_f32(TILE_SIZE / 2, TILE_SIZE / 2)
        .expect("snapshot: read (32, 32)");
    let p_corner = tile
        .read_pixel_f32(TILE_SIZE - 1, TILE_SIZE - 1)
        .expect("snapshot: read (63, 63)");
    RevSnapshot {
        label,
        p00,
        p_mid,
        p_corner,
    }
}

/// Read the name of the layer at `position` into a freshly-allocated
/// `String`. Returns `None` on any FFI error so the caller can fail the
/// test with a clear message.
fn read_layer_name(stack: u64, position: u32) -> Option<String> {
    // SAFETY: `stack` is a live PtLayerStack pointer obtained from
    // `pt_layer_stack_new` (checked by the caller). `position` is
    // bounds-checked inside libpt — out-of-range returns 0.
    let id = unsafe { pt_layer_get_id_at(stack, position) };
    if id == 0 {
        return None;
    }
    let mut buf = [0u8; 64];
    let mut out_len: u32 = 0;
    // SAFETY: `buf` and `out_len` are valid for the duration of the
    // call; libpt validates the stack/id and writes at most buf.len()
    // bytes into `buf`.
    let rc = unsafe {
        pt_layer_get_name(
            stack,
            id,
            buf.as_mut_ptr() as u64,
            buf.len() as u32,
            &mut out_len as *mut u32 as u64,
        )
    };
    if rc != 0 {
        return None;
    }
    let len = out_len as usize;
    if len > buf.len() {
        return None;
    }
    core::str::from_utf8(&buf[..len]).ok().map(str::to_string)
}

/// Walk the full editing pipeline.
///
/// Scenario:
///   - Allocate two RGBA16F tiles, A (opaque red) and B (premultiplied
///     half-alpha blue), at adjacent grid positions.
///   - Composite B over A; snapshot the canvas.
///   - Push two layers onto a pt_layer_* stack ("Background", "Stroke"),
///     reorder so "Stroke" sits above "Background", verify the FFI
///     reports the new ordering, snapshot under the new revision.
///   - Drive a Stroke of >=5 stamps with a hard-round tip across the
///     composited tile; snapshot.
///   - Verify pixels at multiple probes after every stage.
///   - Replay the revision history via `UndoGraph::checkout` and assert
///     each snapshot still matches what we recorded.
#[test]
fn end_to_end_tile_layer_brush_undo_pipeline() {
    // ── Stage 1: allocate and fill two source tiles ────────────────────
    let tile_a = Tile::alloc(0, 0).expect("alloc tile A (red dst)");
    let tile_b = Tile::alloc(1, 0).expect("alloc tile B (half-blue src)");
    assert!(tile_a.is_initialized(), "tile A not initialised");
    assert!(tile_b.is_initialized(), "tile B not initialised");

    // dst opaque red (premultiplied = (1, 0, 0, 1)).
    tile_a
        .fill_f32(1.0, 0.0, 0.0, 1.0)
        .expect("fill tile A with opaque red");
    // src premultiplied half-alpha blue (0, 0, 0.5, 0.5).
    tile_b
        .fill_f32(0.0, 0.0, 0.5, 0.5)
        .expect("fill tile B with half-blue");

    // Per-pixel read-back at three probes on tile A.
    for (px, py) in [(0u32, 0u32), (17, 41), (TILE_SIZE - 1, TILE_SIZE - 1)] {
        let p = tile_a
            .read_pixel_f32(px, py)
            .expect("read tile A pre-composite");
        assert!(approx_eq(p[0], 1.0), "A R({px},{py}) = {}", p[0]);
        assert!(approx_eq(p[1], 0.0), "A G({px},{py}) = {}", p[1]);
        assert!(approx_eq(p[2], 0.0), "A B({px},{py}) = {}", p[2]);
        assert!(approx_eq(p[3], 1.0), "A A({px},{py}) = {}", p[3]);
    }

    // Capture the initial canvas state into the undo graph.
    let mut graph: UndoGraph<RevSnapshot> = UndoGraph::new(snapshot("initial-red", &tile_a));

    // ── Stage 2: composite tile B over tile A ──────────────────────────
    // Expected per pixel: red (1,0,0,1) under half-blue (0,0,0.5,0.5) →
    // (0.5, 0, 0.5, 1.0) for every pixel, both inputs being uniform.
    let composed = tile_a
        .composite_over(&tile_b)
        .expect("Tile::composite_over A under B");

    let probes: [(u32, u32); 5] = [
        (0, 0),
        (1, 1),
        (TILE_SIZE / 2, TILE_SIZE / 2),
        (TILE_SIZE - 1, 0),
        (TILE_SIZE - 1, TILE_SIZE - 1),
    ];
    for (px, py) in probes {
        let p = composed
            .read_pixel_f32(px, py)
            .expect("read composed pixel");
        assert!(approx_eq(p[0], 0.5), "composed R({px},{py}) = {}", p[0]);
        assert!(approx_eq(p[1], 0.0), "composed G({px},{py}) = {}", p[1]);
        assert!(approx_eq(p[2], 0.5), "composed B({px},{py}) = {}", p[2]);
        assert!(approx_eq(p[3], 1.0), "composed A({px},{py}) = {}", p[3]);
    }

    let rev_composited = graph.commit(RevId::ROOT, snapshot("post-composite", &composed));

    // Old revision must still be reachable (UndoGraph monotonicity).
    let initial_seen = graph
        .checkout(RevId::ROOT)
        .expect("checkout initial revision");
    assert_eq!(initial_seen.label, "initial-red");
    assert!(approx_eq(initial_seen.p00[0], 1.0));

    // ── Stage 3: push two layers via pt_layer_* and reorder ────────────
    // SAFETY: pt_layer_stack_new returns 0 on OOM (handled) or a live
    // PtLayerStack pointer that pt_layer_stack_free will accept.
    let stack = unsafe { pt_layer_stack_new() };
    assert!(stack != 0, "pt_layer_stack_new returned null");

    let bg_name = b"Background";
    let stroke_name = b"Stroke";
    // SAFETY: name byte slices outlive each pt_layer_push call.
    let bg_id = unsafe { pt_layer_push(stack, bg_name.as_ptr() as u64, bg_name.len() as u32) };
    let stroke_id =
        unsafe { pt_layer_push(stack, stroke_name.as_ptr() as u64, stroke_name.len() as u32) };
    assert_ne!(bg_id, 0, "pt_layer_push for Background returned 0");
    assert_ne!(stroke_id, 0, "pt_layer_push for Stroke returned 0");
    assert_ne!(bg_id, stroke_id, "pt_layer_push must issue distinct IDs");

    // SAFETY: live stack pointer.
    let count = unsafe { pt_layer_count(stack) };
    assert_eq!(count, 2, "pt_layer_count after two pushes");

    // After push: position 0 = Background (bottom), position 1 = Stroke (top).
    let pos0 = read_layer_name(stack, 0).expect("read name at position 0");
    let pos1 = read_layer_name(stack, 1).expect("read name at position 1");
    assert_eq!(pos0, "Background");
    assert_eq!(pos1, "Stroke");

    // Reorder Stroke to the bottom (position 0). After: Stroke at 0, Background at 1.
    // SAFETY: live stack + valid id, new_position 0 is in range.
    let rc = unsafe { pt_layer_reorder_to(stack, stroke_id, 0) };
    assert_eq!(rc, 0, "pt_layer_reorder_to returned non-OK code {rc}");

    let pos0_after = read_layer_name(stack, 0).expect("read name at position 0 (post-reorder)");
    let pos1_after = read_layer_name(stack, 1).expect("read name at position 1 (post-reorder)");
    assert_eq!(pos0_after, "Stroke");
    assert_eq!(pos1_after, "Background");

    // Snapshot the canvas under a new revision once the layer order changes.
    let rev_layer_reordered =
        graph.commit(rev_composited, snapshot("post-layer-reorder", &composed));

    // ── Stage 4: drive a Stroke of >=5 stamps with a hard-round tip ────
    // tip diameter 8, spacing_ratio 0.25 → stamp_spacing = 2.0.
    // Stroke runs horizontally across the tile centre (y = 32) from
    // x = 0 to x = 60, passing through the (32, 32) probe. That gives
    // 30 further stamps after the initial dab; we assert >= 5.
    let tip = BrushTip::hard_round(8);
    let brush = Brush::new(tip, [1.0, 1.0, 1.0, 1.0], 0.25);
    let mut stroke = Stroke::new();

    let stamps_start = stroke.push(0.0, 32.0, &brush);
    assert_eq!(
        stamps_start.len(),
        1,
        "first stroke push should emit one dab"
    );

    let stamps_run = stroke.push(60.0, 32.0, &brush);
    assert!(
        stamps_run.len() >= 5,
        "expected >=5 follow-up stamps along the run, got {}",
        stamps_run.len()
    );

    // Apply every stamp to the composited tile.
    let total_stamps = stamps_start.len() + stamps_run.len();
    let mut total_pixels_written: u32 = 0;
    for (cx, cy) in stamps_start.into_iter().chain(stamps_run) {
        let written = brush
            .stamp(&composed, cx, cy)
            .expect("brush.stamp must succeed on a live tile");
        total_pixels_written = total_pixels_written.saturating_add(written);
    }
    assert!(total_stamps >= 6, "expected at least six stamps total");
    assert!(
        total_pixels_written > 0,
        "brush stamping must touch at least one pixel"
    );

    // A pixel directly under the stroke at (8, 32) should now be much
    // brighter than the pre-brush blend (which was 0.5, 0, 0.5).
    let p_under_stroke = composed
        .read_pixel_f32(8, 32)
        .expect("read pixel under the stroke");
    assert!(
        p_under_stroke[0] > 0.5_f32 + APPROX_EPS,
        "stroke must lift R above the 0.5 baseline (got {})",
        p_under_stroke[0]
    );
    assert!(
        p_under_stroke[1] > 0.0_f32 + APPROX_EPS,
        "stroke must lift G above the 0.0 baseline (got {})",
        p_under_stroke[1]
    );
    assert!(
        p_under_stroke[2] > 0.5_f32 + APPROX_EPS,
        "stroke must lift B above the 0.5 baseline (got {})",
        p_under_stroke[2]
    );
    assert!(
        approx_eq(p_under_stroke[3], 1.0),
        "stroke must preserve alpha = 1 (got {})",
        p_under_stroke[3]
    );

    // A pixel far above the y = 32 row must be unchanged by the stroke.
    let p_far = composed
        .read_pixel_f32(8, 0)
        .expect("read pixel above stroke row");
    assert!(approx_eq(p_far[0], 0.5), "untouched R = {}", p_far[0]);
    assert!(approx_eq(p_far[1], 0.0), "untouched G = {}", p_far[1]);
    assert!(approx_eq(p_far[2], 0.5), "untouched B = {}", p_far[2]);
    assert!(approx_eq(p_far[3], 1.0), "untouched A = {}", p_far[3]);

    let rev_brushed = graph.commit(rev_layer_reordered, snapshot("post-brush", &composed));

    // ── Stage 5: undo-graph monotonicity replay ────────────────────────
    // The graph now has 4 revisions: ROOT, rev_composited,
    // rev_layer_reordered, rev_brushed. Old revisions must still hold
    // their original snapshots (PROOF-NEEDS INV-2 clause 2).
    assert_eq!(graph.len(), 4, "graph length after three commits");

    let r0 = graph.checkout(RevId::ROOT).expect("checkout ROOT");
    assert_eq!(r0.label, "initial-red");
    assert!(approx_eq(r0.p00[0], 1.0));
    assert!(approx_eq(r0.p00[2], 0.0));

    let r1 = graph.checkout(rev_composited).expect("checkout composited");
    assert_eq!(r1.label, "post-composite");
    assert!(approx_eq(r1.p00[0], 0.5));
    assert!(approx_eq(r1.p00[2], 0.5));

    let r2 = graph
        .checkout(rev_layer_reordered)
        .expect("checkout reordered");
    assert_eq!(r2.label, "post-layer-reorder");

    let r3 = graph.checkout(rev_brushed).expect("checkout brushed");
    assert_eq!(r3.label, "post-brush");
    // The under-stroke probe in r3 must match what we asserted above.
    // The recorded `p_mid` is (32, 32) — directly under the stroke band.
    assert!(
        r3.p_mid[0] > 0.5_f32 + APPROX_EPS,
        "r3 p_mid R = {}",
        r3.p_mid[0]
    );
    // The (63, 63) corner sits well above the stroke band (y = 32);
    // it must still carry the pre-brush composite (0.5, 0, 0.5, 1.0)
    // — proves the brush respected the tile bounds and we are still
    // reading from the same canvas snapshot.
    assert!(
        approx_eq(r3.p_corner[0], 0.5),
        "r3 p_corner R = {} (expected pre-brush composite)",
        r3.p_corner[0]
    );
    assert!(
        approx_eq(r3.p_corner[2], 0.5),
        "r3 p_corner B = {} (expected pre-brush composite)",
        r3.p_corner[2]
    );

    // Ancestry: ROOT is on the path to every commit.
    assert!(graph.is_ancestor(RevId::ROOT, rev_brushed));
    assert!(graph.is_ancestor(rev_composited, rev_brushed));
    assert!(graph.is_ancestor(rev_layer_reordered, rev_brushed));
    // Brushed is NOT an ancestor of composited (forward direction only).
    assert!(!graph.is_ancestor(rev_brushed, rev_composited));

    // ── Cleanup: release the layer stack ───────────────────────────────
    // SAFETY: stack is a live, never-freed PtLayerStack pointer. After
    // this call the local variable goes out of scope without further use.
    unsafe { pt_layer_stack_free(stack) };

    // tile_a, tile_b, composed all drop here, each invoking pt_tile_free.
}

/// A second substantive scenario: drive the higher-level layer model
/// (Rust-side `LayerStack`) through a push → reorder → flatten cycle
/// and verify the flattened tile matches a hand-computed composite.
#[test]
fn end_to_end_layer_stack_flatten_pipeline() {
    // Bottom layer: opaque red tile at (0, 0).
    let mut bg = Layer::new("bg");
    let bg_tile = Tile::alloc(0, 0).expect("alloc bg tile");
    bg_tile
        .fill_f32(1.0, 0.0, 0.0, 1.0)
        .expect("fill bg with opaque red");
    bg.put_tile(TileCoord::new(0, 0), bg_tile);

    // Top layer: premultiplied half-alpha green tile at the same coord.
    let mut fg = Layer::new("fg");
    let fg_tile = Tile::alloc(0, 0).expect("alloc fg tile");
    fg_tile
        .fill_f32(0.0, 0.5, 0.0, 0.5)
        .expect("fill fg with half-green");
    fg.put_tile(TileCoord::new(0, 0), fg_tile);

    let mut stack = LayerStack::new();
    let bg_id = stack.push(bg);
    let fg_id = stack.push(fg);
    assert_eq!(stack.len(), 2, "stack should have two layers");

    // Reorder fg below bg (so bg is now on top) and back.
    stack
        .reorder_to(fg_id, 0)
        .expect("reorder fg to bottom must succeed");
    assert_eq!(stack.position_of(fg_id), Some(0));
    assert_eq!(stack.position_of(bg_id), Some(1));
    stack
        .reorder_to(fg_id, 1)
        .expect("reorder fg back to top must succeed");
    assert_eq!(stack.position_of(fg_id), Some(1));
    assert_eq!(stack.position_of(bg_id), Some(0));

    let flat = stack
        .flatten("flattened")
        .expect("LayerStack::flatten must succeed");
    let result_tile = flat
        .tile(TileCoord::new(0, 0))
        .expect("flattened layer must have a tile at (0, 0)");

    // Expected per pixel: half-green over opaque red.
    // src = (0, 0.5, 0, 0.5) premultiplied; dst = (1, 0, 0, 1).
    // inv_a = 0.5; rgb_out = src + dst*inv_a = (0.5, 0.5, 0, 1).
    for (px, py) in [
        (0u32, 0u32),
        (TILE_SIZE / 2, TILE_SIZE / 2),
        (TILE_SIZE - 1, TILE_SIZE - 1),
    ] {
        let p = result_tile
            .read_pixel_f32(px, py)
            .expect("read flattened pixel");
        assert!(approx_eq(p[0], 0.5), "R({px},{py}) = {}", p[0]);
        assert!(approx_eq(p[1], 0.5), "G({px},{py}) = {}", p[1]);
        assert!(approx_eq(p[2], 0.0), "B({px},{py}) = {}", p[2]);
        assert!(approx_eq(p[3], 1.0), "A({px},{py}) = {}", p[3]);
    }
}
