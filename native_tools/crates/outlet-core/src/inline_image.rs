//! Image preparation for inline model input.
//!
//! The server embeds only JPEG, PNG, GIF and WebP images whose longest side and encoded
//! size fit [`INLINE_IMAGE_MAX_SIDE`] and [`INLINE_IMAGE_MAX_BYTES`]. Files that already
//! fit are passed through byte for byte, so animations and metadata are preserved. Other
//! decodable images are oriented, downscaled and re-encoded; callers report the
//! conversion to the model with [`InlineImage::notice`].

use std::fmt;
use std::io::Cursor;
use std::path::Path;

use anyhow::Context;
use image::codecs::gif::GifDecoder;
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::{CompressionType, FilterType as PngFilterType, PngDecoder, PngEncoder};
use image::codecs::webp::WebPDecoder;
use image::imageops::FilterType;
use image::metadata::Orientation;
use image::{
    AnimationDecoder, ColorType, DynamicImage, ImageBuffer, ImageDecoder, ImageEncoder, ImageError,
    ImageFormat, ImageReader, Limits,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;

/// Longest image side the server embeds inline.
pub const INLINE_IMAGE_MAX_SIDE: u32 = 2000;
/// Largest encoded image the server embeds inline (7.5 MiB).
pub const INLINE_IMAGE_MAX_BYTES: u64 = 7_864_320;
/// Largest source file read for image preparation.
pub const IMAGE_SOURCE_MAX_BYTES: u64 = 256 * 1024 * 1024;
/// Decoder allocation budget; the decoded pixel buffer is checked against it up front.
pub const IMAGE_DECODE_MAX_ALLOC: u64 = 512 * 1024 * 1024;

const JPEG_QUALITY: u8 = 90;
/// Integer box pre-reduction leaves at least this much scaling to the final filter.
const REDUCING_GAP: f64 = 1.5;
const ENCODE_ATTEMPTS: usize = 16;

#[derive(Clone, Copy, Debug)]
struct Budget {
    max_side: u32,
    max_bytes: u64,
    max_source_bytes: u64,
    max_decode_alloc: u64,
}

const DEFAULT_BUDGET: Budget = Budget {
    max_side: INLINE_IMAGE_MAX_SIDE,
    max_bytes: INLINE_IMAGE_MAX_BYTES,
    max_source_bytes: IMAGE_SOURCE_MAX_BYTES,
    max_decode_alloc: IMAGE_DECODE_MAX_ALLOC,
};

/// An image snapshot ready to be uploaded as model media.
#[derive(Debug)]
pub struct InlineImage {
    /// Bytes to upload: the unchanged source, or its converted copy.
    pub bytes: Vec<u8>,
    pub mime_type: &'static str,
    /// Lowercase hex SHA-256 of the source snapshot.
    pub source_sha256: String,
    /// Present when the source had to be converted to fit inline limits.
    pub conversion: Option<ImageConversion>,
}

impl InlineImage {
    /// A short English note for the tool result, or `None` for unchanged sources.
    pub fn notice(&self, original_path: &str) -> Option<String> {
        self.conversion
            .as_ref()
            .map(|conversion| conversion.notice(original_path))
    }

    /// Upload file name whose extension matches the converted format.
    pub fn upload_file_name(&self, file_name: &str) -> String {
        if self.conversion.is_none() {
            return file_name.to_string();
        }
        let (extension, aliases): (&str, &[&str]) = if self.mime_type == "image/png" {
            ("png", &["png"])
        } else {
            ("jpg", &["jpg", "jpeg"])
        };
        let path = Path::new(file_name);
        let current = path
            .extension()
            .and_then(|value| value.to_str())
            .map(str::to_ascii_lowercase);
        if current.is_some_and(|value| aliases.contains(&value.as_str())) {
            return file_name.to_string();
        }
        let stem = path
            .file_stem()
            .and_then(|value| value.to_str())
            .filter(|value| !value.is_empty())
            .unwrap_or("image");
        format!("{stem}.{extension}")
    }
}

/// What the preparation changed; serialized into tool result metadata.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ImageConversion {
    pub original: ImageSummary,
    pub converted: ImageSummary,
    pub orientation_applied: bool,
    pub first_frame_only: bool,
    #[serde(skip)]
    source_format_inline: bool,
    #[serde(skip)]
    max_side: u32,
    #[serde(skip)]
    max_bytes: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct ImageSummary {
    pub format: &'static str,
    pub width: u32,
    pub height: u32,
    pub size_bytes: u64,
}

impl ImageConversion {
    pub fn notice(&self, original_path: &str) -> String {
        let (from, to) = (&self.original, &self.converted);
        let action = if to.width.max(to.height) < from.width.max(from.height) {
            "downscaled"
        } else {
            "converted"
        };
        let limit = format!("{} px / {}", self.max_side, format_size(self.max_bytes));
        let reason = if self.source_format_inline {
            format!("to fit the {limit} inline limit")
        } else {
            format!("to fit the inline image limits (JPEG/PNG/GIF/WebP, {limit})")
        };
        let mut notice = format!(
            "Image was {action} from {} to {} {reason}.",
            describe(from),
            describe(to)
        );
        if self.orientation_applied {
            notice.push_str(" EXIF orientation was applied.");
        }
        if self.first_frame_only {
            notice.push_str(" Only the first animation frame was kept.");
        }
        notice.push_str(&format!(
            " The original file is unchanged at {original_path}."
        ));
        notice
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InlineImageError {
    /// The content is not an image any enabled decoder accepts.
    Invalid,
    SourceTooLarge {
        size_bytes: u64,
        limit_bytes: u64,
    },
    DecodeLimit {
        dimensions: Option<(u32, u32)>,
        required_bytes: Option<u64>,
        limit_bytes: u64,
    },
    Conversion(String),
}

impl fmt::Display for InlineImageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid => formatter.write_str("File content is not a valid image."),
            Self::SourceTooLarge {
                size_bytes,
                limit_bytes,
            } => write!(
                formatter,
                "Image file is too large to process: {} exceeds the {} limit.",
                format_size(*size_bytes),
                format_size(*limit_bytes)
            ),
            Self::DecodeLimit {
                dimensions,
                required_bytes,
                limit_bytes,
            } => {
                let limit = format_size(*limit_bytes);
                match (dimensions, required_bytes) {
                    (Some((width, height)), Some(required)) => write!(
                        formatter,
                        "Image is too large to decode: {width}x{height} pixels need {} of memory, more than the {limit} decoding limit.",
                        format_size(*required)
                    ),
                    (Some((width, height)), None) => write!(
                        formatter,
                        "Image is too large to decode: {width}x{height} pixels exceed the {limit} decoding memory limit."
                    ),
                    _ => write!(
                        formatter,
                        "Image is too large to decode within the {limit} memory limit."
                    ),
                }
            }
            Self::Conversion(message) => {
                write!(formatter, "Failed to convert the image: {message}")
            }
        }
    }
}

