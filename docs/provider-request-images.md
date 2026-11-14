# Provider-owned request images

Provider packages implement `map_request_images(request, acc, mapper)` from
`Common.ProviderType`. The common image service receives this function, never a
provider name used to infer a payload shape. Provider labels are diagnostic only.

The provider calls the arity-two mapper for each supported compact image block:

```elixir
%{
  marker: inner_file_marker,
  encoding: "data_url", # or "base64"
  mime_type: native_mime,
  format_key: :data_url, # or :base64, or a module-owned stable format key
  format: fn base64, mime -> "data:#{mime};base64," <> base64 end
}
```

`marker` is the map inside `$intellectual_club_file`. Responses and Chat
Completions expose the marker's `mime_type`; Anthropic exposes
`source.media_type`, and Google exposes the block's `mime_type`. Native MIME is
not silently replaced with the marker value. The formatter receives **already
base64-encoded** bytes. Equal format keys must mean equal wire formatting, even
across providers sharing one cache.

The mapper returns `{change, next_acc}`. Providers implement every change:

- `:keep`: retain the original block.
- `{:marker, inner_marker, corrected_mime}`: update the native marker location and
  MIME fields, retaining unrelated native metadata.
- `{:wire, wire_binary, mime}`: replace the marker with the formatted wire value.
- `{:omit, text}`: replace the image with native text. Anthropic preserves
  map-valued `cache_control` on this replacement.

## Traversal boundaries

Each package owns its root and container rules. Responses/WSS use `input`,
Anthropic and Chat Completions use `messages`, and Google uses `input`, including
list-valued `function_result.result`. Tool result content lists are supported.
Only native image blocks whose image value contains a map-valued file marker are
mapped. Legacy inline strings/URLs are unchanged. Metadata, tool schemas,
arguments, map-valued tool results, and unrelated JSON are opaque.

`Common.ImageTraversal` only follows the roots and child keys supplied by the
package. It has no provider dispatch or image-shape patterns. ResponsesWss
explicitly delegates to Responses. OpenRouter and NVIDIA explicitly delegate to
`Common.ChatCompletions.ImageMapper`, the shared Chat Completions wire format.
Demo and MissingProvider are no-ops. The test-only `ImageMapperDummy`
(`server/test/support/llm_tools/image_mapper_dummy.ex`) demonstrates a new
packet/picture shape and custom formatter without modifying shared code.

## Hydration and transport

`Common.RequestHydration.hydrate(request, step_id, mapper, opts \\ [])` passes
`mapper`, `cache`, `on_cache`, `on_sent`, `llm_configuration_id` and diagnostic
`provider` to the neutral image service. Stream options are named `image_cache`,
`image_cache_update`, `image_sent_update` and `image_llm_configuration_id`; every
provider/transport wrapper forwards them. Generic Chat Completions also requires
`image_mapper` from its package; provider-specific direct API entry points have
their own mapper defaults.

After a successful hydration, before the request is transmitted, `on_sent`
receives the images the wire request sends natively (possibly none):
`%{sha256:, file_id:, source_file_external_id:, accepted?:}` per payload, where
`accepted?` says whether the current configuration accepted that content
before. Images replaced by text are not in the list. Responses WSS and its HTTP
fallback each report what they hydrated.

Responses WSS computes its continuation delta **before** hydration. HTTP fallback
uses the original logical request and the cache returned by the failed WSS attempt,
including entries retained from before the continuation delta. The normal Worker
cache callback is preserved; fallback does not wait for the Worker to handle it.
Wire hydration never changes the logical request returned in transport events.

## Final preparation

Builders and steering construct logical requests and independent snapshots; they
no longer call `prepare_request`. `Common.PreparedRequest.prepare/3` normalizes
JSON keys and atom values (except `nil`, `true`, and `false`) once and calls a
provider callback accepting string-keyed data. It rejects key collisions before
image traversal; full value validation and canonical encoding belong to the
step resource boundary. Direct
callback callers must normalize their input or use the wrapper. The generation
persistence boundary owns the single final preparation and must refresh the
request snapshot afterwards (notably NVIDIA cache-control removal).

Defensive normalization remains in follow-up/steering inputs, standalone
`request_snapshot/1`, tool/history projection, standard-parameter processing, and
WSS envelope/continuation comparison. Those separate public input paths were not
globally changed by the final-preparation deduplication.


## Image validation, verdicts and limits

