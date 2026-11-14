/**
 * Browser-side normalization of chat image attachments.
 *
 * The server embeds an attachment into the model context as an image only when it
 * is JPEG, PNG, GIF or WebP, its long side is at most MODEL_IMAGE_MAX_SIDE_PX and it
 * is at most MODEL_IMAGE_MAX_BYTES long. Any other file reaches the model as a
 * reference to the stored file. Images that already fit are uploaded byte-for-byte
 * (animation and metadata included); larger images and other formats the browser can
 * decode (HEIC in Safari, AVIF, BMP, TIFF, ...) are re-encoded into a copy that fits.
 */

export const MODEL_IMAGE_MAX_SIDE_PX = 2000;
export const MODEL_IMAGE_MAX_BYTES = 7_864_320;

export type ImageLimits = { maxSidePx: number; maxBytes: number };

export const MODEL_IMAGE_LIMITS: Readonly<ImageLimits> = Object.freeze({
  maxSidePx: MODEL_IMAGE_MAX_SIDE_PX,
  maxBytes: MODEL_IMAGE_MAX_BYTES,
});

export type ImageFormat = 'jpeg' | 'png' | 'gif' | 'webp' | 'heic' | 'avif' | 'jxl' | 'bmp' | 'tiff';

const EMBEDDABLE_FORMATS: ReadonlySet<ImageFormat> = new Set(['jpeg', 'png', 'gif', 'webp']);

export const isEmbeddableImageFormat = (format: ImageFormat) => EMBEDDABLE_FORMATS.has(format);

export type ImageDimensions = { width: number; height: number };

export type WebpFeatures = {
  // Bitstream of the still image or, for an animation, of its first frame.
  bitstream: 'lossy' | 'lossless';
  // Whether that image may have transparent pixels.
  alpha: boolean;
};

export type ImageHeader = {
  format: ImageFormat;
  // Stored (pre-EXIF-rotation) dimensions; null when the header does not reveal them.
  width: number | null;
  height: number | null;
  // WebP only, when the header reveals them.
  webp?: WebpFeatures;
};

const matchesAscii = (bytes: Uint8Array, offset: number, text: string) => {
  if (offset < 0 || offset + text.length > bytes.length) return false;
  for (let index = 0; index < text.length; index += 1) {
    if (bytes[offset + index] !== text.charCodeAt(index)) return false;
  }
  return true;
};

const matchesBytes = (bytes: Uint8Array, offset: number, expected: readonly number[]) =>
  offset + expected.length <= bytes.length && expected.every((value, index) => bytes[offset + index] === value);

const uint16be = (bytes: Uint8Array, offset: number) => (bytes[offset] << 8) | bytes[offset + 1];
const uint16le = (bytes: Uint8Array, offset: number) => bytes[offset] | (bytes[offset + 1] << 8);
const uint24le = (bytes: Uint8Array, offset: number) =>
  bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
const uint32be = (bytes: Uint8Array, offset: number) =>
  ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
const uint32le = (bytes: Uint8Array, offset: number) =>
  (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] as const;
const JXL_CONTAINER_SIGNATURE = [0x00, 0x00, 0x00, 0x0c, 0x4a, 0x58, 0x4c, 0x20, 0x0d, 0x0a, 0x87, 0x0a] as const;
const BMP_DIB_HEADER_SIZES = new Set([12, 16, 40, 52, 56, 64, 108, 124]);
const AVIF_BRANDS = new Set(['avif', 'avis']);
const HEIF_BRANDS = new Set(['heic', 'heix', 'heim', 'heis', 'hevc', 'hevx', 'hevm', 'hevs', 'mif1', 'msf1']);

