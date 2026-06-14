// SPDX-License-Identifier: AGPL-3.0-or-later
//
// codec -- PNG encode/decode for straight-alpha RGBA8 buffers. Decode is
// bounded by MAX_DIM to contain the decoder attack surface.

/// Maximum width or height accepted on decode (guards against
/// decompression-bomb dimensions).
pub const MAX_DIM: u32 = 16_384;

/// Encode `rgba` (length `w * h * 4`, straight alpha) to a PNG file.
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

/// Decode a PNG file into `(rgba, w, h)`, rejecting oversized images.
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