The server never decodes, resizes or re-encodes request images; there is no
libvips dependency. Large images are downscaled before they reach the server
(browser upload compression, outlet `read_image`). Anything the server does not
send natively becomes provider-native text through `{:omit, text}`.

**Structural check.** `ImageProcessor.validate/1` calls the vendored,
dependency-free `ImageCheck` package (`server/vendor/image_check`, see its
README). It accepts JPEG (SOF0/1/2), PNG, GIF and WebP and checks container and
codec headers without decoding pixels: JPEG segments, Huffman code spaces and
scan headers (entropy data is skipped, so truncated or junk-filled scans and a
missing EOI pass, as they do at the providers); PNG critical chunk CRCs, chunk
order, IEND and a bounded, streamed inflate that must produce exactly the
expected rows with valid filter bytes (Adler-32 is ignored); GIF block structure
to the trailer, graphic control blocks long enough for Pillow, and an image size
that, as in Pillow, is the union of the logical screen and all frame rectangles;
WebP following libwebp's `WebPGetFeatures` and demuxer (which Pillow applies to
every file): RIFF bounds, a 10-byte VP8X without reserved flags, exactly one
ALPH/VP8/VP8L frame per still image or ANMF, ALPH only before VP8 and with a
valid header and length where libwebp decodes it, ANIM before the first ANMF,
frames inside the canvas, and VP8/VP8L headers including the bounds of the first
partition. BMP, TIFF, AVIF,
HEIC, JPEG XL and ICO are rejected. The rules were derived from sending 43
damaged images to OpenAI, Google and Anthropic: they may be stricter than the
providers, never more lenient. Check version 2 added rules derived from Pillow
11.3 and libwebp 1.5 rather than from provider responses: GIF frame rectangles
and graphic control blocks, and the WebP demuxer rules above. MIME types always
come from the content; the declared MIME of a file is corrected on its request
pin.

**Verdicts.** The result is remembered per payload SHA-256 in the
`image_verdicts` table (`Files.ImageVerdict`, accessed through
`Files.ImageVerdicts`): `status` (`valid`/`invalid`), content MIME type,
dimensions, a short `reason`, and the `check_version` of the rules
(`ImageProcessor.check_version/0`, bumped whenever the rules change; older
verdicts are recomputed on the next cold load). Every cold payload load still
verifies the stored size and SHA-256 before a verdict is trusted or recorded.
Preparation and hydration load the verdicts of all step bindings with one query
and memoize further lookups; a hit in the Worker's wire cache skips the payload
load but not the verdict lookup.

**Provider facts.** Whether a provider accepted or rejected an image is not a
property of the bytes: providers have different decoders and size limits, and
one OpenRouter configuration may route models to different upstreams. Such facts
are kept per payload SHA-256 **and LLM configuration** in the
`image_provider_verdicts` table (`Files.ImageProviderVerdict`, accessed through
`Files.ImageProviderVerdicts`): `status` (`accepted`/`rejected`) and short
`details` (for a rejection `"<provider_type>: <short error>"`). The foreign key
to `llm_configurations` deletes the facts together with their configuration.
`mark_rejected(sha256s, configuration_id, details)` upserts rejections and
overwrites earlier facts; `record_accepted(sha256s, configuration_id)` only
inserts missing facts and never undoes a rejection. Both write one statement.

Preparation and hydration receive the generation's `llm_configuration_id` and
replace only images **rejected by that configuration** with text — including
inherited pins and warm cache entries; another configuration still receives the
same image. Each loads the facts with at most one query: hydration for all step
bindings before traversal, checking them before the cache and the payload;
preparation for all staged images after traversal (new images are only
identified while traversing), then replaces rejected ones in a second in-memory
pass and discards their staged files. Without a configuration (demo) there are
no facts and nothing is replaced. The Worker records the facts; see *Reaction to
provider image rejections*.

To undo a wrong blame, remove facts from the console with
`ImageProviderVerdicts.forget(sha256s, llm_configuration_id: id)` (the option is
optional; `sha256s` may be `:all`, e.g. with the option after the model of a
configuration was changed). It returns the number of removed facts.

**Limits.** New images (canonical files and pins reused from other steps) must
have a longest edge of at most 2000 px (Anthropic rejects larger images in
requests with more than 20 images) and at most 7,864,320 bytes, so that their
base64 fits Anthropic's 10 MiB image limit. Limits are checked on the headers
before validation and again on the validated size, which for GIF includes frames
that extend past the logical screen (the header reports the screen only). Exact
pins inherited from the source step keep their bytes:
the byte limit is not re-applied, so older conversations keep their images.
Inherited pins above 2000 px (exact bytes pinned by the former raw request
backfill) become the "exceeds the image input limits" text instead of failing.

