# PDF text extraction

## Package boundary

`server/vendor/pdf_text` is an independent local Mix package. It has no Phoenix,
Ash, database, external PDF executable, or third-party native dependency.
The server depends on it through `{:pdf_text, path: "vendor/pdf_text"}`.
`Tools.DocumentReader` is the adapter shared by Artifact Reader and Web Reader.
There is no fallback to `pdf_elixide`, PDFium, or another PDF NIF.

`PdfText.extract/2` is synchronous: it runs in its caller and maintains a bounded,
per-call parsing context. It restores any previous context on return. The package
README describes supported syntax and its standalone API. Sources and notices
for reused encoding data are kept inside the package. Complete distribution
notices are also in `priv/LICENSES.txt`, which Mix includes in desktop and Docker
releases even though source comments are not retained in compiled BEAM files.

## Supported scope

The extractor reads embedded text, not rendered pixels. It supports classic
cross references, xref/object streams, bounded revision chains, page resources,
Flate and ASCII filters, ordinary font encodings and ToUnicode mappings,
text positioning, and nested Form XObjects. Existing invisible OCR text layers
are read; images are not OCRed. Text runs are joined using positions and font
advances rather than adding a space between every PDF string.

Encrypted PDFs, including files that open without a password in a viewer, are
rejected. Unsupported fonts or page constructs may produce partial text with
warnings. Inline images and uncommon encoding features are not a promise of
full compatibility. Reading order and table relationships remain approximate.
The parser does not execute JavaScript, actions, font programs, or image codecs.

## Admission and cancellation

`Tools.DocumentWorker` owns document loading, extraction, and cache writes:

- One active operation per BEAM node; at most 16 pending callbacks.
- Excess requests get a busy error. Pending sources have not been loaded yet.
- Artifact Reader resolves an authorized path through `ContentFiles` before
  admission, then reads bytes inside the worker. Authorization is not bypassed.
- Input is capped at 50 MiB. Web downloads are bounded both before and after
  HTTP decompression, even when the tool configuration permits a larger body.
- The outer deadline covers queueing, loading and writing. Its allowance is the
  extraction timeout plus the HTTP timeout, when applicable, plus five seconds.
  The PDF parser also enforces its own extraction deadline.
- Cancelling the requester kills its active worker or removes its pending job.
  The active slot is not reused until the worker's DOWN notification arrives.
- The worker owns the cache lock. Partial failed writes have no READY marker;
  the next admitted attempt removes stale files before rebuilding.

The worker starts with a 256 MiB `max_heap_size` budget, including shared binaries,
with kill enabled. This is a secondary safeguard, **not a hard RSS ceiling**.
OTP checks the heap limit during garbage collection. Transient copies, allocator
state and native OTP allocations are not fully controlled by this setting.

The parser additionally limits tokens, nesting, objects, reference work,
operations, CMap work, cache retention, decoded bytes, and output. Flate is
expanded in bounded steps through OTP `:zlib.safeInflate`. User-controlled PDF
names never become new atoms. Limits are checked before expanding structures,
not just after opening a document. Ordinary errors are contained in the worker;
unexpected errors are normalized without copying the PDF into exception logs.

Pure Elixir removes the third-party native PDF engine from the application's
address space; it does not provide an OS sandbox. OTP zlib and the BEAM runtime
are still native code. A hard isolation guarantee would require a separately
memory-limited OS process, which is intentionally not part of this version.

## Results and cache

Extraction metadata identifies `pdf_text`, its extractor version, PDF page count,
processed pages, truncation, partial extraction, and bounded warnings. Partial
and truncated results are marked in reader responses. A successful return does
not imply perfect layout reconstruction. Empty/no-text, encrypted, invalid and
resource-limited inputs can return explicit errors.

Old caches tagged `pdf_elixide` or `pdf_oxide_spans` are rebuilt. Cache hits do not
load source bytes or occupy the admission worker. PDF extraction stops at its
output limit rather than processing all pages and filtering afterwards.

## Verification

Run package tests independently:

```sh
cd server/vendor/pdf_text
mix test
```

Full `bin/server-test` and `mix precommit` also run package tests. Addressed server
test runs skip the separate package suite. Docker copies the package before
fetching/compiling dependencies; desktop releases build it from the checkout.

Adversarial tests must use a disposable VM/process, not the running application.
Corpus diagnostics and comparison scripts are local development artifacts under
`assets/pdf-implementation`, not runtime dependencies or distributed user data.

## Initial corpus results

The final prototype was exercised against 106 SHA-deduplicated technical PDFs,
each in a separate OS process. Outcomes: 45 without warnings, 24 partial but not
budget-truncated, 27 stopped with text at a budget, five encrypted, two with no
text, and three reaching a budget before any text. No process crashes or external
timeouts occurred. Maximum observed standalone VM RSS was 174.77 MiB and maximum
API duration was 9.014 seconds. These are measurements of this corpus and runner,
not resource guarantees for arbitrary documents or the full application.

Token-multiset recall versus `pdftotext -layout` was 100% for W-VIP RU, 99.91% for
CAN BASICS and 99.85% for the ICA integration guide. This comparison does not
verify reading order, tables or semantic completeness. `partial: false` means no
supported diagnostic detected a gap, not certified completeness.

The dev macOS release was rebuilt and exercised through `DocumentReader`: a
16-page Russian manual, a cache hit without source loading, encrypted-file
rejection without READY, and a subsequent successful extraction. The release
contains `pdf_text` and its license notices, not `pdf_elixide`. Docker/Windows
integration was updated but those platforms were not built locally.

## Follow-up boundaries

The first version deliberately retains conservative document-wide work budgets.
They can stop a document well before the character cap or timeout, including on
path-heavy pages or repeated font work. Local size limits also stop the document;
continuing past such a limit is not yet implemented. Raising limits solely because
one corpus fits in memory is not part of this safety-first iteration.

Future coverage work includes tolerant page-tree recovery, finer page/font-local
failure handling, inline images, more glyph aliases, CMap fallback and better
standard-font geometry. Unsupported-only documents can currently return `no_text`;
that outcome does not prove the source is an image-only scan. Reader configuration
above the PDF package's character/time ceilings is clamped at the adapter.

Post-review regressions additionally cover ASCII85 and two million one-character
outputs in a 256 MiB capped worker. Accumulators coalesce into bounded blocks;
whitespace-only output no longer masks document-wide budget errors as `no_text`.
The final package suite has 37 tests; the final server precommit passed 1876 tests
(62 excluded), including the HTTP PDF and adapter ceiling regressions.
