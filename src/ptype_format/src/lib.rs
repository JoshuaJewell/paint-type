// SPDX-License-Identifier: AGPL-3.0-or-later
//
// ptype_format — reference encoder/decoder for paint-type's native RGBA16F
// `.ptype` container (draft v1).
//
//! # The `.ptype` native format (draft v1)
//!
//! paint-type's compute core stores a canvas as a stack of **layers**, each
//! holding a *sparse* map of 64×64 **tiles**, and each tile holding
//! `64 * 64 * 4` RGBA16F scalars. Crucially, those scalars are kept as the raw
//! **`u16` bit-patterns of IEEE-754 half-floats** — never as decoded `f32`s
//! (see `src/backends/cpu/main.zig`, `src/interface/ffi/src/main.zig` and
//! `src/ephapax/src/lib.rs` in `JoshuaJewell/paint-type`).
//!
//! This crate serialises that model verbatim. Because we move the exact `u16`
//! bit-patterns to and from disk and never interpret them as floats, the
//! round-trip is **lossless by construction** — it preserves `NaN`, `±Inf`,
//! `−0.0` and every other half-float encoding bit-for-bit. The
//! [`encode`]/[`decode`] pair is therefore an involution on every well-formed
//! [`Canvas`], and re-encoding a decoded canvas yields byte-identical output
//! (the round-trip byte-equality property exercised in the test module and the
//! acceptance criteria of paint-type issue #13).
//!
//! ## Status
//!
//! Draft. The full versioned spec is a v1.0.0 obligation; this is the
//! issue-#13 draft required before `pt_io_save` for the native format can
//! land. The companion prose spec is `docs/spec/ptype-format.adoc`.
//!
//! ## Endianness
//!
//! Every multi-byte scalar is **little-endian**. Half-float scalars are
//! written as their `u16` bit-pattern (also little-endian), with no float
//! interpretation at any point.

#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use std::fmt;

/// Tile edge length in pixels. Matches `TILE_SIZE` in paint-type's CPU backend.
pub const TILE_SIZE: u32 = 64;

/// Channels per pixel (R, G, B, A). Matches `TILE_CHANNELS`.
pub const TILE_CHANNELS: u32 = 4;

/// Scalars per tile: `TILE_SIZE * TILE_SIZE * TILE_CHANNELS` = 16384.
/// Matches `TILE_SCALARS` in paint-type's CPU backend.
pub const TILE_SCALARS: usize =
    (TILE_SIZE as usize) * (TILE_SIZE as usize) * (TILE_CHANNELS as usize);

/// Canvas pixel format discriminant. `0 = RGBA16F` — matches `Canvas.format`
/// in the CPU backend. Only RGBA16F is defined for draft v1.
pub const FORMAT_RGBA16F: u32 = 0;

/// 8-byte container signature.
///
/// Mirrors PNG's design: a high-bit byte (`0x89`) catches 7-bit transports,
/// the legible `PTYPE` aids `hexdump` inspection, and the trailing `CR LF`
/// catches naive newline translation.
pub const MAGIC: [u8; 8] = [0x89, b'P', b'T', b'Y', b'P', b'E', 0x0D, 0x0A];

/// On-disk format version understood by this crate.
pub const VERSION: u16 = 1;

/// Container flags. Draft v1 defines only `0` (uncompressed). Bit 0 is
/// reserved for a future DEFLATE payload; encountering any unknown flag is a
/// hard decode error rather than a silent ignore.
pub const FLAGS_NONE: u16 = 0;

/// Layer blend mode. Discriminants match paint-type's `BlendMode` enum.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlendMode {
    Normal = 0,
    Multiply = 1,
    Screen = 2,
}

impl BlendMode {
    /// Wire discriminant.
    pub fn to_u32(self) -> u32 {
        self as u32
    }