**Text replacements.** Omitted images become, for example:

```
[Image omitted: "photo.png" (file_id=<uuid>, 3000x2000 px, 9.1 MB) exceeds the image input limits of 2000 px per side and 7.5 MB. The file remains available to file tools.]
```

with "could not be validated as an image" for invalid content and "was rejected
by the model provider" for content rejected by the current configuration. `file_id` is the source file's
external id. Files that are not available in the current scope keep the generic
"[Image omitted: attached file could not be validated as an image.]".

**Fail-closed cases.** Missing inherited pins, payload integrity mismatches,
source/MIME mismatches and unsupported variants fail preparation, hydration and
snapshot validation as before; canonical bytes never substitute for a pin. Only
an invalid verdict, a rejection by the current configuration or the edge limit
turns a pin into text, in `prepare` (so a retry step prepared from a failed one
already contains the text) and in `hydrate`. Snapshot validation has no
configuration and accepts rejected pins. Unusable reuse candidates fall back to
the canonical file.

**Pin variants.** New pins are always `identity:v1`. Downscaled
`thumbnail:max-edge=2000:preserve-format:v1` pins created by earlier releases are
still validated, hydrated, inherited, reused and copied. So are `legacy_exact:v1`
pins of the former raw request backfill (exact bytes, up to ~16 MB) and its
markers with the `{"kind": "legacy_exact", "format": "preserve"}` rendition;
above the limits they become text like any other image.

