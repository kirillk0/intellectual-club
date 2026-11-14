import {
  convertImageFile,
  enqueueImageConversion,
  fitWithinSide,
  initialOutputEncoding,
  inspectImageFile,
  MODEL_IMAGE_MAX_BYTES,
  nextDownscaleStep,
  parseImageHeader,
  planImageUpload,
  replaceFileExtension,
  shrinkForByteBudget,
  sniffImageFormat,
  type ImageCanvasBackend,
  type ImageConversionPlan,
  type ImageFormat,
  type ImageHeader,
  type ImageLimits,
  type WebpFeatures,
} from '@/features/chat/imageNormalization';

type Part = number[] | Uint8Array | string;

const concat = (...parts: Part[]) => {
  const chunks = parts.map((part) =>
    typeof part === 'string' ? Uint8Array.from(part, (char) => char.charCodeAt(0)) : Uint8Array.from(part)
  );
  const result = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.length;
  }
  return result;
};

const u16be = (value: number) => [(value >> 8) & 0xff, value & 0xff];
const u16le = (value: number) => [value & 0xff, (value >> 8) & 0xff];
const u24le = (value: number) => [value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff];
const u32be = (value: number) => [(value >>> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];
const u32le = (value: number) => [value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >>> 24) & 0xff];

const jpegSegment = (marker: number, payload: Part) => {
  const body = concat(payload);
  return concat([0xff, marker], u16be(body.length + 2), body);
};

const jpeg = (width: number, height: number, options: { sof?: number; before?: Uint8Array[] } = {}) =>
  concat(
    [0xff, 0xd8],
    ...(options.before ?? []),
    jpegSegment(0xdb, new Uint8Array(65)),
    jpegSegment(options.sof ?? 0xc0, concat([8], u16be(height), u16be(width), [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])),
    jpegSegment(0xda, new Uint8Array(10)),
    [0x00, 0x00, 0xff, 0xd9]
  );

const png = (width: number, height: number) =>
  concat([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], u32be(13), 'IHDR', u32be(width), u32be(height), [8, 6, 0, 0, 0], [0, 0, 0, 0]);

const gif = (width: number, height: number) => concat('GIF89a', u16le(width), u16le(height), [0xf7, 0, 0]);

const riffChunk = (name: string, payload: Part) => {
  const body = concat(payload);
  return concat(name, u32le(body.length), body, body.length % 2 === 1 ? [0] : []);
};
const riff = (...chunks: Uint8Array[]) => {
  const body = concat(...chunks);
  return concat('RIFF', u32le(body.length + 4), 'WEBP', body);
};
const vp8 = (width: number, height: number) =>
  riffChunk('VP8 ', concat([0x50, 0x09, 0x00, 0x9d, 0x01, 0x2a], u16le(width), u16le(height)));
const vp8l = (width: number, height: number, alpha = false) =>
  riffChunk('VP8L', concat([0x2f], u32le(((width - 1) | ((height - 1) << 14) | (alpha ? 1 << 28 : 0)) >>> 0)));
const VP8X_ALPHA = 0x10;
const VP8X_ANIMATION = 0x02;
const vp8x = (width: number, height: number, flags: number) =>
  riffChunk('VP8X', concat([flags, 0, 0, 0], u24le(width - 1), u24le(height - 1)));
const alph = riffChunk('ALPH', [0, 1, 2]);
const iccp = riffChunk('ICCP', new Uint8Array(3_000));
const anim = riffChunk('ANIM', concat(u32le(0), u16le(0)));
const anmf = (frame: { x?: number; y?: number; width: number; height: number }, ...chunks: Uint8Array[]) =>
  riffChunk(
    'ANMF',
    concat(
      u24le((frame.x ?? 0) / 2),
      u24le((frame.y ?? 0) / 2),
      u24le(frame.width - 1),
      u24le(frame.height - 1),
      u24le(100),
      [0],
      ...chunks
    )
  );
const webpLossy = (width: number, height: number) => riff(vp8(width, height));
const webpLossless = (width: number, height: number) => riff(vp8l(width, height));
const webpExtended = (width: number, height: number, flags = VP8X_ALPHA, ...chunks: Uint8Array[]) =>
  riff(vp8x(width, height, flags), ...chunks);