    /// Parse a wire discriminant. Unknown values are rejected (strict).
    pub fn from_u32(v: u32) -> Result<Self, DecodeError> {
        match v {
            0 => Ok(BlendMode::Normal),
            1 => Ok(BlendMode::Multiply),
            2 => Ok(BlendMode::Screen),
            other => Err(DecodeError::UnknownBlendMode(other)),
        }
    }
}

/// Sparse-tile grid coordinate (tile units, not pixels).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct TileKey {
    pub tx: u32,
    pub ty: u32,
}

/// A single 64×64 RGBA16F tile: `TILE_SCALARS` half-float bit-patterns,
/// row-major, channel-interleaved (R,G,B,A,R,G,B,A,…).
#[derive(Clone)]
pub struct Tile {
    pub pixels: [u16; TILE_SCALARS],
}

impl Tile {
    /// A fully-transparent (all-zero) tile.
    pub fn zeroed() -> Self {
        Tile {
            pixels: [0u16; TILE_SCALARS],
        }
    }
}

impl PartialEq for Tile {
    fn eq(&self, other: &Self) -> bool {
        self.pixels[..] == other.pixels[..]
    }
}
impl Eq for Tile {}

impl fmt::Debug for Tile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Avoid dumping 16k scalars; summarise.
        let nonzero = self.pixels.iter().filter(|&&p| p != 0).count();
        write!(
            f,
            "Tile {{ {} non-zero / {} scalars }}",
            nonzero, TILE_SCALARS
        )
    }
}

/// One layer: name, visibility, opacity, blend mode, and its sparse tiles.
/// Tiles live in a `BTreeMap` so iteration order — and therefore the encoded
/// byte stream — is deterministic.
#[derive(Clone, Debug, PartialEq)]
pub struct Layer {
    pub name: String,
    pub visible: bool,
    pub opacity: f64,
    pub blend: BlendMode,
    pub tiles: BTreeMap<TileKey, Tile>,
}

impl Layer {
    /// A visible, fully-opaque, normal-blend layer with no tiles.
    pub fn new(name: impl Into<String>) -> Self {
        Layer {
            name: name.into(),
            visible: true,
            opacity: 1.0,
            blend: BlendMode::Normal,
            tiles: BTreeMap::new(),
        }
    }
}

/// A full canvas: dimensions, pixel format, background colour, layer stack.
#[derive(Clone, Debug, PartialEq)]
pub struct Canvas {
    pub width: u32,
    pub height: u32,
    /// Pixel format discriminant. Draft v1 only encodes [`FORMAT_RGBA16F`].
    pub format: u32,
    /// RGBA background, stored as the `[4]f32` paint-type keeps it as.
    pub background: [f32; 4],
    pub layers: Vec<Layer>,
}

impl Canvas {
    /// An empty RGBA16F canvas with a transparent background and no layers.
    pub fn new(width: u32, height: u32) -> Self {
        Canvas {
            width,
            height,
            format: FORMAT_RGBA16F,
            background: [0.0; 4],
            layers: Vec::new(),
        }
    }
}

// ----------------------------------------------------------------------------
// Errors
// ----------------------------------------------------------------------------