// ISO BMFF (HEIF/AVIF) files start with an `ftyp` box listing the major and compatible brands.
const sniffIsoBmffImage = (bytes: Uint8Array): ImageFormat | null => {
  if (!matchesAscii(bytes, 4, 'ftyp')) return null;

  // Real files list a handful of brands; the cap bounds the scan of arbitrary data.
  const boxSize = Math.min(uint32be(bytes, 0), bytes.length, 256);
  const brands: string[] = [];
  const readBrand = (offset: number) => String.fromCharCode(...bytes.subarray(offset, offset + 4));
  if (bytes.length >= 12) brands.push(readBrand(8));
  for (let offset = 16; offset + 4 <= boxSize; offset += 4) brands.push(readBrand(offset));

  if (brands.some((brand) => AVIF_BRANDS.has(brand))) return 'avif';
  if (brands.some((brand) => HEIF_BRANDS.has(brand))) return 'heic';
  return null;
};

/** Detects the image format from the leading bytes of a file, ignoring its name and MIME type. */
export const sniffImageFormat = (bytes: Uint8Array): ImageFormat | null => {
  if (matchesBytes(bytes, 0, [0xff, 0xd8, 0xff])) return 'jpeg';
  if (matchesBytes(bytes, 0, PNG_SIGNATURE)) return 'png';
  if (matchesAscii(bytes, 0, 'GIF87a') || matchesAscii(bytes, 0, 'GIF89a')) return 'gif';
  if (matchesAscii(bytes, 0, 'RIFF') && matchesAscii(bytes, 8, 'WEBP')) return 'webp';
  if (matchesBytes(bytes, 0, [0xff, 0x0a]) || matchesBytes(bytes, 0, JXL_CONTAINER_SIGNATURE)) return 'jxl';
  if (matchesBytes(bytes, 0, [0x49, 0x49, 0x2a, 0x00]) || matchesBytes(bytes, 0, [0x4d, 0x4d, 0x00, 0x2a])) {
    return 'tiff';
  }
  // "BM" alone is too weak a signature; also require a known DIB header size.
  if (matchesAscii(bytes, 0, 'BM') && bytes.length >= 18 && BMP_DIB_HEADER_SIZES.has(uint32le(bytes, 14))) {
    return 'bmp';
  }
  return sniffIsoBmffImage(bytes);
};

const isJpegStartOfFrame = (marker: number) =>
  marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;

const readJpegDimensions = (bytes: Uint8Array): ImageDimensions | null => {
  let offset = 2;

  while (offset + 4 <= bytes.length) {
    if (bytes[offset] !== 0xff) return null;
    const marker = bytes[offset + 1];
    if (marker === 0xff) {
      // Fill byte before a marker.
      offset += 1;
      continue;
    }

    offset += 2;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
    // The image data (SOS) or the end of the image comes before any frame header.
    if (marker === 0xd9 || marker === 0xda) return null;

    const segmentLength = uint16be(bytes, offset);
    if (segmentLength < 2) return null;

    if (isJpegStartOfFrame(marker)) {
      if (offset + 7 > bytes.length) return null;
      const height = uint16be(bytes, offset + 3);
      const width = uint16be(bytes, offset + 5);
      // A zero height is defined later by a DNL marker; treat it as unknown.
      return width > 0 && height > 0 ? { width, height } : null;
    }

    offset += segmentLength;
  }

  return null;
};

const readPngDimensions = (bytes: Uint8Array): ImageDimensions | null => {
  if (bytes.length < 24 || !matchesAscii(bytes, 12, 'IHDR')) return null;
  const width = uint32be(bytes, 16);
  const height = uint32be(bytes, 20);
  return width > 0 && height > 0 ? { width, height } : null;
};

const readGifDimensions = (bytes: Uint8Array): ImageDimensions | null => {
  if (bytes.length < 10) return null;
  const width = uint16le(bytes, 6);
  const height = uint16le(bytes, 8);
  return width > 0 && height > 0 ? { width, height } : null;
};

type RiffChunk = { name: string; payload: number; size: number };

/** First chunk with one of `names` among the RIFF chunks laid out in [start, end) of the available bytes. */
const findRiffChunk = (bytes: Uint8Array, start: number, end: number, names: readonly string[]): RiffChunk | null => {
  const limit = Math.min(end, bytes.length);
  for (let offset = start; offset + 8 <= limit; ) {
    const size = uint32le(bytes, offset + 4);
    const name = names.find((candidate) => matchesAscii(bytes, offset, candidate));
    if (name) return { name, payload: offset + 8, size };
    // Chunk payloads are padded to an even length.
    offset += 8 + size + (size & 1);
  }
  return null;
};