const isoBmff = (major: string, ...compatible: string[]) =>
  concat(u32be(16 + compatible.length * 4), 'ftyp', major, u32be(0), ...compatible, u32be(8), 'meta');

const bmp = () => concat('BM', u32le(70), u32le(0), u32le(54), u32le(40), u32le(4), u32le(4));

const limits: ImageLimits = { maxSidePx: 2000, maxBytes: 1_000 };

describe('sniffImageFormat', () => {
  it.each<[string, Uint8Array, ImageFormat | null]>([
    ['JPEG', jpeg(10, 10), 'jpeg'],
    ['PNG', png(10, 10), 'png'],
    ['GIF87a', concat('GIF87a', u16le(1), u16le(1)), 'gif'],
    ['GIF89a', gif(1, 1), 'gif'],
    ['WebP', webpLossy(10, 10), 'webp'],
    ['HEIC', isoBmff('heic', 'mif1', 'heic'), 'heic'],
    ['HEIF with a generic major brand', isoBmff('mif1', 'mif1', 'heic'), 'heic'],
    ['AVIF', isoBmff('avif', 'mif1', 'miaf'), 'avif'],
    ['AVIF with a generic major brand', isoBmff('mif1', 'avif', 'miaf'), 'avif'],
    ['JPEG XL codestream', concat([0xff, 0x0a, 0x00]), 'jxl'],
    ['JPEG XL container', concat([0, 0, 0, 0x0c], 'JXL ', [0x0d, 0x0a, 0x87, 0x0a]), 'jxl'],
    ['little-endian TIFF', concat('II', [0x2a, 0x00, 8, 0, 0, 0]), 'tiff'],
    ['big-endian TIFF', concat('MM', [0x00, 0x2a, 0, 0, 0, 8]), 'tiff'],
    ['BMP', bmp(), 'bmp'],
    ['text starting with BM', concat('BMW drivers manual, chapter one'), null],
    ['MP4 video', isoBmff('isom', 'isom', 'avc1', 'mp41'), null],
    ['PDF', concat('%PDF-1.7\n'), null],
    ['SVG', concat('<svg xmlns="http://www.w3.org/2000/svg"/>'), null],
    ['an empty file', new Uint8Array(0), null],
  ])('detects %s', (_label, bytes, expected) => {
    expect(sniffImageFormat(bytes)).toBe(expected);
  });

  it('ignores the declared name and MIME type', async () => {
    const file = new File([png(3000, 10)], 'photo.jpg', { type: 'image/jpeg' });
    await expect(inspectImageFile(file)).resolves.toMatchObject({ header: { format: 'png', width: 3000 } });
  });
});

