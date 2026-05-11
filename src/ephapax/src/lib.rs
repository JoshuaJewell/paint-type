// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Ephapax — the Rust side of the paint.type tile primitive.
//
// This crate is the consumer of libpt (the Zig FFI). It exposes a safe
// Rust API for the same operations that Idris2 sees through Abi.Foreign:
// allocate a 64x64 RGBA16F tile, fill it with a solid colour, read back
// pixels, free it.
//
// Linear ownership: the `Tile` newtype owns its raw pointer and frees
// it on Drop. `Tile` is non-Copy and non-Clone, so a tile cannot be
// double-freed through the safe API.
//
// f16 caveat: Rust's `f16` primitive is still unstable on the stable
// channel as of the time of writing. This crate keeps the public API on
// `u16` and documents that those values carry the bit patterns of IEEE
// 754 binary16 numbers (matching what libpt and Idris2 traffic in).
// Helpers `f32_to_f16_bits` and `f16_bits_to_f32` provide convenient
// conversion using only stable Rust facilities.

#![forbid(unsafe_op_in_unsafe_fn)]
#![warn(missing_docs)]

//! Ephapax: the native image core for paint.type.
//!
//! See the top-of-file comments for design rationale.

//==============================================================================
// FFI declarations (must match libpt — see src/interface/ffi/src/main.zig)
//==============================================================================

unsafe extern "C" {
    fn pt_tile_alloc(x: u32, y: u32) -> u64;
    fn pt_tile_free(tile_ptr: u64);
    fn pt_tile_fill(tile_ptr: u64, r: u16, g: u16, b: u16, a: u16) -> u32;
    fn pt_tile_read_pixel(
        tile_ptr: u64,
        px: u32,
        py: u32,
        out_r: u64,
        out_g: u64,
        out_b: u64,
        out_a: u64,
    ) -> u32;
    fn pt_is_initialized(tile_ptr: u64) -> u32;
}

//==============================================================================
// Constants (mirror Abi.Types and src/main.zig)
//==============================================================================

/// Tile edge length in pixels.
pub const TILE_SIZE: u32 = 64;

/// Channels per pixel for RGBA16F.
pub const TILE_CHANNELS: u32 = 4;

/// Total bytes in a tile's pixel buffer (64 * 64 * 4 * 2 = 32768).
pub const TILE_PIXEL_BYTES: usize =
    (TILE_SIZE as usize) * (TILE_SIZE as usize) * (TILE_CHANNELS as usize) * 2;

//==============================================================================
// Result codes (mirror libpt's `Result` enum)
//==============================================================================

const RESULT_OK: u32 = 0;

/// Errors that can be returned by safe wrappers in this crate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TileError {
    /// libpt rejected the inputs (null pointer, out-of-bounds pixel, etc.).
    InvalidParam,
    /// libpt reported a generic error.
    LibError,
    /// libpt reported it was busy.
    Busy,
}

impl TileError {
    fn from_code(code: u32) -> Self {
        match code {
            2 => TileError::InvalidParam,
            3 => TileError::Busy,
            _ => TileError::LibError,
        }
    }

    /// A short, static description suitable for `&'static str` callers.
    pub fn message(self) -> &'static str {
        match self {
            TileError::InvalidParam => "invalid parameter",
            TileError::LibError => "libpt error",
            TileError::Busy => "libpt busy",
        }
    }
}

impl core::fmt::Display for TileError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for TileError {}

//==============================================================================
// f16 bit-pattern helpers
//==============================================================================