const riffChunkEnd = (chunk: RiffChunk) => chunk.payload + chunk.size + (chunk.size & 1);

const VP8X_ALPHA_FLAG = 0x10;
const VP8X_ANIMATION_FLAG = 0x02;
// The VP8X chunk is 18 bytes long and comes right after the 12-byte RIFF header.
const VP8X_CHUNKS_OFFSET = 30;
const ANMF_HEADER_BYTES = 16;

// The VP8L header (signature 0x2F, then a 32-bit field) ends with an alpha_is_used bit.
const vp8lUsesAlpha = (bytes: Uint8Array, payload: number) =>
  payload + 5 <= bytes.length && ((uint32le(bytes, payload + 1) >>> 28) & 1) === 1;

// Image data of a still image or of an animation frame: an optional ALPH chunk, then the bitstream.
const readWebpImageFeatures = (
  bytes: Uint8Array,
  start: number,
  end: number,
  alphaFlag: boolean
): WebpFeatures | null => {
  let chunk = findRiffChunk(bytes, start, end, ['ALPH', 'VP8 ', 'VP8L']);
  // Decoders apply an ALPH chunk even when the VP8X alpha flag is not set.
  const alpha = alphaFlag || chunk?.name === 'ALPH';
  if (chunk?.name === 'ALPH') chunk = findRiffChunk(bytes, riffChunkEnd(chunk), end, ['VP8 ', 'VP8L']);
  if (!chunk) return null;
  if (chunk.name === 'VP8L') return { bitstream: 'lossless', alpha: alpha || vp8lUsesAlpha(bytes, chunk.payload) };
  return { bitstream: 'lossy', alpha };
};

const readWebpExtendedFeatures = (bytes: Uint8Array, canvas: ImageDimensions): WebpFeatures | null => {
  const flags = bytes[20];
  const riffEnd = 8 + uint32le(bytes, 4);
  if ((flags & VP8X_ANIMATION_FLAG) === 0) {
    return readWebpImageFeatures(bytes, VP8X_CHUNKS_OFFSET, riffEnd, (flags & VP8X_ALPHA_FLAG) !== 0);
  }

  // A conversion keeps only the first frame, so that frame decides. The alpha flag tells
  // nothing about it: encoders set it whenever later frames leave unchanged pixels transparent.
  const frame = findRiffChunk(bytes, VP8X_CHUNKS_OFFSET, riffEnd, ['ANMF']);
  if (!frame || frame.payload + ANMF_HEADER_BYTES > bytes.length) return null;
  const features = readWebpImageFeatures(
    bytes,
    frame.payload + ANMF_HEADER_BYTES,
    Math.min(riffEnd, frame.payload + frame.size),
    false
  );
  if (!features) return null;

  // Frame header: X / 2, Y / 2, (width - 1), (height - 1) and duration as 24-bit fields, then flags.
  const coversCanvas =
    uint24le(bytes, frame.payload) === 0 &&
    uint24le(bytes, frame.payload + 3) === 0 &&
    uint24le(bytes, frame.payload + 6) + 1 === canvas.width &&
    uint24le(bytes, frame.payload + 9) + 1 === canvas.height;
  // The canvas around a smaller frame decodes as transparent.
  return coversCanvas ? features : { ...features, alpha: true };
};

type WebpHeader = ImageDimensions & { features: WebpFeatures | null };