describe('parseImageHeader', () => {
  it.each<[string, Uint8Array, number | null, number | null]>([
    ['baseline JPEG', jpeg(4032, 3024), 4032, 3024],
    ['progressive JPEG', jpeg(8064, 6048, { sof: 0xc2 }), 8064, 6048],
    ['PNG', png(2001, 17), 2001, 17],
    ['GIF', gif(640, 480), 640, 480],
    ['lossy WebP', webpLossy(3000, 2000), 3000, 2000],
    ['lossless WebP', webpLossless(16383, 1), 16383, 1],
    ['extended WebP', webpExtended(9000, 7000), 9000, 7000],
    ['HEIC without dimensions', isoBmff('heic', 'mif1'), null, null],
  ])('reads the dimensions of a %s', (_label, bytes, width, height) => {
    expect(parseImageHeader(bytes)).toMatchObject({ width, height });
  });

  const lossy = (alpha: boolean): WebpFeatures => ({ bitstream: 'lossy', alpha });
  const lossless = (alpha: boolean): WebpFeatures => ({ bitstream: 'lossless', alpha });

  it.each<[string, Uint8Array, WebpFeatures | undefined]>([
    ['a simple lossy WebP', webpLossy(3000, 2000), lossy(false)],
    ['a simple lossless WebP', webpLossless(300, 200), lossless(false)],
    ['a simple lossless WebP with alpha', riff(vp8l(300, 200, true)), lossless(true)],
    ['an extended lossy WebP after an ICC profile', webpExtended(3000, 2000, 0x20, iccp, vp8(3000, 2000)), lossy(false)],
    ['an extended lossy WebP with alpha', webpExtended(3000, 2000, VP8X_ALPHA, alph, vp8(3000, 2000)), lossy(true)],
    ['an ALPH chunk without the alpha flag', webpExtended(3000, 2000, 0, alph, vp8(3000, 2000)), lossy(true)],
    ['an extended lossless WebP', webpExtended(3000, 2000, 0, vp8l(3000, 2000)), lossless(false)],
    [
      'an animation by its first frame',
      webpExtended(3000, 2000, VP8X_ANIMATION, anim, anmf({ width: 3000, height: 2000 }, vp8(3000, 2000)), anmf({ width: 8, height: 8 }, vp8l(8, 8))),
      lossy(false),
    ],
    [
      'an animation whose first frame leaves part of the canvas empty',
      webpExtended(3000, 2000, VP8X_ANIMATION, anim, anmf({ x: 10, width: 2990, height: 2000 }, vp8(2990, 2000))),
      lossy(true),
    ],
    [
      'an animation whose later frames have alpha',
      webpExtended(
        3000,
        2000,
        VP8X_ANIMATION | VP8X_ALPHA,
        anim,
        anmf({ width: 3000, height: 2000 }, vp8(3000, 2000)),
        anmf({ width: 3000, height: 2000 }, alph, vp8(3000, 2000))
      ),
      lossy(false),
    ],
    [
      'an animation whose first frame has alpha',
      webpExtended(3000, 2000, VP8X_ANIMATION | VP8X_ALPHA, anim, anmf({ width: 3000, height: 2000 }, alph, vp8(3000, 2000))),
      lossy(true),
    ],
    [
      'an animation whose first frame is lossless',
      webpExtended(3000, 2000, VP8X_ANIMATION, anim, anmf({ width: 3000, height: 2000 }, vp8l(3000, 2000))),
      lossless(false),
    ],
    ['a WebP whose bitstream is past the read bytes', webpExtended(3000, 2000, 0, iccp, vp8(3000, 2000)).subarray(0, 100), undefined],
  ])('reads the bitstream and alpha of %s', (_label, bytes, webp) => {
    expect(parseImageHeader(bytes)?.webp).toEqual(webp);
  });

  it('skips metadata segments, including frame headers of embedded thumbnails', () => {
    const exif = jpegSegment(0xe1, concat('Exif', [0, 0], [0xff, 0xd8], jpegSegment(0xc0, concat([8], u16be(120), u16be(160)))));
    const fill = new Uint8Array([0xff, 0xff]);
    const bytes = jpeg(4000, 3000, { before: [exif, jpegSegment(0xe2, new Uint8Array(500)), fill] });

    expect(parseImageHeader(bytes)).toEqual({ format: 'jpeg', width: 4000, height: 3000 });
  });

  it('reports unknown dimensions when the JPEG frame header is missing or truncated', () => {
    const full = jpeg(100, 50);
    const sosFirst = concat([0xff, 0xd8], jpegSegment(0xda, new Uint8Array(4)), [0xff, 0xd9]);

    // Cut inside the frame header, after its marker and length.
    expect(parseImageHeader(full.subarray(0, 76))).toEqual({ format: 'jpeg', width: null, height: null });
    expect(parseImageHeader(sosFirst)).toEqual({ format: 'jpeg', width: null, height: null });
    expect(parseImageHeader(jpeg(100, 0))).toEqual({ format: 'jpeg', width: null, height: null });
  });
});