/// Convert an f32 to the bit pattern of the nearest IEEE 754 binary16
/// value (round to nearest, ties to even). Stable-Rust implementation.
///
/// This handles normals, denormals, zero, infinity, NaN, and overflow
/// (which becomes signed infinity). It is the inverse of
/// [`f16_bits_to_f32`] within the rounding precision of binary16.
pub fn f32_to_f16_bits(value: f32) -> u16 {
    let bits = value.to_bits();
    let sign = ((bits >> 31) & 0x1) as u16;
    let exp = ((bits >> 23) & 0xFF) as i32;
    let mant = bits & 0x007F_FFFF;

    if exp == 0xFF {
        // NaN or Inf.
        let new_mant = if mant != 0 {
            // Preserve a non-zero mantissa to keep NaN-ness.
            ((mant >> 13) as u16) | 0x0200
        } else {
            0
        };
        return (sign << 15) | 0x7C00 | new_mant;
    }

    // Subtract f32 bias (127) and add f16 bias (15).
    let new_exp = exp - 127 + 15;

    if new_exp >= 0x1F {
        // Overflow — saturate to infinity.
        return (sign << 15) | 0x7C00;
    }

    if new_exp <= 0 {
        // Subnormal in f16 (or underflow to zero).
        if new_exp < -10 {
            return sign << 15;
        }
        // Add the implicit leading 1 to the mantissa, then shift.
        let mant_with_lead = mant | 0x0080_0000;
        let shift = 14 - new_exp; // == 1 - new_exp + 13
        let shifted = mant_with_lead >> shift;
        // Round to nearest, ties to even.
        let half_bit = 1u32 << (shift - 1);
        let lower_mask = (1u32 << shift) - 1;
        let lower_bits = mant_with_lead & lower_mask;
        let mut rounded = shifted;
        if lower_bits > half_bit
            || (lower_bits == half_bit && (shifted & 1) == 1)
        {
            rounded += 1;
        }
        return (sign << 15) | (rounded as u16);
    }

    // Normal range. Round mantissa to 10 bits.
    let half_bit = 1u32 << 12;
    let lower_mask = (1u32 << 13) - 1;
    let mut new_mant = mant >> 13;
    let lower_bits = mant & lower_mask;
    if lower_bits > half_bit
        || (lower_bits == half_bit && (new_mant & 1) == 1)
    {
        new_mant += 1;
        if new_mant == 0x400 {
            // Mantissa overflowed back to 1.0 — bump the exponent.
            new_mant = 0;
            let bumped_exp = new_exp + 1;
            if bumped_exp >= 0x1F {
                return (sign << 15) | 0x7C00;
            }
            return (sign << 15) | ((bumped_exp as u16) << 10);
        }
    }
    (sign << 15) | ((new_exp as u16) << 10) | (new_mant as u16)
}

/// Convert an IEEE 754 binary16 bit pattern back to an f32.
pub fn f16_bits_to_f32(bits: u16) -> f32 {
    let sign = (bits >> 15) as u32;
    let exp = ((bits >> 10) & 0x1F) as u32;
    let mant = (bits & 0x03FF) as u32;

    let f32_bits = if exp == 0 {
        if mant == 0 {
            sign << 31
        } else {
            // Subnormal: normalise.
            let mut e: i32 = -1;
            let mut m = mant;
            while (m & 0x0400) == 0 {
                m <<= 1;
                e -= 1;
            }
            let new_exp = (127 + e + 1) as u32;
            let new_mant = (m & 0x03FF) << 13;
            (sign << 31) | (new_exp << 23) | new_mant
        }
    } else if exp == 0x1F {
        // Inf or NaN.
        (sign << 31) | 0x7F80_0000 | (mant << 13)
    } else {
        let new_exp = exp - 15 + 127;
        (sign << 31) | (new_exp << 23) | (mant << 13)
    };

    f32::from_bits(f32_bits)
}

//==============================================================================
// Tile — safe wrapper around the FFI handle
//==============================================================================

/// A 64x64 RGBA16F tile owned by the calling Rust code.
///
/// Linear ownership: there is exactly one `Tile` value for each underlying
/// `pt_tile_alloc` allocation. `Tile` is intentionally not `Copy`, not
/// `Clone`, and exposes no API that hands out the raw pointer. On `Drop`
/// it calls `pt_tile_free` exactly once.
pub struct Tile {
    raw: u64,
}