impl std::error::Error for InlineImageError {}

/// Reads `path` once and prepares that snapshot for inline model input.
///
/// Decoding and conversion run on the blocking pool.
pub async fn read_inline_image(path: &Path) -> anyhow::Result<InlineImage> {
    let file = tokio::fs::File::open(path)
        .await
        .context("failed to read image file")?;
    let size_bytes = file
        .metadata()
        .await
        .context("failed to read image file")?
        .len();
    if size_bytes > IMAGE_SOURCE_MAX_BYTES {
        return Err(InlineImageError::SourceTooLarge {
            size_bytes,
            limit_bytes: IMAGE_SOURCE_MAX_BYTES,
        }
        .into());
    }
    let mut source = Vec::with_capacity(usize::try_from(size_bytes).unwrap_or_default());
    // The file may grow after the size check; never read more than one byte past the limit.
    file.take(IMAGE_SOURCE_MAX_BYTES + 1)
        .read_to_end(&mut source)
        .await
        .context("failed to read image file")?;
    let image = tokio::task::spawn_blocking(move || prepare_inline_image(source))
        .await
        .context("image preparation task failed")??;
    Ok(image)
}

/// Validates `source` and converts it when it does not fit the inline limits.
///
/// CPU-bound: call from a blocking context.
pub fn prepare_inline_image(source: Vec<u8>) -> Result<InlineImage, InlineImageError> {
    prepare(source, &DEFAULT_BUDGET)
}

fn prepare(source: Vec<u8>, budget: &Budget) -> Result<InlineImage, InlineImageError> {
    let source_size = source.len() as u64;
    if source_size > budget.max_source_bytes {
        return Err(InlineImageError::SourceTooLarge {
            size_bytes: source_size,
            limit_bytes: budget.max_source_bytes,
        });
    }
    let source_sha256 = format!("{:x}", Sha256::digest(&source));
    let decoded = decode(&source, budget)?;
    let (width, height) = (decoded.image.width(), decoded.image.height());
    let inline_mime = inline_mime_type(decoded.format);
    if let Some(mime_type) = inline_mime {
        if width.max(height) <= budget.max_side && source_size <= budget.max_bytes {
            return Ok(InlineImage {
                bytes: source,
                mime_type,
                source_sha256,
                conversion: None,
            });
        }
    }

    let first_frame_only = is_animated(decoded.format, &source, budget);
    drop(source);
    let original = ImageSummary {
        format: format_name(decoded.format),
        width,
        height,
        size_bytes: source_size,
    };
    let orientation_applied = decoded.orientation != Orientation::NoTransforms;
    let encoded = normalize(decoded, budget)?;
    let converted = ImageSummary {
        format: format_name(encoded.format),
        width: encoded.width,
        height: encoded.height,
        size_bytes: encoded.bytes.len() as u64,
    };
    Ok(InlineImage {
        bytes: encoded.bytes,
        mime_type: encoded.format.to_mime_type(),
        source_sha256,
        conversion: Some(ImageConversion {
            original,
            converted,
            orientation_applied,
            first_frame_only,
            source_format_inline: inline_mime.is_some(),
            max_side: budget.max_side,
            max_bytes: budget.max_bytes,
        }),
    })
}

struct Decoded {
    image: DynamicImage,
    format: ImageFormat,
    orientation: Orientation,
    icc_profile: Option<Vec<u8>>,
}

struct Encoded {
    bytes: Vec<u8>,
    format: ImageFormat,
    width: u32,
    height: u32,
}

fn decoder_limits(budget: &Budget) -> Limits {
    let mut limits = Limits::default();
    limits.max_alloc = Some(budget.max_decode_alloc);
    limits
}