describe('planImageUpload', () => {
  const header = (format: ImageFormat, width: number | null, height: number | null) => ({ format, width, height });

  it('keeps embeddable images within both limits, boundaries included', () => {
    expect(planImageUpload(header('jpeg', 2000, 1500), MODEL_IMAGE_MAX_BYTES)).toEqual({
      action: 'keep',
      header: header('jpeg', 2000, 1500),
    });
    expect(planImageUpload(header('gif', 300, 2000), 10).action).toBe('keep');
    expect(planImageUpload(header('webp', 1, 1), 10).action).toBe('keep');
  });

  it.each<[string, ReturnType<typeof header>, number, string[]]>([
    ['a long side over the limit', header('jpeg', 4032, 3024), 5_000_000, ['dimensions']],
    ['a tall image', header('png', 800, 2001), 100, ['dimensions']],
    ['a file over the byte limit', header('png', 1900, 1900), MODEL_IMAGE_MAX_BYTES + 1, ['bytes']],
    ['a format the model does not accept', header('heic', null, null), 1_000_000, ['format']],
    ['a large BMP', header('bmp', null, null), MODEL_IMAGE_MAX_BYTES + 1, ['format', 'bytes']],
    ['unknown dimensions', header('jpeg', null, null), 1_000, ['unknown-dimensions']],
  ])('converts %s', (_label, imageHeader, size, reasons) => {
    expect(planImageUpload(imageHeader, size)).toEqual({ action: 'convert', header: imageHeader, reasons });
  });
});

describe('inspectImageFile', () => {
  it('returns null for files that are not images', async () => {
    await expect(inspectImageFile(new File(['%PDF-1.7'], 'image.png', { type: 'image/png' }))).resolves.toBeNull();
  });

  it('reads further into a JPEG whose frame header follows large metadata', async () => {
    const appSegments = Array.from({ length: 5 }, () => jpegSegment(0xe2, new Uint8Array(65_000)));
    const bytes = jpeg(1600, 1200, { before: appSegments });
    expect(bytes.length).toBeGreaterThan(256 * 1024);

    await expect(inspectImageFile(new File([bytes], 'photo.jpg'))).resolves.toEqual({
      action: 'keep',
      header: { format: 'jpeg', width: 1600, height: 1200 },
    });
  });

  it('plans a conversion for a JPEG over the byte limit without reading it completely', async () => {
    const appSegments = Array.from({ length: 5 }, () => jpegSegment(0xe2, new Uint8Array(65_000)));
    const file = new File([jpeg(1600, 1200, { before: appSegments })], 'photo.jpg');
    const slice = vi.spyOn(file, 'slice');

    await expect(inspectImageFile(file, { maxSidePx: 2000, maxBytes: 300_000 })).resolves.toMatchObject({
      action: 'convert',
      reasons: ['bytes', 'unknown-dimensions'],
    });
    expect(slice).toHaveBeenCalledTimes(1);
  });
});