const readWebpHeader = (bytes: Uint8Array): WebpHeader | null => {
  if (matchesAscii(bytes, 12, 'VP8 ')) {
    // Lossy bitstream: 3-byte frame tag, start code 9D 01 2A, then 14-bit width and height.
    // The simple lossy format has no alpha channel.
    if (bytes.length < 30 || !matchesBytes(bytes, 23, [0x9d, 0x01, 0x2a])) return null;
    return {
      width: uint16le(bytes, 26) & 0x3fff,
      height: uint16le(bytes, 28) & 0x3fff,
      features: { bitstream: 'lossy', alpha: false },
    };
  }

  if (matchesAscii(bytes, 12, 'VP8L')) {
    // Lossless bitstream: signature 0x2F, then (width - 1) and (height - 1) as 14-bit fields.
    if (bytes.length < 25 || bytes[20] !== 0x2f) return null;
    const bits = uint32le(bytes, 21);
    return {
      width: (bits & 0x3fff) + 1,
      height: ((bits >>> 14) & 0x3fff) + 1,
      features: { bitstream: 'lossless', alpha: vp8lUsesAlpha(bytes, 20) },
    };
  }

  if (matchesAscii(bytes, 12, 'VP8X')) {
    // Extended format: flags and reserved bytes, then 24-bit (width - 1) and (height - 1) of the canvas.
    if (bytes.length < 30) return null;
    const canvas = { width: uint24le(bytes, 24) + 1, height: uint24le(bytes, 27) + 1 };
    return { ...canvas, features: readWebpExtendedFeatures(bytes, canvas) };
  }

  return null;
};

const readWebpDimensions = (bytes: Uint8Array): ImageDimensions | null => {
  const header = readWebpHeader(bytes);
  return header && { width: header.width, height: header.height };
};

/** Reads image dimensions from the header of a JPEG, PNG, GIF or WebP file without decoding it. */
export const readImageDimensions = (bytes: Uint8Array, format: ImageFormat): ImageDimensions | null => {
  switch (format) {
    case 'jpeg':
      return readJpegDimensions(bytes);
    case 'png':
      return readPngDimensions(bytes);
    case 'gif':
      return readGifDimensions(bytes);
    case 'webp':
      return readWebpDimensions(bytes);
    default:
      return null;
  }
};

export const parseImageHeader = (bytes: Uint8Array): ImageHeader | null => {
  const format = sniffImageFormat(bytes);
  if (!format) return null;
  if (format === 'webp') {
    const webp = readWebpHeader(bytes);
    return {
      format,
      width: webp?.width ?? null,
      height: webp?.height ?? null,
      ...(webp?.features ? { webp: webp.features } : {}),
    };
  }

  const dimensions = readImageDimensions(bytes, format);
  return { format, width: dimensions?.width ?? null, height: dimensions?.height ?? null };
};

export type ImageConversionReason = 'format' | 'dimensions' | 'bytes' | 'unknown-dimensions';

export type ImageUploadPlan =
  | { action: 'keep'; header: ImageHeader }
  | { action: 'convert'; header: ImageHeader; reasons: ImageConversionReason[] };

export type ImageConversionPlan = Extract<ImageUploadPlan, { action: 'convert' }>;

/** Decides whether an image is uploaded as is or replaced by a browser-encoded copy. */
export const planImageUpload = (
  header: ImageHeader,
  byteSize: number,
  limits: ImageLimits = MODEL_IMAGE_LIMITS
): ImageUploadPlan => {
  const reasons: ImageConversionReason[] = [];
  const embeddable = isEmbeddableImageFormat(header.format);

  if (!embeddable) reasons.push('format');
  if (byteSize > limits.maxBytes) reasons.push('bytes');
  if (header.width !== null && header.height !== null) {
    if (Math.max(header.width, header.height) > limits.maxSidePx) reasons.push('dimensions');
  } else if (embeddable) {
    reasons.push('unknown-dimensions');
  }

  return reasons.length === 0 ? { action: 'keep', header } : { action: 'convert', header, reasons };
};

/** Scales dimensions down (never up) so that the long side fits `maxSide`. */
export const fitWithinSide = (width: number, height: number, maxSide: number): ImageDimensions => {
  const scale = Math.min(1, maxSide / Math.max(width, height, 1));
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
};

