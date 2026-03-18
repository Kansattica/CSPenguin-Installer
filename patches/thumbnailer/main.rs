use memmap2::Mmap;
use memchr::memmem;
use std::env;
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::process;

const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
const SQLITE_SIGNATURE: &[u8] = b"SQLite format 3\0";
const IEND_MARKER: &[u8] = b"IEND";
const MAX_THUMB_SIZE: u32 = 256;

// Validate PNG by checking for IHDR chunk at the expected position
fn is_valid_png_header(data: &[u8]) -> bool {
    data.len() >= 16
        && data[8..12] == [0, 0, 0, 13]
        && &data[12..16] == b"IHDR"
}

// Find a valid (IHDR-validated) PNG in data, returns (start, end)
fn find_valid_png(data: &[u8]) -> Option<(usize, usize)> {
    let mut offset = 0;
    while let Some(rel) = memmem::find(&data[offset..], PNG_SIGNATURE) {
        let start = offset + rel;
        if data.len() >= start + 16 && is_valid_png_header(&data[start..]) {
            if let Some(iend_rel) = memmem::find(&data[start..], IEND_MARKER) {
                let end = start + iend_rel + 8;
                if end <= data.len() {
                    return Some((start, end));
                }
            }
        }
        offset = start + 1;
    }
    None
}

fn decode_png(data: &[u8]) -> Result<(u32, u32, Vec<u8>), String> {
    use zune_png::PngDecoder;
    use zune_core::colorspace::ColorSpace;

    let mut decoder = PngDecoder::new(data);
    let pixels = decoder.decode_raw()
        .map_err(|e| format!("PNG decode error: {:?}", e))?;
    let (w, h) = decoder.get_dimensions()
        .ok_or("Could not get PNG dimensions")?;
    let colorspace = decoder.get_colorspace()
        .ok_or("Could not get PNG colorspace")?;

    // normalize to RGBA
    let rgba = match colorspace {
        ColorSpace::RGBA => pixels,
        ColorSpace::RGB => pixels.chunks_exact(3)
            .flat_map(|p| [p[0], p[1], p[2], 255])
            .collect(),
        ColorSpace::Luma => pixels.iter()
            .flat_map(|&v| [v, v, v, 255])
            .collect(),
        ColorSpace::LumaA => pixels.chunks_exact(2)
            .flat_map(|p| [p[0], p[0], p[0], p[1]])
            .collect(),
        _ => return Err(format!("Unsupported colorspace: {:?}", colorspace)),
    };

    Ok((w as u32, h as u32, rgba))
}

fn resize_nearest(src: &[u8], src_w: u32, src_h: u32) -> (u32, u32, Vec<u8>) {
    let scale = (MAX_THUMB_SIZE as f32 / src_w as f32)
        .min(MAX_THUMB_SIZE as f32 / src_h as f32)
        .min(1.0);

    let dst_w = ((src_w as f32 * scale) as u32).max(1);
    let dst_h = ((src_h as f32 * scale) as u32).max(1);

    let mut dst = vec![0u8; (dst_w * dst_h * 4) as usize];
    for dy in 0..dst_h {
        let sy = ((dy as f32 / scale) as u32).min(src_h - 1);
        for dx in 0..dst_w {
            let sx = ((dx as f32 / scale) as u32).min(src_w - 1);
            let src_idx = ((sy * src_w + sx) * 4) as usize;
            let dst_idx = ((dy * dst_w + dx) * 4) as usize;
            dst[dst_idx..dst_idx + 4].copy_from_slice(&src[src_idx..src_idx + 4]);
        }
    }
    (dst_w, dst_h, dst)
}

fn encode_png(w: u32, h: u32, rgba: &[u8], output_path: &str) -> Result<(), String> {
    if let Some(parent) = Path::new(output_path).parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create output directory: {}", e))?;
    }
    let mut out = File::create(output_path)
        .map_err(|e| format!("Failed to create output file: {}", e))?;
    let mut encoder = png::Encoder::new(&mut out, w, h);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    let mut writer = encoder.write_header()
        .map_err(|e| format!("PNG header error: {}", e))?;
    writer.write_image_data(rgba)
        .map_err(|e| format!("PNG write error: {}", e))
}

fn process_png(data: &[u8], output_path: &str) -> Result<(), String> {
    let (w, h, pixels) = decode_png(data)?;
    if w <= MAX_THUMB_SIZE && h <= MAX_THUMB_SIZE {
        // already small enough, re-encode as-is
        encode_png(w, h, &pixels, output_path)
    } else {
        let (rw, rh, resized) = resize_nearest(&pixels, w, h);
        encode_png(rw, rh, &resized, output_path)
    }
}

fn extract_thumbnail(input_path: &str, output_path: &str) -> Result<(), String> {
    use rusqlite::Connection;

    let file = File::open(input_path)
        .map_err(|e| format!("Failed to open input file: {}", e))?;
    let mmap = unsafe { Mmap::map(&file) }
        .map_err(|e| format!("Failed to mmap file: {}", e))?;

    let sqlite_offset = memmem::find(&mmap, SQLITE_SIGNATURE)
        .ok_or("No SQLite header found in clip file")?;

    // fast path: scan the sqlite region for an embedded preview PNG
    let search_end = mmap.len();
    if let Some((rel_start, rel_end)) = find_valid_png(&mmap[sqlite_offset..search_end]) {
        let bytes = &mmap[sqlite_offset + rel_start..sqlite_offset + rel_end];
        if process_png(bytes, output_path).is_ok() {
            return Ok(());
        }
    }


    let tmp_db = format!("/tmp/clip-thumbnailer-{}.db", std::process::id());
    let sqlite_data = &mmap[sqlite_offset..];
    let write_size = sqlite_data.len().min(256 * 1024 * 1024);
    {
        let mut tmp_file = File::create(&tmp_db)
            .map_err(|e| format!("Failed to create temp DB: {}", e))?;
        tmp_file.write_all(&sqlite_data[..write_size])
            .map_err(|e| format!("Failed to write temp DB: {}", e))?;
    }

    let conn = Connection::open(&tmp_db)
        .map_err(|e| format!("Failed to open SQLite: {}", e))?;
    let blob: Vec<u8> = conn
        .query_row("SELECT ImageData FROM CanvasPreview LIMIT 1", [], |row| row.get(0))
        .map_err(|e| format!("Failed to query CanvasPreview: {}", e))?;
    drop(conn);
    let _ = fs::remove_file(&tmp_db);

    let (start, end) = find_valid_png(&blob)
        .ok_or("No valid PNG found in CanvasPreview blob")?;
    process_png(&blob[start..end], output_path)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: clip-thumbnailer [input_file] [output_file]");
        process::exit(1);
    }
    if let Err(e) = extract_thumbnail(&args[1], &args[2]) {
        eprintln!("Error: {}", e);
        process::exit(1);
    }
}