fn decode(source: &[u8], budget: &Budget) -> Result<Decoded, InlineImageError> {
    let format = image::guess_format(source).map_err(|_| InlineImageError::Invalid)?;
    let limit_bytes = budget.max_decode_alloc;
    let failure = |error: ImageError, dimensions: Option<(u32, u32)>| match error {
        ImageError::Limits(_) => InlineImageError::DecodeLimit {
            dimensions,
            required_bytes: None,
            limit_bytes,
        },
        _ => InlineImageError::Invalid,
    };

    let mut reader = ImageReader::with_format(Cursor::new(source), format);
    reader.limits(decoder_limits(budget));
    let mut decoder = reader
        .into_decoder()
        .map_err(|error| failure(error, None))?;
    let dimensions = decoder.dimensions();
    let required_bytes = decoder.total_bytes();
    // Like `ImageReader::decode`: reserve the pixel buffer, leave the rest to the decoder.
    let mut limits = decoder_limits(budget);
    if limits.reserve(required_bytes).is_err() {
        return Err(InlineImageError::DecodeLimit {
            dimensions: Some(dimensions),
            required_bytes: Some(required_bytes),
            limit_bytes,
        });
    }
    decoder
        .set_limits(limits)
        .map_err(|error| failure(error, Some(dimensions)))?;
    let orientation = decoder.orientation().unwrap_or(Orientation::NoTransforms);
    let icc_profile = decoder.icc_profile().ok().flatten();
    let image =
        DynamicImage::from_decoder(decoder).map_err(|error| failure(error, Some(dimensions)))?;
    if image.width() == 0 || image.height() == 0 {
        return Err(InlineImageError::Invalid);
    }
    Ok(Decoded {
        image,
        format,
        orientation,
        icc_profile,
    })
}

fn is_animated(format: ImageFormat, source: &[u8], budget: &Budget) -> bool {
    match format {
        ImageFormat::Gif => GifDecoder::new(Cursor::new(source)).is_ok_and(|mut decoder| {
            decoder.set_limits(decoder_limits(budget)).is_ok()
                && decoder.into_frames().nth(1).is_some()
        }),
        ImageFormat::Png => PngDecoder::with_limits(Cursor::new(source), decoder_limits(budget))
            .and_then(|decoder| decoder.is_apng())
            .unwrap_or(false),
        ImageFormat::WebP => {
            WebPDecoder::new(Cursor::new(source)).is_ok_and(|decoder| decoder.has_animation())
        }
        _ => false,
    }
}

fn normalize(decoded: Decoded, budget: &Budget) -> Result<Encoded, InlineImageError> {
    let Decoded {
        image,
        format,
        orientation,
        icc_profile,
    } = decoded;
    let image = into_8bit(image);
    let transparent = has_transparency(&image);
    let (width, height) = fit_within(image.width(), image.height(), budget.max_side);
    // Resample before orienting so a rotation never copies the full-size image.
    let mut image = resample(image, width, height, transparent);
    if !transparent {
        image = drop_alpha(image);
    }
    image.apply_orientation(orientation);
    let lossless = transparent
        || matches!(
            format,
            ImageFormat::Png
                | ImageFormat::Gif
                | ImageFormat::WebP
                | ImageFormat::Bmp
                | ImageFormat::Ico
        );
    encode_within(image, lossless, transparent, icc_profile, budget.max_bytes)
}

fn encode_within(
    base: DynamicImage,
    lossless: bool,
    transparent: bool,
    icc_profile: Option<Vec<u8>>,
    max_bytes: u64,
) -> Result<Encoded, InlineImageError> {
    let icc_profile = icc_profile.filter(|profile| icc_profile_matches(profile, &base));
    let mut format = if lossless {
        ImageFormat::Png
    } else {
        ImageFormat::Jpeg
    };
    let mut scaled: Option<DynamicImage> = None;
    for _ in 0..ENCODE_ATTEMPTS {
        let image = scaled.as_ref().unwrap_or(&base);
        let bytes = encode(image, format, icc_profile.as_deref())?;
        if bytes.len() as u64 <= max_bytes {
            return Ok(Encoded {
                bytes,
                format,
                width: image.width(),
                height: image.height(),
            });
        }
        if format == ImageFormat::Png && !transparent {
            format = ImageFormat::Jpeg;
            continue;
        }
        // Shrink in proportion to the overshoot, with headroom for size variance.
        let factor = ((max_bytes as f64 / bytes.len() as f64).sqrt() * 0.9).clamp(0.1, 0.9);
        let (width, height) = (
            scale_side(image.width(), factor),
            scale_side(image.height(), factor),
        );
        if (width, height) == (image.width(), image.height()) {
            break;
        }
        scaled = Some(resample(base.clone(), width, height, transparent));
    }
    Err(InlineImageError::Conversion(format!(
        "it does not fit {} even after downscaling",
        format_size(max_bytes)
    )))
}