/** Next, smaller dimensions for an encoding that came out `actualBytes` long against a `maxBytes` budget. */
export const shrinkForByteBudget = (
  dimensions: ImageDimensions,
  actualBytes: number,
  maxBytes: number
): ImageDimensions => {
  // Encoded size grows roughly with the pixel count; aim a little below the budget.
  const scale = Math.min(0.9, Math.max(0.5, Math.sqrt(maxBytes / Math.max(actualBytes, 1)) * 0.95));
  return {
    width: Math.max(1, Math.floor(dimensions.width * scale)),
    height: Math.max(1, Math.floor(dimensions.height * scale)),
  };
};

export type OutputEncoding = 'jpeg' | 'png' | 'jpeg-unless-transparent';

/**
 * Photo-like sources become JPEG, graphics-like sources start as PNG. A lossy WebP
 * without alpha counts as a photo: as a PNG it would come out several times larger.
 */
export const initialOutputEncoding = (header: Pick<ImageHeader, 'format' | 'webp'>): OutputEncoding => {
  const { format, webp } = header;
  if (format === 'jpeg') return 'jpeg';
  if (format === 'webp' && webp?.bitstream === 'lossy' && !webp.alpha) return 'jpeg';
  if (format === 'heic' || format === 'avif' || format === 'jxl') return 'jpeg-unless-transparent';
  return 'png';
};

export const replaceFileExtension = (name: string, extension: string) => {
  const trimmed = name.trim() || 'image';
  const dot = trimmed.lastIndexOf('.');
  const stem = dot > 0 ? trimmed.slice(0, dot) : trimmed;
  return `${stem}.${extension}`;
};

const extensionForMimeType = (mimeType: string) => {
  const normalized = mimeType.toLowerCase();
  if (normalized === 'image/jpeg') return 'jpg';
  if (normalized === 'image/png') return 'png';
  if (normalized === 'image/webp') return 'webp';
  return normalized.split('/')[1]?.replace(/[^a-z0-9]/gu, '') || 'img';
};

const HEADER_PROBE_BYTES = 256 * 1024;

const readLeadingBytes = async (blob: Blob, length: number) =>
  new Uint8Array(await blob.slice(0, length).arrayBuffer());

/**
 * Reads the header of a file and plans its upload; resolves to null for files that
 * are not raster images this module knows about.
 */
export const inspectImageFile = async (
  file: Blob,
  limits: ImageLimits = MODEL_IMAGE_LIMITS
): Promise<ImageUploadPlan | null> => {
  const head = await readLeadingBytes(file, Math.min(file.size, HEADER_PROBE_BYTES));
  let header = parseImageHeader(head);
  if (!header) return null;

  // Large metadata segments can push the JPEG frame header past the probe. Only files
  // within the byte limit need their dimensions to decide; read those completely.
  if (header.format === 'jpeg' && header.width === null && file.size > head.length && file.size <= limits.maxBytes) {
    header = parseImageHeader(await readLeadingBytes(file, file.size)) ?? header;
  }

  return planImageUpload(header, file.size, limits);
};

export type DecodedImage = {
  // Dimensions after the EXIF orientation is applied.
  width: number;
  height: number;
  source: CanvasImageSource;
  close: () => void;
};

export type RenderedImage = {
  hasTransparency: () => boolean;
  encode: (mimeType: 'image/jpeg' | 'image/png', quality?: number) => Promise<Blob>;
  release: () => void;
};

export type ImageCanvasBackend = {
  decode: (file: Blob) => Promise<DecodedImage>;
  render: (image: DecodedImage, width: number, height: number) => RenderedImage;
};

type AnyCanvas = OffscreenCanvas | HTMLCanvasElement;
type AnyCanvasContext = OffscreenCanvasRenderingContext2D | CanvasRenderingContext2D;

const createCanvas = (width: number, height: number): AnyCanvas => {
  if (typeof OffscreenCanvas === 'function') return new OffscreenCanvas(width, height);
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  return canvas;
};