describe('geometry and naming helpers', () => {
  it('fits the long side without upscaling', () => {
    expect(fitWithinSide(4032, 3024, 2000)).toEqual({ width: 2000, height: 1500 });
    expect(fitWithinSide(3024, 4032, 2000)).toEqual({ width: 1500, height: 2000 });
    expect(fitWithinSide(20000, 10, 2000)).toEqual({ width: 2000, height: 1 });
    expect(fitWithinSide(800, 600, 2000)).toEqual({ width: 800, height: 600 });
  });

  it('shrinks towards the byte budget by bounded steps', () => {
    expect(shrinkForByteBudget({ width: 2000, height: 1000 }, 2_000, 1_000)).toEqual({ width: 1343, height: 671 });
    expect(shrinkForByteBudget({ width: 2000, height: 1000 }, 1_010, 1_000)).toEqual({ width: 1800, height: 900 });
    expect(shrinkForByteBudget({ width: 2000, height: 1000 }, 100_000, 1_000)).toEqual({ width: 1000, height: 500 });
  });

  it('halves per downscale step and keeps intermediate canvases within the iOS limit', () => {
    const target = { width: 1500, height: 2000 };
    expect(nextDownscaleStep({ width: 6048, height: 8064 }, target)).toEqual({ width: 3024, height: 4032 });
    expect(nextDownscaleStep({ width: 3024, height: 4032 }, target)).toEqual({ width: 1512, height: 2016 });
    expect(nextDownscaleStep({ width: 2500, height: 3500 }, target)).toEqual({ width: 1500, height: 2000 });

    const panorama = nextDownscaleStep({ width: 20000, height: 5000 }, { width: 2000, height: 500 });
    expect(panorama.width * panorama.height).toBeLessThanOrEqual(16_000_000);
    expect(panorama.width / panorama.height).toBeCloseTo(4, 2);
  });

  it.each<[string, string, Pick<ImageHeader, 'format' | 'webp'>]>([
    ['JPEG', 'jpeg', { format: 'jpeg' }],
    ['HEIC', 'jpeg-unless-transparent', { format: 'heic' }],
    ['AVIF', 'jpeg-unless-transparent', { format: 'avif' }],
    ['PNG', 'png', { format: 'png' }],
    ['GIF', 'png', { format: 'gif' }],
    ['lossy WebP', 'jpeg', { format: 'webp', webp: { bitstream: 'lossy', alpha: false } }],
    ['lossy WebP with alpha', 'png', { format: 'webp', webp: { bitstream: 'lossy', alpha: true } }],
    ['lossless WebP', 'png', { format: 'webp', webp: { bitstream: 'lossless', alpha: false } }],
    ['WebP with an unknown bitstream', 'png', { format: 'webp' }],
    ['BMP', 'png', { format: 'bmp' }],
    ['TIFF', 'png', { format: 'tiff' }],
  ])('encodes %s sources as %s first', (_label, encoding, header) => {
    expect(initialOutputEncoding(header)).toBe(encoding);
  });

  it('replaces the file extension', () => {
    expect(replaceFileExtension('photo.heic', 'jpg')).toBe('photo.jpg');
    expect(replaceFileExtension('archive.v2.PNG', 'jpg')).toBe('archive.v2.jpg');
    expect(replaceFileExtension('.hidden', 'png')).toBe('.hidden.png');
    expect(replaceFileExtension('scan', 'png')).toBe('scan.png');
    expect(replaceFileExtension('  ', 'jpg')).toBe('image.jpg');
  });
});

type FakeBackendOptions = {
  width: number;
  height: number;
  transparent?: boolean;
  failDecode?: boolean;
  encodedSize?: (mimeType: string, width: number, height: number) => number;
  blobType?: (mimeType: string) => string;
};

const fakeBackend = (options: FakeBackendOptions) => {
  const calls = {
    renders: [] as Array<[number, number]>,
    encodes: [] as Array<{ mimeType: string; quality?: number; width: number; height: number }>,
    released: 0,
    closed: 0,
  };
  const backend: ImageCanvasBackend = {
    decode: async () => {
      if (options.failDecode) throw new DOMException('The source image could not be decoded.', 'InvalidStateError');
      return {
        width: options.width,
        height: options.height,
        source: {} as CanvasImageSource,
        close: () => {
          calls.closed += 1;
        },
      };
    },
    render: (_image, width, height) => {
      calls.renders.push([width, height]);
      return {
        hasTransparency: () => options.transparent ?? false,
        encode: async (mimeType, quality) => {
          calls.encodes.push({ mimeType, quality, width, height });
          const size = options.encodedSize?.(mimeType, width, height) ?? 100;
          return new Blob([new Uint8Array(size)], { type: options.blobType?.(mimeType) ?? mimeType });
        },
        release: () => {
          calls.released += 1;
        },
      };
    },
  };
  return { backend, calls };
};

const convertPlan = (format: ImageFormat, width: number | null, height: number | null, reasons: ImageConversionPlan['reasons']): ImageConversionPlan => ({
  action: 'convert',
  header: { format, width, height },
  reasons,
});