fn encode(
    image: &DynamicImage,
    format: ImageFormat,
    icc_profile: Option<&[u8]>,
) -> Result<Vec<u8>, InlineImageError> {
    let mut bytes = Vec::new();
    let result = if format == ImageFormat::Png {
        let mut encoder = PngEncoder::new_with_quality(
            &mut bytes,
            CompressionType::Default,
            PngFilterType::Adaptive,
        );
        if let Some(profile) = icc_profile {
            let _ = encoder.set_icc_profile(profile.to_vec());
        }
        image.write_with_encoder(encoder)
    } else {
        let mut encoder = JpegEncoder::new_with_quality(&mut bytes, JPEG_QUALITY);
        if let Some(profile) = icc_profile {
            let _ = encoder.set_icc_profile(profile.to_vec());
        }
        image.write_with_encoder(encoder)
    };
    result.map_err(|error| InlineImageError::Conversion(error.to_string()))?;
    Ok(bytes)
}

/// Keeps an embedded profile only when its colour space matches the output pixels
/// (for example, CMYK JPEG profiles are dropped once pixels are RGB).
fn icc_profile_matches(profile: &[u8], image: &DynamicImage) -> bool {
    let expected: &[u8] = if image.color().has_color() {
        b"RGB "
    } else {
        b"GRAY"
    };
    profile.get(16..20) == Some(expected)
}

fn into_8bit(image: DynamicImage) -> DynamicImage {
    match image {
        DynamicImage::ImageLuma8(_)
        | DynamicImage::ImageLumaA8(_)
        | DynamicImage::ImageRgb8(_)
        | DynamicImage::ImageRgba8(_) => image,
        DynamicImage::ImageLuma16(_) => DynamicImage::ImageLuma8(image.into_luma8()),
        DynamicImage::ImageLumaA16(_) => DynamicImage::ImageLumaA8(image.into_luma_alpha8()),
        _ if image.color().has_alpha() => DynamicImage::ImageRgba8(image.into_rgba8()),
        _ => DynamicImage::ImageRgb8(image.into_rgb8()),
    }
}

fn drop_alpha(image: DynamicImage) -> DynamicImage {
    match image {
        DynamicImage::ImageRgba8(_) => DynamicImage::ImageRgb8(image.into_rgb8()),
        DynamicImage::ImageLumaA8(_) => DynamicImage::ImageLuma8(image.into_luma8()),
        other => other,
    }
}

fn has_transparency(image: &DynamicImage) -> bool {
    match image {
        DynamicImage::ImageRgba8(buffer) => buffer
            .as_raw()
            .chunks_exact(4)
            .any(|pixel| pixel[3] != u8::MAX),
        DynamicImage::ImageLumaA8(buffer) => buffer
            .as_raw()
            .chunks_exact(2)
            .any(|pixel| pixel[1] != u8::MAX),
        _ => false,
    }
}

fn fit_within(width: u32, height: u32, max_side: u32) -> (u32, u32) {
    let longest = width.max(height);
    if longest <= max_side {
        return (width, height);
    }
    let scale = f64::from(max_side) / f64::from(longest);
    (
        scale_side(width, scale).min(max_side),
        scale_side(height, scale).min(max_side),
    )
}

fn scale_side(side: u32, scale: f64) -> u32 {
    ((f64::from(side) * scale).round() as u32).max(1)
}

/// Resizes with Lanczos3. Large reductions start with an integer box reduction, which
/// bounds the filter's full-width float buffer and its running time.
fn resample(mut image: DynamicImage, width: u32, height: u32, transparent: bool) -> DynamicImage {
    if (image.width(), image.height()) == (width, height) {
        return image;
    }
    // The filters treat channels independently; premultiplying keeps the colour of
    // transparent pixels from bleeding into visible edges.
    if transparent {
        premultiply_alpha(&mut image);
    }
    let scale = (f64::from(image.width()) / f64::from(width))
        .max(f64::from(image.height()) / f64::from(height));
    let factor = (scale / REDUCING_GAP).floor() as u32;
    if factor >= 2 {
        image = box_reduce(&image, factor);
    }
    let mut image = image.resize_exact(width, height, FilterType::Lanczos3);
    if transparent {
        unpremultiply_alpha(&mut image);
    }
    image
}

/// Averages `factor` x `factor` blocks of an 8-bit image; edge blocks may be partial.
/// Unlike `thumbnail_exact`, block boundaries never drift when sides are not multiples
/// of `factor`.
fn box_reduce(image: &DynamicImage, factor: u32) -> DynamicImage {
    let (width, height) = (image.width() as usize, image.height() as usize);
    let factor_size = factor as usize;
    let (reduced_width, reduced_height) =
        (width.div_ceil(factor_size), height.div_ceil(factor_size));
    let channels = usize::from(image.color().channel_count());
    let stride = width * channels;
    let samples = image.as_bytes();
    if samples.len() != stride * height {
        // Only 8-bit images reach this point; keep a safe fallback for anything else.
        return image.thumbnail_exact(reduced_width as u32, reduced_height as u32);
    }
    let mut reduced = Vec::with_capacity(reduced_width * reduced_height * channels);
    let mut sums = vec![0u32; reduced_width * channels];
    for block_row in samples.chunks(stride * factor_size) {
        sums.fill(0);
        for row in block_row.chunks_exact(stride) {
            for (block, sum) in row
                .chunks(factor_size * channels)
                .zip(sums.chunks_exact_mut(channels))
            {
                for pixel in block.chunks_exact(channels) {
                    for (total, &value) in sum.iter_mut().zip(pixel) {
                        *total += u32::from(value);
                    }
                }
            }
        }
        let rows = (block_row.len() / stride) as u32;
        for (block_index, sum) in sums.chunks_exact(channels).enumerate() {
            let columns = (width - block_index * factor_size).min(factor_size) as u32;
            let count = rows * columns;
            reduced.extend(sum.iter().map(|total| ((total + count / 2) / count) as u8));
        }
    }
    let (reduced_width, reduced_height) = (reduced_width as u32, reduced_height as u32);
    let rebuilt = match image.color() {
        ColorType::L8 => ImageBuffer::from_raw(reduced_width, reduced_height, reduced)
            .map(DynamicImage::ImageLuma8),
        ColorType::La8 => ImageBuffer::from_raw(reduced_width, reduced_height, reduced)
            .map(DynamicImage::ImageLumaA8),
        ColorType::Rgb8 => ImageBuffer::from_raw(reduced_width, reduced_height, reduced)
            .map(DynamicImage::ImageRgb8),
        ColorType::Rgba8 => ImageBuffer::from_raw(reduced_width, reduced_height, reduced)
            .map(DynamicImage::ImageRgba8),
        _ => None,
    };
    rebuilt.unwrap_or_else(|| image.thumbnail_exact(reduced_width, reduced_height))
}