// SAFETY: A Tile uniquely owns its allocation — moving it across threads
// is fine because there is only one owner at a time. We do NOT implement
// Sync; concurrent access from multiple threads would require interior
// synchronisation that libpt does not provide.
unsafe impl Send for Tile {}

impl Tile {
    /// Allocate a 64x64 RGBA16F tile at grid position `(x, y)`.
    /// Returns `None` on out-of-memory.
    pub fn alloc(x: u32, y: u32) -> Option<Tile> {
        // SAFETY: pt_tile_alloc has no preconditions on its arguments.
        // It returns 0 on OOM and a valid pointer otherwise.
        let raw = unsafe { pt_tile_alloc(x, y) };
        if raw == 0 {
            None
        } else {
            Some(Tile { raw })
        }
    }

    /// Returns true iff libpt still considers this tile live.
    /// (Always true for any `Tile` you can call this on, by construction;
    /// kept as a sanity check / debugging aid.)
    pub fn is_initialized(&self) -> bool {
        // SAFETY: self.raw was obtained from pt_tile_alloc and has not
        // been freed (we hold the only owner). pt_is_initialized accepts
        // any u64 and never dereferences past the magic-word check.
        unsafe { pt_is_initialized(self.raw) == 1 }
    }

    /// Fill every pixel of the tile with a single RGBA16F colour.
    ///
    /// Channel arguments are the bit patterns of f16 values. Use
    /// [`f32_to_f16_bits`] if you have f32 values.
    pub fn fill_bits(&self, r: u16, g: u16, b: u16, a: u16) -> Result<(), TileError> {
        // SAFETY: self.raw is a live tile; pt_tile_fill validates non-null
        // and magic internally.
        let code = unsafe { pt_tile_fill(self.raw, r, g, b, a) };
        if code == RESULT_OK {
            Ok(())
        } else {
            Err(TileError::from_code(code))
        }
    }

    /// Convenience: fill with f32 channel values, converted to f16 first.
    pub fn fill_f32(&self, r: f32, g: f32, b: f32, a: f32) -> Result<(), TileError> {
        self.fill_bits(
            f32_to_f16_bits(r),
            f32_to_f16_bits(g),
            f32_to_f16_bits(b),
            f32_to_f16_bits(a),
        )
    }

    /// Read one pixel from the tile. Returns the four channel bit patterns
    /// in (R, G, B, A) order.
    pub fn read_pixel_bits(&self, px: u32, py: u32) -> Result<[u16; 4], TileError> {
        let mut r: u16 = 0;
        let mut g: u16 = 0;
        let mut b: u16 = 0;
        let mut a: u16 = 0;

        // SAFETY: All four destination addresses point to live u16s on
        // this stack frame; pt_tile_read_pixel validates the tile and
        // bounds internally.
        let code = unsafe {
            pt_tile_read_pixel(
                self.raw,
                px,
                py,
                &mut r as *mut u16 as u64,
                &mut g as *mut u16 as u64,
                &mut b as *mut u16 as u64,
                &mut a as *mut u16 as u64,
            )
        };
        if code == RESULT_OK {
            Ok([r, g, b, a])
        } else {
            Err(TileError::from_code(code))
        }
    }

    /// Read one pixel and return it as f32 channels.
    pub fn read_pixel_f32(&self, px: u32, py: u32) -> Result<[f32; 4], TileError> {
        let bits = self.read_pixel_bits(px, py)?;
        Ok([
            f16_bits_to_f32(bits[0]),
            f16_bits_to_f32(bits[1]),
            f16_bits_to_f32(bits[2]),
            f16_bits_to_f32(bits[3]),
        ])
    }
}

impl Drop for Tile {
    fn drop(&mut self) {
        // SAFETY: We are the unique owner. pt_tile_free is a no-op on
        // null and self-defends against double-free via a magic word.
        unsafe { pt_tile_free(self.raw) };
    }
}

impl core::fmt::Debug for Tile {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("Tile")
            .field("raw", &format_args!("0x{:016x}", self.raw))
            .finish()
    }
}