**Provenance of pins.** The private `image_state` returned by preparation (the
Worker's `request_images`) contains `images`: for each staged reference key
`%{sha256: ..., origin: :inherited | :reused | :new}`. `:inherited` pins come
from the source step; `:reused` pins of other steps in scope and `:new`
canonical files were added by this step (the first step of a new generation has
no source step, so images of the chat history are `:reused`). This records
provenance only: what an attempt actually sent comes from hydration.

## Reaction to provider image rejections

A provider may still refuse an image the structural check accepted. The Worker
reacts in `handle_provider_error`, after the transient auto-retry
(429/5xx/network) and before finalizing the error, for errors from
`:response_error` events and from errors inside a completed `raw_response`.

**Predicate.** `RequestImages.ProviderRejection.image_rejection?/1` is one
provider-independent rule over the error metadata. It requires an
invalid-request status — HTTP 400, or no status on an `error_kind: "provider"`
error whose body has an `invalid_request`/`invalid_request_error` type or code
(the ChatGPT backend reports in-stream without a status) — **and** an error text
(`error_text`, `message`/`raw` values of `raw_response`) about processing, the
format or the size of an image. Recognized texts include:

- ChatGPT backend: `input_image image_url could not parse image: …`,
  `input_image image_url unsupported image format: unknown`;
- OpenAI API: `The image data you provided does not represent a valid image.`;
- Google: `Unable to process input image. Please retry …`;
- Anthropic (direct or via OpenRouter `metadata.raw`): `Could not process image`,
  `…image.source.base64.media_type: Input should be 'image/jpeg', …`,
  `…media type, but the image appears to be a image/png image`,
  `…image exceeds 10 MB maximum: …`.

The patterns name a problem with one image, so that unrelated 400s do not blame
images. Texts saying that the model does not accept images at all
(`does not support image input`, `image input is not supported`,
`No endpoints found that support image input`) and context-length errors never
match, nor does any other status (401/403/404/429/5xx).

**Suspects.** Only images the failed attempt actually sent. The Worker keeps the
`on_sent` reports of the running attempt, bound to its stream reference and
step; reports and errors of other attempts never mix. Let `S` be these images
and `S'` those the current configuration has not accepted before. The Worker
blames `S'`: images that already passed this configuration are trusted, so a
new broken image does not take the chat history down with it. If `S'` is empty
while `S` is not, the evidence contradicts the error; the Worker blames all of
`S` so that the generation can still succeed, and logs a warning with
`fallback=true`. An empty `S` (nothing sent natively, for example after
hydration replaced the only image with text) and a generation without an LLM
configuration are not retried. The Worker always hydrates its own requests
before sending, also after recovery, so it never reconstructs `S` from pins.
Images in one new message that are sent together for the first time are all in
`S'`, so a valid image next to a broken one is blamed as well — for this
configuration only.

**One retry.** The Worker records the suspects as rejected by the current
configuration and retries through the regular
`persist_retry_error_and_start_next_step` path: the error stays on the failed
step (`retry_reason: "image_rejected"` in its retry metadata, text "The provider
rejected an image on attempt N. …"), the next step is prepared from the failed
one and therefore carries text instead of the rejected images, and it starts
without backoff (`{:backoff, 0}`, so steering, cancellation and lease loss behave
as for other retries). The retry counts as an attempt. It happens at most once
per run of the generation (`image_rejection_retried?`). A manual retry by the
user (`Supervisor.retry_last_step/2`, `retry_from_step/3`) is a new run of the
message and gets a fresh retry: the supervisor marks its context
(`manual_retry?`), so an image rejected after an earlier image-rejection retry
does not fail every manual retry of the message. Any other Worker start on a
later step continues an interrupted run (recovery, including the restart of the
unfinished step, subagent and fork resumption) and restores the flag from all
earlier steps of the message, whatever transient retries followed: any retry
error with `retry_reason: "image_rejected"` sets it
(`Persistence.image_rejection_retried_before_step?/2`, one query). In both cases
the attempt counter continues from the predecessor. A repeated rejection, an
attempt without sent images, or a failure to record (database error) ends the
generation with the original provider error.

**Acceptance.** When an attempt that sent images completes — the provider
returned a full response without an error and the step was persisted as done or
waiting for tools — the Worker records the images of `S` that were not yet
accepted as accepted by the configuration, in the same persistence operation
right after the step commit (one insert of the missing facts). In steady state
hydration already reports them as accepted and nothing is written. Failures to
record are logged and do not affect the generation.

## Worker cache and publication

The Worker retains the compact logical request, its image descriptors, and a
private content-addressed cache of **final formatted wire binaries**. Its key is
`{prepared_file.sha256, mime_type, format_key}`, not the source file UUID. Entries
contain checked dimensions, MIME and byte size, but no raw image payload, source
ownership, step binding or authorization capability. Large BEAM binaries can be
shared by reference with the sending task; there is no global cache and no cache
serialization into requests, storage, public snapshots or tracing metadata.

The retained previous logical request and descriptors avoid reconstructing its
patch chain during normal follow-up preparation. This does not bypass source
scope validation or step-local binding checks. Every prepared step receives its
own independently pinned logical files. An in-memory hit can reuse verified
image metadata and wire bytes without another file read, hash, validation or
base64 encoding. Only referenced cache keys are retained when the prepared step
is installed; cache updates from a send are accepted only for the current stream
reference and step, while its lease is valid. Retry and steering use the same
rules. Manual retry transfers its prepared image state into the replacement
Worker instead of immediately throwing the cache away.

Byte integrity is checked on cold loading or preparation, not on every use of a
verified in-memory entry. A disk file corrupted after an entry was cached does
not invalidate the already verified bytes in memory; after recovery or eviction,
the next cold load detects that corruption. A cache hit still requires a valid
binding and matching persisted file metadata, and never bypasses an invalid
verdict or a rejection by the current configuration. Missing inherited pins fail
closed.
Cold recovery reconstructs the compact request and repopulates the cache on use.

`RequestImages.hydrate_with_cache/3` returns `{:ok, wire_request, cache, sent_images}`
explicitly; `hydrate/3` wraps it with the optional `on_cache` and `on_sent`
callbacks. Providers never mutate the
logical request to install wire bytes. Image service telemetry contains only
hit/miss and loaded/encoded byte counters.

## Mapper selection and staging failures

The common image API requires an explicit mapper and returns
`:image_mapper_required` when it is missing. Generation resolves it from the
adapter (including explicit no-op adapters). When an inherited request has a
different format, callers can supply its `source_mapper` separately. The
read-only historical-copy validator uses registered provider mappers to inspect
stored references even when the original provider configuration no longer
exists; normal generation never guesses a provider from payload shape.

Image preparation stages independent logical files before immutable publication.
A short-lived private staging journal also records files when a provider mapper
or formatter raises or throws before returning its accumulator. Those files are
removed on failure. On success, `PreparedRequests` owns the staged handle until
bindings are attached and persistence succeeds, or cleanup follows rollback.
Expensive image processing is not wrapped in a new database transaction.