fn alpha_samples(image: &mut DynamicImage) -> Option<(&mut [u8], usize)> {
    match image {
        DynamicImage::ImageRgba8(buffer) => Some((&mut **buffer, 4)),
        DynamicImage::ImageLumaA8(buffer) => Some((&mut **buffer, 2)),
        _ => None,
    }
}

fn premultiply_alpha(image: &mut DynamicImage) {
    if let Some((samples, channels)) = alpha_samples(image) {
        for pixel in samples.chunks_exact_mut(channels) {
            let (color, alpha) = pixel.split_at_mut(channels - 1);
            let alpha = u16::from(alpha[0]);
            for value in color {
                *value = ((u16::from(*value) * alpha + 127) / 255) as u8;
            }
        }
    }
}

fn unpremultiply_alpha(image: &mut DynamicImage) {
    if let Some((samples, channels)) = alpha_samples(image) {
        for pixel in samples.chunks_exact_mut(channels) {
            let (color, alpha) = pixel.split_at_mut(channels - 1);
            let alpha = u16::from(alpha[0]);
            for value in color {
                *value = if alpha == 0 {
                    0
                } else {
                    ((u16::from(*value) * 255 + alpha / 2) / alpha).min(255) as u8
                };
            }
        }
    }
}

fn inline_mime_type(format: ImageFormat) -> Option<&'static str> {
    match format {
        ImageFormat::Png => Some("image/png"),
        ImageFormat::Jpeg => Some("image/jpeg"),
        ImageFormat::Gif => Some("image/gif"),
        ImageFormat::WebP => Some("image/webp"),
        _ => None,
    }
}

fn format_name(format: ImageFormat) -> &'static str {
    match format {
        ImageFormat::Jpeg => "JPEG",
        ImageFormat::Png => "PNG",
        ImageFormat::Gif => "GIF",
        ImageFormat::WebP => "WebP",
        ImageFormat::Bmp => "BMP",
        ImageFormat::Ico => "ICO",
        ImageFormat::Tiff => "TIFF",
        ImageFormat::Avif => "AVIF",
        ImageFormat::Tga => "TGA",
        ImageFormat::Pnm => "PNM",
        ImageFormat::Qoi => "QOI",
        ImageFormat::Hdr => "HDR",
        ImageFormat::OpenExr => "OpenEXR",
        _ => "image",
    }
}

fn describe(summary: &ImageSummary) -> String {
    format!(
        "{}x{} ({}, {})",
        summary.width,
        summary.height,
        format_size(summary.size_bytes),
        summary.format
    )
}

