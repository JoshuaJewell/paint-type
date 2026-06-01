// SPDX-License-Identifier: PMPL-1.0-or-later
//
// pt_tile_write_pixel fuzz target.
//
// Drives `Tile::write_pixel_bits` (the safe wrapper around the
// `pt_tile_write_pixel` Zig FFI export) with arbitrary pixel
// coordinates and four arbitrary u16 channel bit patterns. The bit
// patterns are valid IEEE 754 binary16 encodings by construction
// (every u16 IS a valid binary16 — including NaNs, subnormals, and
// ±Inf), so the fuzzer freely explores all FP edge cases.
//
// Invariants asserted:
//   * Every call returns; libpt never aborts.
//   * `px >= TILE_SIZE` or `py >= TILE_SIZE` ⇒ Err(InvalidParam),
//     never Ok (catches OOB regressions).
//   * In-bounds writes round-trip: a subsequent Read returns the same
//     four u16 bit patterns (catches silent corruption in libpt's
//     pixel addressing arithmetic).

#![no_main]

use ephapax::{Tile, TILE_SIZE};
use libfuzzer_sys::fuzz_target;

#[derive(arbitrary::Arbitrary, Debug)]
struct WriteInput {
    grid_x: u32,
    grid_y: u32,
    // u16 keeps the input compact while still letting the fuzzer push
    // px/py just past TILE_SIZE; full u32 would burn the entire budget
    // on extreme values that all hit the same OOB branch.
    px: u16,
    py: u16,
    r: u16,
    g: u16,
    b: u16,
    a: u16,
}

fuzz_target!(|input: WriteInput| {
    let tile = match Tile::alloc(input.grid_x, input.grid_y) {
        Some(t) => t,
        None => return,
    };

    let px = input.px as u32;
    let py = input.py as u32;

    let result = tile.write_pixel_bits(px, py, input.r, input.g, input.b, input.a);
    let oob = px >= TILE_SIZE || py >= TILE_SIZE;
    assert!(
        !(oob && result.is_ok()),
        "OOB write ({px},{py}) returned Ok"
    );

    if result.is_ok() {
        let read_back = tile.read_pixel_bits(px, py);
        if let Ok(pixel) = read_back {
            assert_eq!(
                pixel,
                [input.r, input.g, input.b, input.a],
                "round-trip mismatch at ({px},{py})"
            );
        }
    }
});
