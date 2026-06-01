// SPDX-License-Identifier: PMPL-1.0-or-later
//
// pt_tile_blit fuzz target.
//
// `pt_tile_blit` is the planned source-to-destination tile copy entry
// point (TEST-NEEDS P2). The FFI surface in src/interface/ffi/src/main.zig
// does not yet expose a single `pt_tile_blit` symbol; until it does, this
// harness fuzzes the equivalent operation built from the primitives that
// are exposed today:
//
//   pt_tile_alloc  →  pt_tile_write_pixel*  →  pt_tile_read_pixel*  →  pt_tile_free
//
// The blit body issues `w * h` read-from-src / write-to-dst pairs across
// arbitrary `(src_x, src_y)` / `(dst_x, dst_y)` start offsets and `w, h`
// extents. Inputs are bounded so the fuzzer can still explore offset
// arithmetic that walks off the 64x64 tile (the FFI must reject those
// without UB or crash); without the bound the loop body would dominate
// runtime instead of input space.
//
// Invariants asserted:
//   * Every FFI call returns; libpt never aborts the process.
//   * Out-of-bounds reads/writes yield Err(InvalidParam), never Ok.
//   * Successful writes round-trip: a Read after a Write must return
//     the same bit pattern (this catches silent corruption in libpt's
//     pixel addressing).

#![no_main]

use ephapax::{Tile, TILE_SIZE};
use libfuzzer_sys::fuzz_target;

/// Bounded blit input: every numeric field is capped well below the
/// 64x64 tile bound so the fuzzer spends its budget on edge cases at
/// the tile boundary instead of trivial out-of-range failures.
#[derive(arbitrary::Arbitrary, Debug)]
struct BlitInput {
    src_grid_x: u32,
    src_grid_y: u32,
    dst_grid_x: u32,
    dst_grid_y: u32,
    src_x: u8,
    src_y: u8,
    dst_x: u8,
    dst_y: u8,
    w: u8,
    h: u8,
    fill_r: u16,
    fill_g: u16,
    fill_b: u16,
    fill_a: u16,
}

fuzz_target!(|input: BlitInput| {
    // Cap blit extents to [0, 80] so we still exercise the off-by-one
    // around TILE_SIZE (64) without spending all our cycles on the
    // 255×255 case. The branchless `min` keeps the body O(1).
    let w = (input.w as u32).min(80);
    let h = (input.h as u32).min(80);
    let src_x = (input.src_x as u32).min(80);
    let src_y = (input.src_y as u32).min(80);
    let dst_x = (input.dst_x as u32).min(80);
    let dst_y = (input.dst_y as u32).min(80);

    let src = match Tile::alloc(input.src_grid_x, input.src_grid_y) {
        Some(t) => t,
        None => return,
    };
    let dst = match Tile::alloc(input.dst_grid_x, input.dst_grid_y) {
        Some(t) => t,
        None => return,
    };

    // Pre-fill src with a deterministic colour so blit invariants are
    // checkable: after a successful read+write, dst must hold the same
    // bit pattern at the destination coordinate.
    let _ = src.fill_bits(input.fill_r, input.fill_g, input.fill_b, input.fill_a);

    for dy in 0..h {
        for dx in 0..w {
            let sx = src_x.saturating_add(dx);
            let sy = src_y.saturating_add(dy);
            let tx = dst_x.saturating_add(dx);
            let ty = dst_y.saturating_add(dy);

            let read = src.read_pixel_bits(sx, sy);
            let any_oob = sx >= TILE_SIZE || sy >= TILE_SIZE;
            // Invariant: out-of-bounds source coordinates MUST error.
            assert!(
                !(any_oob && read.is_ok()),
                "src OOB ({sx},{sy}) returned Ok"
            );

            let Ok(pixel) = read else { continue };

            let write = dst.write_pixel_bits(tx, ty, pixel[0], pixel[1], pixel[2], pixel[3]);
            let dst_oob = tx >= TILE_SIZE || ty >= TILE_SIZE;
            assert!(
                !(dst_oob && write.is_ok()),
                "dst OOB ({tx},{ty}) returned Ok"
            );

            if write.is_ok() {
                // Round-trip invariant: a Read after a Write returns
                // the bit pattern we just wrote.
                let read_back = dst.read_pixel_bits(tx, ty);
                if let Ok(rb) = read_back {
                    assert_eq!(rb, pixel, "round-trip mismatch at ({tx},{ty})");
                }
            }
        }
    }

    // Tile is non-Copy / non-Clone; Drop runs here and calls pt_tile_free
    // exactly once per allocation, sanity-checking the lifecycle path.
});