/// Why a byte slice failed to decode as a `.ptype` container. Every malformed
/// input maps to one of these — `decode` never panics on bad data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// First 8 bytes were not [`MAGIC`].
    BadMagic,
    /// Version field was not one this crate understands.
    UnsupportedVersion(u16),
    /// Flags field carried a bit this crate does not implement.
    UnsupportedFlags(u16),
    /// `format` field was not a value draft v1 defines.
    UnsupportedFormat(u32),
    /// Recorded tile geometry did not match this build's constants.
    TileGeometryMismatch {
        got: (u32, u32),
        expected: (u32, u32),
    },
    /// Blend-mode discriminant was outside the defined set.
    UnknownBlendMode(u32),
    /// A length/count field would require reading past the end of input.
    UnexpectedEof { context: &'static str },
    /// A UTF-8 layer name was not valid UTF-8.
    InvalidUtf8 { context: &'static str },
    /// Trailing bytes remained after a complete canvas was decoded.
    TrailingBytes { extra: usize },
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::BadMagic => write!(f, "bad magic: not a .ptype container"),
            DecodeError::UnsupportedVersion(v) => write!(f, "unsupported .ptype version {v}"),
            DecodeError::UnsupportedFlags(x) => write!(f, "unsupported .ptype flags {x:#06x}"),
            DecodeError::UnsupportedFormat(x) => write!(f, "unsupported pixel format {x}"),
            DecodeError::TileGeometryMismatch { got, expected } => write!(
                f,
                "tile geometry mismatch: file has {}x{}c, this build expects {}x{}c",
                got.0, got.1, expected.0, expected.1
            ),
            DecodeError::UnknownBlendMode(x) => write!(f, "unknown blend mode {x}"),
            DecodeError::UnexpectedEof { context } => {
                write!(f, "unexpected end of input while reading {context}")
            }
            DecodeError::InvalidUtf8 { context } => write!(f, "invalid UTF-8 in {context}"),
            DecodeError::TrailingBytes { extra } => {
                write!(f, "{extra} trailing byte(s) after canvas")
            }
        }
    }
}

impl std::error::Error for DecodeError {}

// ----------------------------------------------------------------------------
// Encode
// ----------------------------------------------------------------------------

/// Serialise a [`Canvas`] to the draft-v1 `.ptype` byte layout.
///
/// Deterministic: layers are written in stack order and tiles in `TileKey`
/// order, so two equal canvases always encode to identical bytes.
pub fn encode(canvas: &Canvas) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&FLAGS_NONE.to_le_bytes());
    out.extend_from_slice(&canvas.format.to_le_bytes());
    out.extend_from_slice(&canvas.width.to_le_bytes());
    out.extend_from_slice(&canvas.height.to_le_bytes());
    for c in canvas.background {
        out.extend_from_slice(&c.to_le_bytes());
    }
    // Tile geometry, recorded so a reader can validate (and a future variable
    // tile size has somewhere to live).
    out.extend_from_slice(&TILE_SIZE.to_le_bytes());
    out.extend_from_slice(&TILE_CHANNELS.to_le_bytes());

    out.extend_from_slice(&(canvas.layers.len() as u32).to_le_bytes());
    for layer in &canvas.layers {
        let name = layer.name.as_bytes();
        out.extend_from_slice(&(name.len() as u32).to_le_bytes());
        out.extend_from_slice(name);
        out.push(u8::from(layer.visible));
        out.extend_from_slice(&layer.opacity.to_le_bytes());
        out.extend_from_slice(&layer.blend.to_u32().to_le_bytes());

        out.extend_from_slice(&(layer.tiles.len() as u32).to_le_bytes());
        for (key, tile) in &layer.tiles {
            out.extend_from_slice(&key.tx.to_le_bytes());
            out.extend_from_slice(&key.ty.to_le_bytes());
            for scalar in tile.pixels {
                out.extend_from_slice(&scalar.to_le_bytes());
            }
        }
    }
    out
}

// ----------------------------------------------------------------------------
// Decode
// ----------------------------------------------------------------------------