fn format_size(bytes: u64) -> String {
    const KIB: u64 = 1024;
    const MIB: u64 = 1024 * KIB;
    const GIB: u64 = 1024 * MIB;
    let (value, unit) = if bytes >= 1000 * MIB {
        (bytes as f64 / GIB as f64, "GB")
    } else if bytes >= 1000 * KIB {
        (bytes as f64 / MIB as f64, "MB")
    } else {
        return format!("{} KB", bytes.div_ceil(KIB).max(1));
    };
    let value = format!("{value:.1}");
    format!("{} {unit}", value.strip_suffix(".0").unwrap_or(&value))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{GrayImage, Luma, Rgb, RgbImage, Rgba, RgbaImage};

    fn encoded(image: &DynamicImage, format: ImageFormat) -> Vec<u8> {
        let mut bytes = Cursor::new(Vec::new());
        image.write_to(&mut bytes, format).unwrap();
        bytes.into_inner()
    }

    fn budget(max_side: u32, max_bytes: u64) -> Budget {
        Budget {
            max_side,
            max_bytes,
            ..DEFAULT_BUDGET
        }
    }

    /// A big-endian TIFF block with a single orientation entry.
    fn exif_orientation(value: u16) -> Vec<u8> {
        let mut exif = b"MM\0\x2a\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01".to_vec();
        exif.extend_from_slice(&value.to_be_bytes());
        exif.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
        exif
    }

    fn decoded(bytes: &[u8]) -> DynamicImage {
        image::load_from_memory(bytes).unwrap()
    }

    /// Deterministic noise that compresses poorly.
    fn noise(seed: u32) -> impl FnMut(u32, u32) -> u8 {
        let mut state = seed.max(1);
        move |_, _| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            state as u8
        }
    }

    #[test]
    fn images_within_inline_limits_are_passed_through_byte_for_byte() {
        let image = DynamicImage::ImageRgba8(RgbaImage::from_fn(5, 3, |x, y| {
            Rgba([x as u8 * 40, y as u8 * 60, 90, 200])
        }));
        for (format, mime_type) in [
            (ImageFormat::Png, "image/png"),
            (ImageFormat::Gif, "image/gif"),
            (ImageFormat::WebP, "image/webp"),
            (ImageFormat::Jpeg, "image/jpeg"),
        ] {
            let source = if format == ImageFormat::Jpeg {
                encoded(&DynamicImage::ImageRgb8(image.to_rgb8()), format)
            } else {
                encoded(&image, format)
            };
            let prepared = prepare_inline_image(source.clone()).unwrap();

            assert_eq!(prepared.bytes, source, "{format:?}");
            assert_eq!(prepared.mime_type, mime_type);
            assert_eq!(
                prepared.source_sha256,
                format!("{:x}", Sha256::digest(&source))
            );
            assert!(prepared.conversion.is_none());
            assert_eq!(prepared.notice("/tmp/a.png"), None);
            assert_eq!(prepared.upload_file_name("a.png"), "a.png");
        }
    }

    #[test]
    fn exactly_maximum_side_is_still_inline() {
        let source = encoded(&DynamicImage::new_luma8(2000, 1), ImageFormat::Png);
        assert_eq!(prepare_inline_image(source.clone()).unwrap().bytes, source);
    }

    #[test]
    fn oversized_jpeg_is_downscaled_to_the_maximum_side_with_a_notice() {
        let source = encoded(
            &DynamicImage::ImageRgb8(RgbImage::from_fn(4032, 30, |x, _| {
                Rgb([(x / 16) as u8, 120, 200])
            })),
            ImageFormat::Jpeg,
        );
        let prepared = prepare_inline_image(source.clone()).unwrap();
        let conversion = prepared.conversion.clone().unwrap();
        let result = decoded(&prepared.bytes);

        assert_eq!(prepared.mime_type, "image/jpeg");
        assert_eq!((result.width(), result.height()), (2000, 15));
        assert_eq!(
            conversion.original,
            ImageSummary {
                format: "JPEG",
                width: 4032,
                height: 30,
                size_bytes: source.len() as u64,
            }
        );
        assert_eq!(
            (conversion.converted.format, conversion.converted.width),
            ("JPEG", 2000)
        );
        assert_eq!(
            prepared.notice("/data/photo.jpg").unwrap(),
            format!(
                "Image was downscaled from 4032x30 ({}, JPEG) to 2000x15 ({}, JPEG) to fit the 2000 px / 7.5 MB inline limit. The original file is unchanged at /data/photo.jpg.",
                format_size(source.len() as u64),
                format_size(prepared.bytes.len() as u64)
            )
        );
        assert_eq!(prepared.upload_file_name("photo.JPEG"), "photo.JPEG");
        let raw = serde_json::to_value(&conversion).unwrap();
        assert_eq!(raw["original"]["format"], "JPEG");
        assert_eq!(raw["converted"]["height"], 15);
        assert_eq!(raw["first_frame_only"], false);
        assert!(raw.get("max_side").is_none());
    }

    #[test]
    fn large_reductions_are_box_reduced_before_the_final_filter() {
        let source = encoded(
            &DynamicImage::ImageLuma8(GrayImage::from_fn(9001, 7, |x, _| {
                Luma([if x < 4500 { 40 } else { 220 }])
            })),
            ImageFormat::Png,
        );
        let prepared = prepare_inline_image(source).unwrap();
        let result = decoded(&prepared.bytes).into_luma8();

        // A 4.5x reduction starts with a 3x box reduction, then Lanczos3 does the rest.
        assert_eq!(prepared.mime_type, "image/png");
        assert_eq!(result.dimensions(), (2000, 2));
        assert!(result.get_pixel(100, 0)[0].abs_diff(40) <= 1);
        assert!(result.get_pixel(1900, 1)[0].abs_diff(220) <= 1);
    }

    #[test]
    fn box_reduction_averages_partial_edge_blocks() {
        let image =
            DynamicImage::ImageLuma8(GrayImage::from_raw(5, 1, vec![0, 2, 4, 9, 7]).unwrap());
        let reduced = box_reduce(&image, 2).into_luma8();
        assert_eq!(reduced.into_raw(), vec![1, 7, 7]);
    }

    #[test]
    fn transparent_png_stays_png_without_dark_fringes() {
        // Transparent pixels are black: unpremultiplied filtering would darken the edge.
        let source = encoded(
            &DynamicImage::ImageRgba8(RgbaImage::from_fn(2400, 24, |x, _| {
                if x < 1200 {
                    Rgba([0, 0, 0, 0])
                } else {
                    Rgba([255, 255, 255, 255])
                }
            })),
            ImageFormat::Png,
        );
        let prepared = prepare_inline_image(source).unwrap();
        let result = decoded(&prepared.bytes);
        let conversion = prepared.conversion.as_ref().unwrap();

        assert_eq!(prepared.mime_type, "image/png");
        assert_eq!(
            (conversion.original.format, conversion.converted.format),
            ("PNG", "PNG")
        );
        assert!(result.color().has_alpha());
        let result = result.into_rgba8();
        assert_eq!(result.dimensions(), (2000, 20));
        assert_eq!(result.get_pixel(10, 5)[3], 0);
        assert_eq!(*result.get_pixel(1990, 5), Rgba([255, 255, 255, 255]));
        for x in 990..1010 {
            let pixel = result.get_pixel(x, 5);
            if pixel[3] >= 64 {
                assert!(pixel[0] >= 240, "dark fringe at {x}: {pixel:?}");
            }
        }
    }

    #[test]
    fn opaque_alpha_channel_is_dropped_from_converted_png() {
        let source = encoded(
            &DynamicImage::ImageRgba8(RgbaImage::from_pixel(64, 8, Rgba([10, 20, 30, 255]))),
            ImageFormat::Png,
        );
        let prepared = prepare(source, &budget(32, DEFAULT_BUDGET.max_bytes)).unwrap();
        let result = decoded(&prepared.bytes);

        assert_eq!(prepared.mime_type, "image/png");
        assert_eq!(result.color(), ColorType::Rgb8);
        assert_eq!((result.width(), result.height()), (32, 4));
    }

    #[test]
    fn exif_orientation_is_applied_when_converting() {
        // Left half red, right half blue; EXIF 6 means "rotate 90 degrees clockwise".
        let image = DynamicImage::ImageRgb8(RgbImage::from_fn(2400, 100, |x, _| {
            if x < 1200 {
                Rgb([255, 0, 0])
            } else {
                Rgb([0, 0, 255])
            }
        }));
        let mut source = Vec::new();
        let mut encoder = JpegEncoder::new_with_quality(&mut source, 95);
        encoder.set_exif_metadata(exif_orientation(6)).unwrap();
        image.write_with_encoder(encoder).unwrap();

        let prepared = prepare_inline_image(source).unwrap();
        let conversion = prepared.conversion.as_ref().unwrap();
        let result = decoded(&prepared.bytes).into_rgb8();

        assert!(conversion.orientation_applied);
        assert_eq!(result.dimensions(), (83, 2000));
        // Pixels are already upright, so the output must not carry the tag again.
        let mut output =
            image::codecs::jpeg::JpegDecoder::new(Cursor::new(&prepared.bytes)).unwrap();
        assert_eq!(output.orientation().unwrap(), Orientation::NoTransforms);
        let top = result.get_pixel(40, 100);
        let bottom = result.get_pixel(40, 1900);
        assert!(top[0] > 200 && top[2] < 60, "top {top:?}");
        assert!(bottom[2] > 200 && bottom[0] < 60, "bottom {bottom:?}");
        assert!(prepared.notice("/p.jpg").unwrap().contains("to 83x2000 ("));
        assert!(prepared
            .notice("/p.jpg")
            .unwrap()
            .contains("inline limit. EXIF orientation was applied. The original file"));
    }

    #[test]
    fn bmp_is_converted_to_png_losslessly() {
        let image = DynamicImage::ImageRgb8(RgbImage::from_fn(3, 2, |x, y| {
            Rgb([x as u8 * 80, y as u8 * 100, 7])
        }));
        let source = encoded(&image, ImageFormat::Bmp);
        let prepared = prepare_inline_image(source.clone()).unwrap();

        assert_eq!(prepared.mime_type, "image/png");
        assert_eq!(decoded(&prepared.bytes).into_rgb8(), image.to_rgb8());
        assert_eq!(prepared.upload_file_name("scan.bmp"), "scan.png");
        assert_eq!(
            prepared.notice("/tmp/scan.bmp").unwrap(),
            format!(
                "Image was converted from 3x2 ({}, BMP) to 3x2 ({}, PNG) to fit the inline image limits (JPEG/PNG/GIF/WebP, 2000 px / 7.5 MB). The original file is unchanged at /tmp/scan.bmp.",
                format_size(source.len() as u64),
                format_size(prepared.bytes.len() as u64)
            )
        );
    }

    #[test]
    fn oversized_animation_keeps_only_the_first_frame() {
        use image::codecs::gif::GifEncoder;
        use image::{Delay, Frame};

        let mut source = Vec::new();
        {
            let mut encoder = GifEncoder::new(&mut source);
            for color in [[200, 0, 0, 255], [0, 0, 200, 255]] {
                encoder
                    .encode_frame(Frame::from_parts(
                        RgbaImage::from_pixel(40, 4, Rgba(color)),
                        0,
                        0,
                        Delay::from_numer_denom_ms(100, 1),
                    ))
                    .unwrap();
            }
        }
        let prepared = prepare(source, &budget(20, DEFAULT_BUDGET.max_bytes)).unwrap();
        let conversion = prepared.conversion.as_ref().unwrap();
        let result = decoded(&prepared.bytes).into_rgb8();

        assert!(conversion.first_frame_only);
        assert_eq!(prepared.mime_type, "image/png");
        assert_eq!(result.dimensions(), (20, 2));
        assert!(result.get_pixel(10, 1)[0] > 150);
        assert!(prepared
            .notice("/a.gif")
            .unwrap()
            .contains("Only the first animation frame was kept."));
    }

    #[test]
    fn opaque_png_over_the_byte_limit_falls_back_to_jpeg() {
        let mut pixel = noise(7);
        let image = DynamicImage::ImageRgb8(RgbImage::from_fn(96, 96, |x, y| {
            let jitter = pixel(x, y) % 16;
            Rgb([(x * 2) as u8 + jitter, (y * 2) as u8 + jitter, 128 + jitter])
        }));
        let source = encoded(&image, ImageFormat::Png);
        let png = encode(&image, ImageFormat::Png, None).unwrap().len() as u64;
        let jpeg = encode(&image, ImageFormat::Jpeg, None).unwrap().len() as u64;
        assert!(jpeg < png);
        let max_bytes = (jpeg + png) / 2;
        assert!(source.len() as u64 > max_bytes);

        let prepared = prepare(source, &budget(2000, max_bytes)).unwrap();
        let conversion = prepared.conversion.as_ref().unwrap();

        assert_eq!(prepared.mime_type, "image/jpeg");
        assert!(prepared.bytes.len() as u64 <= max_bytes);
        assert_eq!(
            (conversion.converted.width, conversion.converted.height),
            (96, 96)
        );
        assert!(prepared
            .notice("/n.png")
            .unwrap()
            .starts_with("Image was converted from 96x96"));
        assert_eq!(prepared.upload_file_name("n.png"), "n.jpg");
    }

    #[test]
    fn transparent_png_over_the_byte_limit_is_downscaled_until_it_fits() {
        let mut red = noise(3);
        let mut alpha = noise(11);
        let image = DynamicImage::ImageRgba8(RgbaImage::from_fn(128, 128, |x, y| {
            Rgba([red(x, y), 90, 40, alpha(x, y)])
        }));
        let source = encoded(&image, ImageFormat::Png);
        let max_bytes = 20_000;
        assert!(source.len() > max_bytes as usize);

        let prepared = prepare(source, &budget(2000, max_bytes)).unwrap();
        let result = decoded(&prepared.bytes);

        assert_eq!(prepared.mime_type, "image/png");
        assert!(prepared.bytes.len() as u64 <= max_bytes);
        assert!(result.color().has_alpha());
        assert!(result.width() < 128 && result.width() == result.height());
        assert!(prepared
            .notice("/t.png")
            .unwrap()
            .starts_with("Image was downscaled from 128x128"));
    }

    #[test]
    fn invalid_content_is_rejected() {
        let png = encoded(&DynamicImage::new_rgb8(2, 2), ImageFormat::Png);
        for source in [Vec::new(), b"<html>404</html>".to_vec(), png[..33].to_vec()] {
            assert_eq!(
                prepare_inline_image(source).unwrap_err(),
                InlineImageError::Invalid
            );
        }
        assert_eq!(
            InlineImageError::Invalid.to_string(),
            "File content is not a valid image."
        );
    }

    #[test]
    fn decoding_is_bounded_by_the_memory_budget() {
        // A BMP header claiming 30000x30000 RGB pixels (2.5 GB) with no pixel data.
        let mut source = encoded(&DynamicImage::new_rgb8(1, 1), ImageFormat::Bmp);
        source[18..22].copy_from_slice(&30_000i32.to_le_bytes());
        source[22..26].copy_from_slice(&30_000i32.to_le_bytes());

        let error = prepare_inline_image(source).unwrap_err();

        assert_eq!(
            error,
            InlineImageError::DecodeLimit {
                dimensions: Some((30_000, 30_000)),
                required_bytes: Some(2_700_000_000),
                limit_bytes: IMAGE_DECODE_MAX_ALLOC,
            }
        );
        assert_eq!(
            error.to_string(),
            "Image is too large to decode: 30000x30000 pixels need 2.5 GB of memory, more than the 512 MB decoding limit."
        );
    }

    #[test]
    fn oversized_sources_are_rejected_before_decoding() {
        let source = encoded(&DynamicImage::new_rgb8(2, 2), ImageFormat::Png);
        let tight = Budget {
            max_source_bytes: 10,
            ..DEFAULT_BUDGET
        };
        assert!(matches!(
            prepare(source, &tight),
            Err(InlineImageError::SourceTooLarge {
                limit_bytes: 10,
                ..
            })
        ));
    }

    #[tokio::test]
    async fn read_inline_image_reads_a_snapshot_and_reports_missing_files() {
        let path = std::env::temp_dir().join(format!(
            "outlet-core-inline-image-{}-{:?}.png",
            std::process::id(),
            std::time::SystemTime::now()
        ));
        let source = encoded(&DynamicImage::new_rgb8(3, 3), ImageFormat::Png);
        tokio::fs::write(&path, &source).await.unwrap();
        let prepared = read_inline_image(&path).await.unwrap();
        tokio::fs::remove_file(&path).await.unwrap();
        assert_eq!(prepared.bytes, source);

        let error = read_inline_image(&path).await.unwrap_err();
        assert_eq!(error.to_string(), "failed to read image file");
    }

    #[test]
    fn sizes_use_binary_units() {
        assert_eq!(format_size(INLINE_IMAGE_MAX_BYTES), "7.5 MB");
        assert_eq!(format_size(5_347_738), "5.1 MB");
        assert_eq!(format_size(600 * 1024), "600 KB");
        assert_eq!(format_size(1), "1 KB");
        assert_eq!(format_size(IMAGE_SOURCE_MAX_BYTES), "256 MB");
        assert_eq!(format_size(2_700_000_000), "2.5 GB");
    }
}
