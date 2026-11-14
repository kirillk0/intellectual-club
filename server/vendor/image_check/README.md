# ImageCheck

A local, standalone Mix package for cheap **structural** validation of JPEG,
PNG, GIF and WebP payloads. Elixir 1.19+; tested on Elixir 1.20 / OTP 29. No
Hex dependencies, NIFs, external executables or application processes. PNG
inflation uses OTP's native `:zlib`.

Pixels are never decoded. The goal is to reject payloads that common decoders
(and therefore LLM provider image endpoints) refuse, while accepting damage
they tolerate, at a small fraction of the cost of decoding.

## API

```elixir
ImageCheck.header(bytes)
# {:ok, %{format: :png, mime_type: "image/png", width: 640, height: 480}}

ImageCheck.validate(bytes, max_pixels: 100_000_000)
# {:ok, %{format: :jpeg, mime_type: "image/jpeg", width: 4000, height: 3000}}
# {:error, {:jpeg, :invalid_huffman_table}}
# {:error, {:unsupported_format, :heic}}
# {:error, :unknown_format}
# {:error, :too_many_pixels}

ImageCheck.format(bytes)   # {:ok, :webp} | {:error, ...}, magic bytes only
```

`header/1` reads the dimensions from the headers only. `validate/2` performs
the full check below; `:max_pixels` (default 100 million, or `:infinity`) is
applied to the declared size before any image data is processed. Both report
the size decoders produce, except that for GIF `header/1` reads the logical
screen only, while `validate/2` reports the union of the screen and all frame
rectangles (see below).

Error reasons are atoms or `{format, atom}` tuples. They never contain input
bytes, numbers or names, and no atoms are created from input. Neither function
raises for binary input; memory stays bounded and time is linear in the input
(for PNG, in the declared image size, which `:max_pixels` bounds).

## Rules

- **JPEG**: SOI; every header segment length is at least 2 and inside the
  payload; exactly one SOF0/SOF1/SOF2 frame (other processes are unsupported)
  with 8-bit precision, nonzero dimensions up to 65500, 1, 3 or 4 components,
  sampling factors 1..4 with integral ratios; DQT/DHT/DRI/SOS are syntactically
  valid; Huffman tables fit the canonical code space (the libjpeg
  "Bogus Huffman table" check, including the reserved all-ones code) and DC
  symbols are at most 15; every scan references frame components, defined
  quantization and Huffman tables, at most 10 blocks per MCU and, for
  progressive frames, valid spectral/approximation parameters. At least one
  complete SOS header is required. Entropy-coded data is skipped, never
  decoded; truncation after the first scan header, a missing EOI and trailing
  bytes are accepted. Sequential frames stop being checked once every component
  has been scanned; progressive frames are walked scan by scan.
- **PNG**: signature; IHDR first with valid depth/color combination,
  compression 0, filter 0, interlace 0 or 1; critical chunk CRCs (ancillary CRCs
  are ignored); unknown critical chunks are rejected; PLTE (required for color
  type 3) has 1..256 entries before IDAT; IDAT chunks are consecutive; IEND is
  required and trailing bytes after it are ignored. The zlib stream is inflated
  incrementally (bounded output per step, never buffered) and must end with
  exactly the bytes the (Adam7) layout requires and a valid filter type at the
  start of every row. The Adler-32 trailer is ignored.
- **GIF**: GIF87a/GIF89a; nonzero screen size; color tables, extensions, image
  descriptors and data sub-blocks are walked up to the trailer; at least one
  frame with a nonzero size, LZW minimum code size 2..8 and data. Frames may
  extend past the logical screen: like Pillow, the reported size is the union
  of the screen and every frame rectangle, and `:max_pixels` applies to it (and
  thereby to every frame) at each image descriptor. The first sub-block of a
  graphic control extension, when not empty, holds at least the delay (3 bytes)
  and, with the transparency flag, the transparent index (4 bytes); Pillow
  fails on shorter ones. LZW data is not decoded; truncation is an error.
- **WebP**: modelled on libwebp's `WebPGetFeatures` and demuxer, which
  `WebPAnimDecoder` (and so Pillow) applies to every file. RIFF/WEBP with a
  RIFF size that fits the payload; all chunks inside it. A frame is at most one
  ALPH and one VP8 or VP8L chunk, adjacent; ALPH never goes with VP8L. VP8:
  key frame, profile, visible frame, start code, nonzero size, and a nonempty
  first partition that ends after the 10-byte frame header with at least one
  byte left for the token partitions. VP8L: signature, version and at least
  the 3 bytes of the shortest image stream after the 5-byte header. The pad
  byte of an odd-sized VP8/VP8L chunk counts, as libwebp decodes it. Simple
  files start with a frame. Extended files start with a 10-byte VP8X chunk
  without reserved flags; a still one holds one frame matching the canvas, an
  animated one ANIM before the first ANMF and ANMF frames inside the canvas
  whose bitstreams match their size. Other ALPH, VP8, VP8L or VP8X chunks are
  errors. ALPH is checked where libwebp decodes it (ANMF frames, and still
  frames with the VP8X alpha flag): it precedes the VP8 chunk, has zero
  reserved bits, compression 0 or 1, pre-processing 0 or 1, and either at
  least width × height raw bytes or a 3-byte lossless stream.
- BMP, TIFF, AVIF, HEIC, JPEG XL and ICO are recognized and reported as
  unsupported.

## Tests

```sh
mix test
```

The fixtures in `test/fixtures` are produced by `test/fixtures/generate.py`
with Pillow and pypng; damaged variants are generated by the tests.