/// A bounds-checked little-endian cursor. Every read is fallible; nothing here
/// can panic on a short or malformed buffer.
struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    fn take(&mut self, n: usize, context: &'static str) -> Result<&'a [u8], DecodeError> {
        let end = self
            .pos
            .checked_add(n)
            .ok_or(DecodeError::UnexpectedEof { context })?;
        if end > self.buf.len() {
            return Err(DecodeError::UnexpectedEof { context });
        }
        let slice = &self.buf[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn u8(&mut self, context: &'static str) -> Result<u8, DecodeError> {
        Ok(self.take(1, context)?[0])
    }

    fn u16(&mut self, context: &'static str) -> Result<u16, DecodeError> {
        let b = self.take(2, context)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    fn u32(&mut self, context: &'static str) -> Result<u32, DecodeError> {
        let b = self.take(4, context)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn f32(&mut self, context: &'static str) -> Result<f32, DecodeError> {
        let b = self.take(4, context)?;
        Ok(f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn f64(&mut self, context: &'static str) -> Result<f64, DecodeError> {
        let b = self.take(8, context)?;
        Ok(f64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    fn remaining(&self) -> usize {
        self.buf.len() - self.pos
    }
}

/// Parse a draft-v1 `.ptype` byte slice back into a [`Canvas`].
///
/// Returns a typed [`DecodeError`] for every malformed input — truncation, bad
/// magic, unknown version/flags/format/blend, bad UTF-8, or trailing garbage.
pub fn decode(bytes: &[u8]) -> Result<Canvas, DecodeError> {
    let mut r = Reader::new(bytes);

    let magic = r.take(MAGIC.len(), "magic")?;
    if magic != MAGIC {
        return Err(DecodeError::BadMagic);
    }
    let version = r.u16("version")?;
    if version != VERSION {
        return Err(DecodeError::UnsupportedVersion(version));
    }
    let flags = r.u16("flags")?;
    if flags != FLAGS_NONE {
        return Err(DecodeError::UnsupportedFlags(flags));
    }
    let format = r.u32("format")?;
    if format != FORMAT_RGBA16F {
        return Err(DecodeError::UnsupportedFormat(format));
    }
    let width = r.u32("width")?;
    let height = r.u32("height")?;
    let mut background = [0.0f32; 4];
    for (i, c) in background.iter_mut().enumerate() {
        *c = r.f32(["bg.r", "bg.g", "bg.b", "bg.a"][i])?;
    }

    let tile_size = r.u32("tile_size")?;
    let tile_channels = r.u32("tile_channels")?;
    if (tile_size, tile_channels) != (TILE_SIZE, TILE_CHANNELS) {
        return Err(DecodeError::TileGeometryMismatch {
            got: (tile_size, tile_channels),
            expected: (TILE_SIZE, TILE_CHANNELS),
        });
    }

    let layer_count = r.u32("layer_count")?;
    // Never size an allocation from the untrusted `layer_count` (CWE-789): a
    // ~50-byte file can claim 0xFFFF_FFFF layers, and ANY eager reservation
    // from that value OOM-aborts (~256 GiB), violating the "decode never panics
    // on bad data" contract (found by the INV-1 fuzzer,
    // fuzz/fuzz_targets/decode_total.rs). Start empty and let the Vec grow as
    // layers are actually read; the real count is bounded by the input length,
    // and amortised growth is negligible for a reference decoder.
    let mut layers = Vec::new();
    for _ in 0..layer_count {
        let name_len = r.u32("layer name length")? as usize;
        let name_bytes = r.take(name_len, "layer name")?;
        let name = std::str::from_utf8(name_bytes)
            .map_err(|_| DecodeError::InvalidUtf8 {
                context: "layer name",
            })?
            .to_owned();
        let visible = r.u8("layer visible")? != 0;
        let opacity = r.f64("layer opacity")?;
        let blend = BlendMode::from_u32(r.u32("layer blend")?)?;

        let tile_count = r.u32("tile_count")?;
        let mut tiles = BTreeMap::new();
        for _ in 0..tile_count {
            let tx = r.u32("tile.tx")?;
            let ty = r.u32("tile.ty")?;
            let mut pixels = [0u16; TILE_SCALARS];
            for scalar in pixels.iter_mut() {
                *scalar = r.u16("tile pixel")?;
            }
            tiles.insert(TileKey { tx, ty }, Tile { pixels });
        }

        layers.push(Layer {
            name,
            visible,
            opacity,
            blend,
            tiles,
        });
    }

    if r.remaining() != 0 {
        return Err(DecodeError::TrailingBytes {
            extra: r.remaining(),
        });
    }

    Ok(Canvas {
        width,
        height,
        format,
        background,
        layers,
    })
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a tile whose scalars cycle through a caller-supplied pattern.
    fn patterned_tile(pattern: &[u16]) -> Tile {
        let mut t = Tile::zeroed();
        for (i, p) in t.pixels.iter_mut().enumerate() {
            *p = pattern[i % pattern.len()];
        }
        t
    }

    fn sample_canvas() -> Canvas {
        let mut c = Canvas::new(256, 128);
        c.background = [0.1, 0.2, 0.3, 1.0];

        let mut base = Layer::new("background");
        base.tiles
            .insert(TileKey { tx: 0, ty: 0 }, patterned_tile(&[0x3C00, 0x0000]));
        base.tiles.insert(
            TileKey { tx: 3, ty: 1 },
            patterned_tile(&[0xFFFF, 0x1234, 0x00FF]),
        );

        let mut over = Layer::new("ink ✏");
        over.visible = false;
        over.opacity = 0.42;
        over.blend = BlendMode::Multiply;
        over.tiles
            .insert(TileKey { tx: 2, ty: 2 }, patterned_tile(&[0x8000, 0x7C00]));

        c.layers.push(base);
        c.layers.push(over);
        c
    }

    #[test]
    fn roundtrip_empty_canvas() {
        let c = Canvas::new(64, 64);
        let bytes = encode(&c);
        assert_eq!(decode(&bytes).unwrap(), c);
    }

    #[test]
    fn roundtrip_multi_layer_multi_tile() {
        let c = sample_canvas();
        let decoded = decode(&encode(&c)).unwrap();
        assert_eq!(decoded, c);
    }

    /// The defining property: NaN / ±Inf / −0 / max-normal half-float bit
    /// patterns survive a round-trip *because we never interpret them as
    /// floats*. A naive f32 round-trip would canonicalise NaNs and lose this.
    #[test]
    fn roundtrip_preserves_half_float_edge_patterns() {
        let edges = [
            0x0000, // +0
            0x8000, // -0
            0x3C00, // 1.0
            0x7BFF, // max normal
            0x0400, // min normal
            0x0001, // min subnormal
            0x7C00, // +Inf
            0xFC00, // -Inf
            0x7E00, // a quiet NaN
            0xFDFF, // a signalling-range NaN payload
            0xFFFF, // all bits set
        ];
        let mut c = Canvas::new(64, 64);
        let mut layer = Layer::new("edges");
        layer
            .tiles
            .insert(TileKey { tx: 7, ty: 9 }, patterned_tile(&edges));
        c.layers.push(layer);

        let decoded = decode(&encode(&c)).unwrap();
        let original = &c.layers[0].tiles[&TileKey { tx: 7, ty: 9 }];
        let got = &decoded.layers[0].tiles[&TileKey { tx: 7, ty: 9 }];
        assert_eq!(got.pixels[..], original.pixels[..]);
    }

    /// Encoding is a deterministic function of the canvas, so re-encoding a
    /// decoded canvas is byte-identical (issue #13 byte-equality criterion).
    #[test]
    fn byte_stability_under_reencode() {
        let c = sample_canvas();
        let once = encode(&c);
        let twice = encode(&decode(&once).unwrap());
        assert_eq!(once, twice);
    }

    /// Lock the wire prefix so an accidental layout change is caught.
    #[test]
    fn golden_header_prefix() {
        let c = Canvas::new(0x0102_0304, 0x0506_0708);
        let bytes = encode(&c);
        let expected: &[u8] = &[
            0x89, b'P', b'T', b'Y', b'P', b'E', 0x0D, 0x0A, // magic
            0x01, 0x00, // version 1
            0x00, 0x00, // flags 0
            0x00, 0x00, 0x00, 0x00, // format RGBA16F
            0x04, 0x03, 0x02, 0x01, // width  (LE)
            0x08, 0x07, 0x06, 0x05, // height (LE)
        ];
        assert_eq!(&bytes[..expected.len()], expected);
    }

    #[test]
    fn reject_bad_magic() {
        let mut bytes = encode(&Canvas::new(8, 8));
        bytes[0] ^= 0xFF;
        assert_eq!(decode(&bytes), Err(DecodeError::BadMagic));
    }

    #[test]
    fn reject_unsupported_version() {
        let mut bytes = encode(&Canvas::new(8, 8));
        bytes[8] = 0xFE; // low byte of the version field
        assert!(matches!(
            decode(&bytes),
            Err(DecodeError::UnsupportedVersion(_))
        ));
    }

    /// Truncation at *every* prefix length must error, never panic. Uses a
    /// single-tile canvas to keep the O(n) sweep cheap while still crossing the
    /// header, name, tile-header and mid-tile boundaries.
    #[test]
    fn reject_truncation_at_all_lengths() {
        let mut c = Canvas::new(8, 8);
        let mut layer = Layer::new("t");
        layer.tiles.insert(TileKey { tx: 0, ty: 0 }, Tile::zeroed());
        c.layers.push(layer);
        let bytes = encode(&c);
        for len in 0..bytes.len() {
            match decode(&bytes[..len]) {
                Err(_) => {}
                Ok(_) => panic!("a {len}-byte truncated prefix decoded as a full canvas"),
            }
        }
    }

    #[test]
    fn reject_trailing_bytes() {
        let mut bytes = encode(&Canvas::new(8, 8));
        bytes.push(0x00);
        assert!(matches!(
            decode(&bytes),
            Err(DecodeError::TrailingBytes { extra: 1 })
        ));
    }

    #[test]
    fn reject_unknown_blend_mode() {
        let mut c = Canvas::new(8, 8);
        c.layers.push(Layer::new("x"));
        let mut bytes = encode(&c);
        // Fixed header up to and including tile_channels, then layer_count,
        // then the single layer's (name_len + name "x" + visible + opacity)
        // before its 4-byte blend field.
        let header = MAGIC.len() + 2 + 2 + 4 + 4 + 4 + 16 + 4 + 4; // magic..tile_channels
        let first_layer = header + 4; // skip layer_count
        let blend_off = first_layer + 4 + 1 + 1 + 8; // name_len + "x" + visible + opacity
        bytes[blend_off] = 0x09; // not a defined blend mode
        assert_eq!(decode(&bytes), Err(DecodeError::UnknownBlendMode(9)));
    }

    #[test]
    fn blend_modes_roundtrip() {
        for (mode, disc) in [
            (BlendMode::Normal, 0u32),
            (BlendMode::Multiply, 1),
            (BlendMode::Screen, 2),
        ] {
            assert_eq!(mode.to_u32(), disc);
            assert_eq!(BlendMode::from_u32(disc).unwrap(), mode);
        }
        assert_eq!(
            BlendMode::from_u32(3),
            Err(DecodeError::UnknownBlendMode(3))
        );
    }

    /// A huge `layer_count` must NOT trigger an eager multi-gigabyte
    /// `Vec::with_capacity` (which OOM-aborts the process). The INV-1 fuzzer
    /// (`fuzz/fuzz_targets/decode_total.rs`) found exactly that: a 52-byte file
    /// claiming `0xFFFF_FFFF` layers made `decode` try to reserve ~256 GiB.
    /// Decode must cap the preallocation to what the input can hold and fail
    /// with a typed error on the (absent) layer data — never abort.
    #[test]
    fn reject_oversized_layer_count_without_oom() {
        let mut bytes = encode(&Canvas::new(8, 8)); // 0 real layers
        // layer_count is the final u32: magic..tile_channels, then layer_count.
        let layer_count_off = MAGIC.len() + 2 + 2 + 4 + 4 + 4 + 16 + 4 + 4;
        bytes[layer_count_off..layer_count_off + 4]
            .copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(matches!(
            decode(&bytes),
            Err(DecodeError::UnexpectedEof { .. })
        ));
    }
}
