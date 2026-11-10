# PdfText

A local, standalone Mix package for bounded PDF **text-layer** extraction.
Elixir 1.19+; tested on Elixir 1.20 / OTP 29. No Hex dependencies, PDF NIF,
external executable, application process, global application configuration,
network access, image decoding or OCR. Flate uses OTP's native `:zlib`.

## API

```elixir
PdfText.extract(pdf_bytes,
  max_chars: 500_000,
  timeout_ms: 45_000,
  max_input_bytes: 50 * 1024 * 1024,
  max_output_bytes: 2 * 1024 * 1024
)
# {:ok, %{
#   text: "...", page_count: 12, pages_extracted: 12, version: "0.1.0",
#   partial: false, truncated: false, warnings: []
# }}
# {:error, :no_text | :encrypted_pdf | :invalid_pdf | ...}
```

`text` is detached UTF-8, including existing invisible/OCR text layers.
`version` is the package/extractor version, not the input PDF version.
`page_count` is the counted page-tree leaves, not an untrusted `/Count` value.
`pages_extracted` counts pages whose content traversal finished, including
empty pages and pages with skipped unsupported fonts. A partially visited page
can contribute text without incrementing this count.

A nonempty result with skipped content has `partial: true`. Output exhaustion
or any global resource limit also sets `truncated: true` and stops the whole
extraction. Text obtained before the stop is retained, including a prefix of
the current page. Warnings are at most 32 deduplicated small maps, e.g.
`%{reason: :unsupported_font}` or `%{reason: :limit, limit: :decoded_bytes}`.
No input-derived names, source bytes, exception messages or paths are exposed.

No extractable text returns `{:error, :no_text}`, including when every text
font/page was unsupported. A global resource limit before any output returns
`{:error, {:limit_exceeded, budget}}`. Other errors are stable atoms such as
`:invalid_options`, `:invalid_input`, `:input_too_large`, `:missing_xref`,
`:xref_cycle`, `:page_cycle` or `:encrypted_pdf`; malformed structures can also
return `:invalid_pdf`. Error atoms are diagnostics, not a recovery protocol.
All encryption is rejected, including empty-password encrypted documents.

The implementation is synchronous. It neither spawns workers nor changes
process flags. Its single private process-dictionary context is restored in
`after`, even if a caller already had a value at that key. No state survives a
call, and calls in different processes are independent.

## Supported subset

- Classic xref tables, xref streams, object streams, hybrid references and
  incremental `/Prev` revisions. Newer free entries mask older live entries.
  Sparse object IDs do not allocate ID-sized arrays. Cycles and revision depth
  are bounded. Nonstandard generation zero on a free object zero is tolerated.
- Lazy indirect-object resolution, bounded caches and page-local content
  decoding; the page tree and xref index are read before content extraction.
  Resource dictionaries inherit through the page tree.
- Exact direct/indirect stream lengths, Flate and ASCII85 filter chains, PNG
  predictors 10–15. Each Flate drain is bounded, charged before accumulation,
  and validated by `inflateEnd`; the handle is always closed in `after`.
- Simple fonts with ToUnicode, Standard/WinAnsi/MacRoman and donor-provided
  additional encodings, Differences and Adobe glyph names. Only standard-14
  fonts get an implicit encoding fallback. Unknown embedded encodings are not
  guessed. Horizontal Type0 Identity-H requires ToUnicode.
- ToUnicode `bfchar`, both forms of `bfrange`, multi-character UTF-16BE and
  surrogate pairs. Ranges remain compact; disjoint ranges use binary search,
  overlapping ranges use budgeted precedence-preserving lookup.
- Text matrices, widths/CID widths, `TJ` positioning, character/word spacing,
  rise, leading, `q/Q`, `cm`, ExtGState fonts and bounded Form XObjects with
  local resources and matrices. Invisible text is retained. Image XObjects
  are skipped without decoding image streams or executing glyph programs.

## Limits and memory model

Top-level options must be positive integers. Hard ceilings are 2,000,000
characters, 120,000 ms, 100 MiB input and 8 MiB output. Unknown options and
invalid values are rejected. `limits: [budget: smaller_positive_integer]`
can **only lower** the following defaults; values never come from the PDF or
application environment:

| Budget | Default |
| --- | ---: |
| `tokens` | 2,000,000 |
| `objects` (uncached resolutions) | 100,000 |
| `xref_entries` (all sections/revisions combined) | 250,000 |
| `revisions` | 64 |
| `depth` | 64 |
| `token_bytes` | 65,536 |
| `collection` (one array/dictionary/header) | 20,000 |
| `stream_bytes` (one decoded filter stage) | 8 MiB |
| `decoded_bytes` (all decoding, including repeated work/predictors) | 64 MiB |
| `operations` | 1,000,000 |
| `pages` / `page_nodes` | 10,000 / 100,000 |
| `forms` / `form_depth` | 10,000 / 24 |
| `glyphs` | 2,000,000 |
| `cmap_entries` / `cmap_work` | 100,000 / 2,000,000 |
| `cmap_bytes` | 1 MiB |
| `cache_entries` / `cache_bytes` | 128 / 4 MiB |
| `predictor_row` | 65,536 bytes |

Counters and the deadline are document-wide, not reset between pages or
Forms. Resolver/object-stream cache entries are bounded by external-term size
and count, cleared between pages and evicted wholesale when full. A separate
font cache has the same byte ceiling and at most `min(64, cache_entries)`
entries. It retains only compiled mappings/metrics, not decoded content streams.
Oversized entries are not cached. The current object, stream, active Form stack,
xref/page index, input binary and output remain live independently of caches.
Text strings are mapped in batches of at most 128 glyphs; glyph-name length and
ToUnicode destination length are separately capped. Output is checked in both
Unicode codepoints (not graphemes) and UTF-8 bytes, never split mid-codepoint.
Trailing/leading whitespace is trimmed, so final length can be below the cap.

**These are cooperative work/allocation bounds, not a hard RSS sandbox.**
The caller must supply concurrency/admission control, a monitored worker with
an appropriate `max_heap_size` (including shared binaries), and a watchdog.
The package does not own that policy. OTP zlib and the BEAM runtime still use
native code. Hard memory isolation requires a separate OS process/container.
Deadline checks cannot interrupt an individual OTP primitive or GC operation.
No security certification or adversarial-runtime guarantee is claimed.

## Deliberate gaps in this first iteration

- No encryption, OCR, font-program fallback, predefined/vertical CJK CMaps,
  `usecmap`, custom Type0 encoding CMaps, LZW, TIFF predictor or damaged-xref
  repair. The bootstrap xref stream must have a **direct** `/Length`; indirect
  lengths work once its xref is available. Indirect filter parameter dictionaries
  and unusual indirect resource attributes can be rejected rather than guessed.
- Inline images stop the current page with a warning; the parser does not scan
  naively for `EI`. A safely extracted prefix can remain in a partial result.
- No ActualText/structure-tree recovery, annotation appearances, Type3 glyph
  rendering, clipping/occlusion evaluation, page rotation normalization or
  semantic table/multicolumn reconstruction. Text is emitted in painting order
  with geometric line/space heuristics, not sorted into a reading-order model.
  Missing standard-font widths use approximate advances.
- A successful result is not a guarantee of semantic completeness. `partial`
  reports detected unsupported/malformed content, not every possible layout or
  font ambiguity. Conservative budgets intentionally truncate some long or
  path-heavy documents well before the default character cap.

## Development and evidence

```sh
cd server/vendor/pdf_text
mix test
mix precommit
```

Tests generate their own tiny PDFs; no database, app, private corpus or oracle
binary is needed. They cover xref/ObjStm/hybrid/incremental references, cycles,
Unicode/encodings, geometry, Forms, invisible text, bounded decompression,
malformed predictors, partial/early-stop semantics, option validation, state
restoration, atom safety and deterministic malformed-input mutations.

An implementation-time run used all 106 SHA-deduplicated local technical PDFs,
each in a fresh OS process. The `pdftotext -layout` oracle was used only by the
local benchmark, not the package. All calls returned tuples without OS-process
crashes or external timeouts. Outcomes: 45 complete, 24 partial without truncation, 27 budget-truncated,
2 no-text, 3 token-budget errors before output and 5 encrypted rejections.
The largest per-process peak RSS reported by macOS `time -l` was 174.77 MiB;
the slowest API call was 9.014 seconds. These include a separate VM per file,
not a hard memory limit or an admission/concurrency test. Do not interpret
`ok` as full-document recall.
Representative nontruncated token recall was 100% for the Russian W-VIP and
VIP REST manuals, ~99.9% for CAN BASICS and ~99.85% for the ICA integration guide.
These token-multiset measurements do not assess reading order or tables.
Private input/text artifacts are not part of this package and were not uploaded.

See `THIRD_PARTY_NOTICES.md` for the small encoding/glyph-table subset reused
under MIT and Adobe licenses. The reader, budgets, codecs and extraction pipeline
are new code; no donor HTML/writer/renderer application was imported.