const encodeCanvas = (canvas: AnyCanvas, type: string, quality?: number) => {
  if (typeof OffscreenCanvas === 'function' && canvas instanceof OffscreenCanvas) {
    return canvas.convertToBlob({ type, quality });
  }

  return new Promise<Blob>((resolve, reject) => {
    (canvas as HTMLCanvasElement).toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error('Canvas encoding failed.'))),
      type,
      quality
    );
  });
};

const createCanvasContext = (width: number, height: number) => {
  const canvas = createCanvas(width, height);
  const context = canvas.getContext('2d') as AnyCanvasContext | null;
  if (!context) throw new Error('Canvas 2D context is unavailable.');

  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = 'high';
  return { canvas, context };
};

const releaseCanvas = (canvas: AnyCanvas) => {
  // Frees the backing store right away; Safari keeps it alive until collection otherwise.
  canvas.width = 0;
  canvas.height = 0;
};

// iOS Safari refuses canvases above 16,777,216 pixels.
const MAX_INTERMEDIATE_CANVAS_PIXELS = 16_000_000;

/**
 * Next size on the way from `current` down to `target`: at most a halving per step,
 * since a single bilinear pass over a larger factor skips source pixels (WebKit does
 * not area-average even with high smoothing quality). The first step may shrink more
 * to keep the intermediate canvas within the iOS size limit.
 */
export const nextDownscaleStep = (current: ImageDimensions, target: ImageDimensions): ImageDimensions => {
  let width = Math.max(target.width, Math.ceil(current.width / 2));
  let height = Math.max(target.height, Math.ceil(current.height / 2));

  if (width * height > MAX_INTERMEDIATE_CANVAS_PIXELS) {
    const scale = Math.sqrt(MAX_INTERMEDIATE_CANVAS_PIXELS / (width * height));
    width = Math.max(target.width, Math.floor(width * scale));
    height = Math.max(target.height, Math.floor(height * scale));
  }

  return { width, height };
};

const hasTransparentPixel = (data: Uint8ClampedArray) => {
  for (let index = 3; index < data.length; index += 4) {
    if (data[index] < 255) return true;
  }
  return false;
};

const decodeImageBitmap = async (file: Blob) => {
  try {
    // The EXIF orientation is applied while decoding.
    return await createImageBitmap(file, { imageOrientation: 'from-image' });
  } catch (error) {
    // Older engines reject the option value itself; decoding errors are DOMExceptions.
    if (!(error instanceof TypeError)) throw error;
    return createImageBitmap(file);
  }
};

/**
 * Canvas backend of the current browser, or null when it cannot decode images.
 *
 * Images are resized by drawing them onto a canvas with high-quality smoothing; the
 * resize options of createImageBitmap are not used because WebKit implements them with
 * nearly nearest-neighbour sampling.
 */
export const createBrowserImageBackend = (): ImageCanvasBackend | null => {
  if (typeof createImageBitmap !== 'function') return null;
  if (typeof OffscreenCanvas !== 'function' && typeof document === 'undefined') return null;

  return {
    decode: async (file) => {
      const bitmap = await decodeImageBitmap(file);
      return { width: bitmap.width, height: bitmap.height, source: bitmap, close: () => bitmap.close() };
    },
    render: (image, width, height) => {
      let source: CanvasImageSource = image.source;
      let current: ImageDimensions = { width: image.width, height: image.height };
      let intermediate: AnyCanvas | null = null;

      while (current.width > width * 2 || current.height > height * 2) {
        current = nextDownscaleStep(current, { width, height });
        const step = createCanvasContext(current.width, current.height);
        step.context.drawImage(source, 0, 0, current.width, current.height);
        if (intermediate) releaseCanvas(intermediate);
        intermediate = step.canvas;
        source = step.canvas;
      }

      const { canvas, context } = createCanvasContext(width, height);
      context.drawImage(source, 0, 0, width, height);
      if (intermediate) releaseCanvas(intermediate);

      let transparent: boolean | null = null;
      return {
        hasTransparency: () => {
          transparent ??= hasTransparentPixel(context.getImageData(0, 0, width, height).data);
          return transparent;
        },
        encode: (type, quality) => encodeCanvas(canvas, type, quality),
        release: () => releaseCanvas(canvas),
      };
    },
  };
};

