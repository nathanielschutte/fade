//! Cleans every image the server can see before anyone else gets it.
//!
//! Group pics and group pictures aren't end-to-end encrypted, so they pass
//! from one person to others through us. Each one is fully decoded (Rust's
//! memory-safe decoders, with strict size limits against decompression bombs)
//! and re-encoded as a fresh JPEG. Only the re-encoded file is stored and
//! served, so nothing the uploader hid survives: script or HTML in a
//! polyglot file, malformed data aimed at someone's image decoder, EXIF/GPS
//! metadata. Direct-chat pics are end-to-end encrypted; the server can't see
//! inside those, and serves them as opaque bytes.

use std::{io::Cursor, sync::OnceLock};

use image::{codecs::jpeg::JpegEncoder, imageops::FilterType, ImageFormat, ImageReader, Limits};
use tokio::sync::Semaphore;

use crate::error::AppError;

/// Largest width or height accepted from an upload (before resizing).
const MAX_INPUT_SIDE: u32 = 6000;
/// Memory one decode may use: a 6000x6000 RGBA image is ~144 MB, so this
/// rejects the largest of those; real phone photos fit easily.
const MAX_DECODE_BYTES: u64 = 96 * 1024 * 1024;
const JPEG_QUALITY: u8 = 85;

/// Decoding is CPU- and memory-heavy on a small server; one at a time.
fn gate() -> &'static Semaphore {
    static GATE: OnceLock<Semaphore> = OnceLock::new();
    GATE.get_or_init(|| Semaphore::new(1))
}

/// Decodes `data` (JPEG, PNG, or WebP only), shrinks it so neither side
/// exceeds `max_side`, and returns a new JPEG. Anything else is rejected.
pub fn reencode(data: &[u8], max_side: u32) -> Result<Vec<u8>, String> {
    let mut reader = ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .map_err(|_| "unreadable image")?;
    match reader.format() {
        Some(ImageFormat::Jpeg | ImageFormat::Png | ImageFormat::WebP) => {}
        _ => return Err("not a JPEG, PNG, or WebP image".into()),
    }
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_INPUT_SIDE);
    limits.max_image_height = Some(MAX_INPUT_SIDE);
    limits.max_alloc = Some(MAX_DECODE_BYTES);
    reader.limits(limits);
    let img = reader
        .decode()
        .map_err(|e| format!("couldn't decode: {e}"))?;
    if img.width() == 0 || img.height() == 0 {
        return Err("empty image".into());
    }
    let img = if img.width().max(img.height()) > max_side {
        img.resize(max_side, max_side, FilterType::Triangle)
    } else {
        img
    };
    let rgb = img.to_rgb8(); // drops alpha and any odd color layouts
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY)
        .encode_image(&rgb)
        .map_err(|e| format!("couldn't encode: {e}"))?;
    Ok(out)
}

/// `reencode` off the async workers, one at a time, with a user-facing error.
pub async fn clean(data: bytes::Bytes, max_side: u32) -> Result<Vec<u8>, AppError> {
    let _permit = gate()
        .acquire()
        .await
        .map_err(|_| AppError::Internal("image gate closed".into()))?;
    tokio::task::spawn_blocking(move || reencode(&data, max_side))
        .await?
        .map_err(|reason| {
            tracing::info!(%reason, "image rejected");
            AppError::bad("That doesn't look like a photo we can use. Try a different one.")
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageBuffer, Rgb};

    fn png(w: u32, h: u32) -> Vec<u8> {
        let img: ImageBuffer<Rgb<u8>, Vec<u8>> =
            ImageBuffer::from_fn(w, h, |x, y| Rgb([(x % 255) as u8, (y % 255) as u8, 90]));
        let mut out = Cursor::new(Vec::new());
        img.write_to(&mut out, ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn reencodes_to_a_fresh_jpeg_and_resizes() {
        let out = reencode(&png(2000, 1000), 1280).unwrap();
        assert!(out.starts_with(&[0xFF, 0xD8, 0xFF]));
        let back = image::load_from_memory(&out).unwrap();
        assert_eq!((back.width(), back.height()), (1280, 640));
    }

    #[test]
    fn hidden_payloads_do_not_survive() {
        // A real image with script and fake EXIF/GPS bolted on after the end.
        let mut poly = png(64, 64);
        poly.extend_from_slice(b"<script>alert(1)</script>Exif\0\0GPSLatitude");
        let out = reencode(&poly, 1280).unwrap();
        for needle in [&b"<script"[..], b"Exif", b"GPS"] {
            assert!(
                !out.windows(needle.len()).any(|w| w == needle),
                "{needle:?} survived"
            );
        }
    }

    #[test]
    fn rejects_non_images_bombs_and_garbage() {
        assert!(reencode(b"<svg onload=alert(1)>", 1280).is_err());
        assert!(reencode(b"GIF89a\x01\x00\x01\x00", 1280).is_err());
        assert!(reencode(&[0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0], 1280).is_err()); // truncated JPEG
                                                                              // A PNG header claiming 100000 x 100000 pixels.
        let mut bomb = png(1, 1);
        bomb[16..20].copy_from_slice(&100_000u32.to_be_bytes());
        bomb[20..24].copy_from_slice(&100_000u32.to_be_bytes());
        assert!(reencode(&bomb, 1280).is_err());
    }
}