//==============================================================================
// Tests
//==============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_alloc_and_free() {
        let tile = Tile::alloc(0, 0).expect("alloc must succeed");
        assert!(tile.is_initialized());
        // Drop runs at end of scope; valgrind / sanitizers should be clean.
    }

    #[test]
    fn test_fill_and_read() {
        let tile = Tile::alloc(2, 3).expect("alloc");

        // Red: r=1.0, g=0.0, b=0.0, a=1.0.
        tile.fill_f32(1.0, 0.0, 0.0, 1.0).expect("fill");

        let pixel = tile.read_pixel_f32(0, 0).expect("read (0,0)");
        assert_eq!(pixel[0], 1.0_f32);
        assert_eq!(pixel[1], 0.0_f32);
        assert_eq!(pixel[2], 0.0_f32);
        assert_eq!(pixel[3], 1.0_f32);

        // Read elsewhere — every pixel should carry the same fill colour.
        let mid = tile.read_pixel_f32(32, 32).expect("read (32,32)");
        assert_eq!(mid, pixel);

        let corner = tile
            .read_pixel_f32(TILE_SIZE - 1, TILE_SIZE - 1)
            .expect("read (63,63)");
        assert_eq!(corner, pixel);
    }

    #[test]
    fn test_drop_frees() {
        // Allocating and dropping many tiles in a tight loop should not
        // leak nor crash. If pt_tile_free were buggy we would expect
        // either OOM or a heap corruption crash here.
        for i in 0..512 {
            let t = Tile::alloc(i, i).expect("alloc");
            t.fill_bits(0x3C00, 0x0000, 0x0000, 0x3C00).expect("fill"); // f16 1.0, 0.0, 0.0, 1.0
            // Drop t.
        }
    }

    #[test]
    fn test_out_of_bounds_read() {
        let tile = Tile::alloc(0, 0).expect("alloc");
        let err = tile
            .read_pixel_bits(TILE_SIZE, 0)
            .expect_err("must reject px == TILE_SIZE");
        assert_eq!(err, TileError::InvalidParam);

        let err2 = tile
            .read_pixel_bits(0, 9999)
            .expect_err("must reject huge py");
        assert_eq!(err2, TileError::InvalidParam);
    }

    #[test]
    fn test_freshly_allocated_is_zero() {
        let tile = Tile::alloc(0, 0).expect("alloc");
        let pixel = tile.read_pixel_bits(0, 0).expect("read");
        assert_eq!(pixel, [0, 0, 0, 0]);
    }

    #[test]
    fn test_f16_round_trip_one() {
        let bits = f32_to_f16_bits(1.0);
        assert_eq!(bits, 0x3C00);
        assert_eq!(f16_bits_to_f32(bits), 1.0_f32);
    }

    #[test]
    fn test_f16_round_trip_zero() {
        assert_eq!(f32_to_f16_bits(0.0), 0x0000);
        assert_eq!(f16_bits_to_f32(0x0000), 0.0_f32);
    }

    #[test]
    fn test_f16_round_trip_half() {
        // 0.5 in f16 has exponent -1: 0 01110 0000000000 = 0x3800.
        assert_eq!(f32_to_f16_bits(0.5), 0x3800);
        assert_eq!(f16_bits_to_f32(0x3800), 0.5_f32);
    }

    #[test]
    fn test_f16_round_trip_negative() {
        let bits = f32_to_f16_bits(-1.0);
        assert_eq!(bits, 0xBC00);
        assert_eq!(f16_bits_to_f32(bits), -1.0_f32);
    }

    #[test]
    fn test_fill_with_arbitrary_color_round_trips() {
        let tile = Tile::alloc(7, 11).expect("alloc");
        // Use values that are exactly representable in f16.
        tile.fill_f32(0.25, 0.5, 0.75, 1.0).expect("fill");
        let pixel = tile.read_pixel_f32(17, 41).expect("read");
        assert_eq!(pixel, [0.25, 0.5, 0.75, 1.0]);
    }
}