export type ImageConversionResult =
  // Header dimensions were unknown, but the decoded image fits: upload the original.
  | { kind: 'unchanged'; width: number; height: number }
  | {
      kind: 'converted';
      file: File;
      width: number;
      height: number;
      sourceWidth: number;
      sourceHeight: number;
    }
  | { kind: 'failed'; reason: 'decode' | 'encode'; error?: unknown };

export type ImageConversionOptions = {
  backend?: ImageCanvasBackend | null;
  limits?: ImageLimits;
};

const JPEG_QUALITY = 0.9;
const MAX_ENCODING_ATTEMPTS = 6;

/** Re-encodes an image into a copy within the limits; never rejects. */
export const convertImageFile = async (
  file: File,
  plan: ImageConversionPlan,
  options: ImageConversionOptions = {}
): Promise<ImageConversionResult> => {
  const limits = options.limits ?? MODEL_IMAGE_LIMITS;
  const backend = options.backend === undefined ? createBrowserImageBackend() : options.backend;
  if (!backend) return { kind: 'failed', reason: 'decode' };

  let decoded: DecodedImage;
  try {
    decoded = await backend.decode(file);
  } catch (error) {
    return { kind: 'failed', reason: 'decode', error };
  }

  try {
    const sourceWidth = decoded.width;
    const sourceHeight = decoded.height;
    if (sourceWidth <= 0 || sourceHeight <= 0) return { kind: 'failed', reason: 'decode' };

    const onlyDimensionsUnknown = plan.reasons.every((reason) => reason === 'unknown-dimensions');
    if (onlyDimensionsUnknown && Math.max(sourceWidth, sourceHeight) <= limits.maxSidePx) {
      return { kind: 'unchanged', width: sourceWidth, height: sourceHeight };
    }

    let target = fitWithinSide(sourceWidth, sourceHeight, limits.maxSidePx);
    let encoding = initialOutputEncoding(plan.header);

    for (let attempt = 0; attempt < MAX_ENCODING_ATTEMPTS; attempt += 1) {
      const rendered = backend.render(decoded, target.width, target.height);
      let blob: Blob;
      try {
        if (encoding === 'jpeg-unless-transparent') {
          encoding = rendered.hasTransparency() ? 'png' : 'jpeg';
        }

        blob = await rendered.encode(
          encoding === 'jpeg' ? 'image/jpeg' : 'image/png',
          encoding === 'jpeg' ? JPEG_QUALITY : undefined
        );

        // An opaque PNG that is too large is better off as a JPEG of the same size.
        if (blob.size > limits.maxBytes && encoding === 'png' && !rendered.hasTransparency()) {
          encoding = 'jpeg';
          blob = await rendered.encode('image/jpeg', JPEG_QUALITY);
        }
      } finally {
        rendered.release();
      }

      if (blob.size <= limits.maxBytes) {
        const mimeType = blob.type || (encoding === 'jpeg' ? 'image/jpeg' : 'image/png');
        const converted = new File([blob], replaceFileExtension(file.name, extensionForMimeType(mimeType)), {
          type: mimeType,
          lastModified: file.lastModified,
        });
        return { kind: 'converted', file: converted, ...target, sourceWidth, sourceHeight };
      }

      target = shrinkForByteBudget(target, blob.size, limits.maxBytes);
    }

    return { kind: 'failed', reason: 'encode' };
  } catch (error) {
    return { kind: 'failed', reason: 'encode', error };
  } finally {
    decoded.close();
  }
};

let conversionQueue: Promise<unknown> = Promise.resolve();

/**
 * Runs image conversions one at a time: decoding several camera photos at once can
 * exhaust the memory of a phone.
 */
export const enqueueImageConversion = <T>(task: () => Promise<T>): Promise<T> => {
  const run = conversionQueue.then(task);
  conversionQueue = run.catch(() => undefined);
  return run;
};