describe('convertImageFile', () => {
  const source = (name: string) => new File([new Uint8Array(10)], name, { type: 'image/jpeg', lastModified: 1_700_000_000_000 });

  it('re-encodes a large photo as a JPEG that fits the long side, keeping the EXIF-rotated aspect', async () => {
    const { backend, calls } = fakeBackend({ width: 3024, height: 4032 });

    const result = await convertImageFile(source('IMG_0001.JPG'), convertPlan('jpeg', 4032, 3024, ['dimensions']), {
      backend,
      limits,
    });

    expect(result).toMatchObject({ kind: 'converted', width: 1500, height: 2000, sourceWidth: 3024, sourceHeight: 4032 });
    if (result.kind !== 'converted') throw new Error('expected a conversion');
    expect(result.file).toMatchObject({ name: 'IMG_0001.jpg', type: 'image/jpeg', lastModified: 1_700_000_000_000 });
    expect(calls.encodes).toEqual([{ mimeType: 'image/jpeg', quality: 0.9, width: 1500, height: 2000 }]);
    expect(calls.released).toBe(1);
    expect(calls.closed).toBe(1);
  });

  it('turns an opaque HEIC into a JPEG and a transparent one into a PNG', async () => {
    const opaque = fakeBackend({ width: 4000, height: 3000 });
    const transparent = fakeBackend({ width: 4000, height: 3000, transparent: true });
    const plan = convertPlan('heic', null, null, ['format']);

    const jpegResult = await convertImageFile(source('photo.heic'), plan, { backend: opaque.backend, limits });
    const pngResult = await convertImageFile(source('sticker.heic'), plan, { backend: transparent.backend, limits });

    expect(jpegResult).toMatchObject({ kind: 'converted', file: { name: 'photo.jpg', type: 'image/jpeg' } });
    expect(pngResult).toMatchObject({ kind: 'converted', file: { name: 'sticker.png', type: 'image/png' } });
    expect(transparent.calls.encodes).toEqual([{ mimeType: 'image/png', quality: undefined, width: 2000, height: 1500 }]);
  });

  it('re-encodes a lossy WebP without alpha as a JPEG and other WebPs as a PNG', async () => {
    const convert = async (bytes: Uint8Array<ArrayBuffer>) => {
      const file = new File([bytes], 'photo.webp', { type: 'image/webp' });
      const plan = await inspectImageFile(file, limits);
      if (plan?.action !== 'convert') throw new Error('expected a conversion plan');
      const { backend, calls } = fakeBackend({ width: 3000, height: 2000 });
      const result = await convertImageFile(file, plan, { backend, limits });
      return { result, encodes: calls.encodes.map((call) => [call.mimeType, call.quality]) };
    };

    await expect(convert(webpLossy(3000, 2000))).resolves.toEqual({
      result: expect.objectContaining({ kind: 'converted', width: 2000, height: 1333, file: expect.objectContaining({ name: 'photo.jpg', type: 'image/jpeg' }) }),
      encodes: [['image/jpeg', 0.9]],
    });
    await expect(convert(webpLossless(3000, 2000))).resolves.toMatchObject({
      result: { file: { name: 'photo.png', type: 'image/png' } },
      encodes: [['image/png', undefined]],
    });
    await expect(convert(webpExtended(3000, 2000, VP8X_ALPHA, alph, vp8(3000, 2000)))).resolves.toMatchObject({
      encodes: [['image/png', undefined]],
    });
  });

  it('keeps graphics as PNG when the PNG fits', async () => {
    const { backend } = fakeBackend({ width: 1500, height: 1000 });

    const result = await convertImageFile(source('scan.bmp'), convertPlan('bmp', null, null, ['format']), { backend, limits });

    expect(result).toMatchObject({ kind: 'converted', width: 1500, height: 1000, file: { name: 'scan.png', type: 'image/png' } });
  });

  it('falls back to JPEG at the same size when an opaque PNG is too large', async () => {
    const { backend, calls } = fakeBackend({
      width: 1900,
      height: 1900,
      encodedSize: (mimeType) => (mimeType === 'image/png' ? 5_000 : 800),
    });

    const result = await convertImageFile(source('noise.png'), convertPlan('png', 1900, 1900, ['bytes']), { backend, limits });

    expect(result).toMatchObject({ kind: 'converted', width: 1900, height: 1900, file: { name: 'noise.jpg', type: 'image/jpeg' } });
    expect(calls.encodes.map((call) => call.mimeType)).toEqual(['image/png', 'image/jpeg']);
    expect(calls.renders).toEqual([[1900, 1900]]);
  });

  it('shrinks a transparent PNG until it fits instead of dropping the alpha channel', async () => {
    const { backend, calls } = fakeBackend({
      width: 3000,
      height: 2000,
      transparent: true,
      encodedSize: (_mimeType, width, height) => Math.round((width * height) / 1_000),
    });

    const result = await convertImageFile(source('logo.png'), convertPlan('png', 3000, 2000, ['dimensions']), { backend, limits });

    expect(result).toMatchObject({ kind: 'converted', file: { type: 'image/png' } });
    expect(calls.encodes.every((call) => call.mimeType === 'image/png')).toBe(true);
    expect(calls.renders[0]).toEqual([2000, 1333]);
    expect(calls.renders.length).toBeGreaterThan(1);
    const [width, height] = calls.renders.at(-1)!;
    expect((width * height) / 1_000).toBeLessThanOrEqual(limits.maxBytes);
    expect(calls.released).toBe(calls.renders.length);
  });

  it('names the file after the type the browser actually produced', async () => {
    const { backend } = fakeBackend({ width: 4000, height: 3000, blobType: () => 'image/png' });

    const result = await convertImageFile(source('photo.jpeg'), convertPlan('jpeg', 4000, 3000, ['dimensions']), { backend, limits });

    expect(result).toMatchObject({ kind: 'converted', file: { name: 'photo.png', type: 'image/png' } });
  });

  it('keeps the original when only the dimensions were unknown and the decoded image fits', async () => {
    const { backend, calls } = fakeBackend({ width: 1200, height: 900 });

    const result = await convertImageFile(source('odd.jpg'), convertPlan('jpeg', null, null, ['unknown-dimensions']), { backend, limits });

    expect(result).toEqual({ kind: 'unchanged', width: 1200, height: 900 });
    expect(calls.renders).toEqual([]);
    expect(calls.closed).toBe(1);
  });

  it('reports images the browser cannot decode', async () => {
    const { backend } = fakeBackend({ width: 1, height: 1, failDecode: true });

    const result = await convertImageFile(source('photo.heic'), convertPlan('heic', null, null, ['format']), { backend, limits });

    expect(result).toMatchObject({ kind: 'failed', reason: 'decode', error: expect.any(DOMException) });
    await expect(
      convertImageFile(source('photo.heic'), convertPlan('heic', null, null, ['format']), { backend: null, limits })
    ).resolves.toEqual({ kind: 'failed', reason: 'decode' });
  });

  it('gives up after a bounded number of attempts and releases every canvas', async () => {
    const { backend, calls } = fakeBackend({ width: 3000, height: 3000, transparent: true, encodedSize: () => 1_000_000 });

    const result = await convertImageFile(source('huge.png'), convertPlan('png', 3000, 3000, ['dimensions']), { backend, limits });

    expect(result).toEqual({ kind: 'failed', reason: 'encode' });
    expect(calls.renders).toHaveLength(6);
    expect(calls.released).toBe(6);
    expect(calls.closed).toBe(1);
  });

  it('reports encoding errors', async () => {
    const { backend } = fakeBackend({ width: 3000, height: 3000 });
    backend.render = () => {
      throw new Error('Canvas 2D context is unavailable.');
    };

    const result = await convertImageFile(source('photo.jpg'), convertPlan('jpeg', 3000, 3000, ['dimensions']), { backend, limits });

    expect(result).toMatchObject({ kind: 'failed', reason: 'encode', error: expect.any(Error) });
  });
});

describe('enqueueImageConversion', () => {
  it('runs conversions one at a time and survives failures', async () => {
    const events: string[] = [];
    let releaseFirst!: () => void;

    const first = enqueueImageConversion(async () => {
      events.push('first:start');
      await new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
      events.push('first:end');
      throw new Error('first failed');
    });
    const second = enqueueImageConversion(async () => {
      events.push('second:start');
      return 'second';
    });

    await vi.waitFor(() => expect(events).toEqual(['first:start']));
    releaseFirst();

    await expect(first).rejects.toThrow('first failed');
    await expect(second).resolves.toBe('second');
    expect(events).toEqual(['first:start', 'first:end', 'second:start']);
  });
});
