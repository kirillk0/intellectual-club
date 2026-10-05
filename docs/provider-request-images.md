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
`mapper`, `cache`, `on_cache`, and diagnostic `provider` to the neutral image
service. Stream options are named `image_cache` and `image_cache_update`; every
provider/transport wrapper forwards them. Generic Chat Completions also requires
`image_mapper` from its package; provider-specific direct API entry points have
their own mapper defaults.

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
image metadata and wire bytes without another file read, hash, decode, resize or
base64 encoding. Only referenced cache keys are retained when the prepared step
is installed; cache updates from a send are accepted only for the current stream
reference and step, while its lease is valid. Retry and steering use the same
rules. Manual retry transfers its prepared image state into the replacement
Worker instead of immediately throwing the cache away.

Byte integrity is checked on cold loading or preparation, not on every use of a
verified in-memory entry. A disk file corrupted after an entry was cached does
not invalidate the already verified bytes in memory; after recovery or eviction,
the next cold load detects that corruption. A cache hit still requires a valid
binding and matching persisted file metadata. Missing inherited pins fail closed.
Cold recovery reconstructs the compact request and repopulates the cache on use.

`RequestImages.hydrate_with_cache/3` returns `{:ok, wire_request, cache}` explicitly;
`hydrate/3` wraps it with the optional cache callback. Providers never mutate the
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
