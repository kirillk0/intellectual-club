# Immutable step request storage

`IntellectualClub.Generation.StepRequests` stores an **opaque compact JSON object** per step. It has no provider, image, file, prompt or binding knowledge. It neither hydrates nor changes logical content. Request-file bindings retain their existing lifecycle.

## Logical generation writes

Normal generation uses the separate, non-public `ChatMessageStep.create_request` action. Prepare its changeset **before** taking publication row locks:

```elixir
{changeset, snapshot} = StepRequests.prepare_create!(
  %{chat_message_id: message.id, sequence: next_sequence, status: :waiting_provider},
  final_compact_request,
  actor: actor,
  previous_step: previous_step,
  previous_request: previous_compact_request,
  force_full: boundary?,
  max_chain: 32
)

# Encoding is complete. In generation, this transaction also attaches staged
# image bindings and publishes the previous-step transition/steering receipt.
Ash.transaction([ChatMessageStep], fn ->
  Ash.create!(changeset, actor: actor, authorize?: true)
end)

snapshot.request # normalized JSON object, preserving numeric values
snapshot.hash    # canonical SHA-256
snapshot.size    # canonical compact JSON byte size
```

The resource-owned change derives normalization, canonical hash/size and diff from logical input during `for_create`. It captures the plan in a `before_action` closure, **not** a caller-writable validated flag, context value or snapshot struct. Publication checks unchanged inputs/actor/message/sequence/owner, locks the message and compares persisted predecessor ID, owner, message, sequence, hash, mode and checkpoint distance. It then inserts the captured encoding without repeating normalization, hashing or diff. Caller previous-step metadata supplies only an expected ID; its claimed hash/distance is never authoritative. Runtime base mismatches fail even when the writer would choose a full checkpoint. Legacy nil-hash predecessors are reconstructed through authorized reads during preparation.

`Persistence` performs this preparation after provider/image preparation but before its own publication transactions and locks. Callers already inside an outer `Lease`/linked-cleanup/fork transaction retain that outer scope: moving preparation ahead of those locks requires restructuring the outer caller, with staged bindings kept alive until its final transaction outcome. `prepare_create!/3` is the split preparation API; it does not release pre-existing caller locks. `PreparedRequests` may return `%{request: map, bindings: ..., ...}` with additional cache/image metadata: persistence preserves those fields and returns its authoritative `request_snapshot` alongside `request`/`step`. Binding attachment remains in the same transaction as the step. An externally supplied snapshot is not trusted at the Ash boundary; final normalization belongs to the resource.

`StepRequests.snapshot!/1` provides a pure normalized `Snapshot` with cached hash and size. `hash/1` hashes without constructing a forced-full encoding; `equal?/2` compares normalized JSON by numeric value. Snapshots are computation caches, not capabilities. Normalization and canonical encoding are fused into one traversal per distinct current/base document in ordinary preparation; string validity is checked while encoding, without a separate full UTF-8 scan. An unchanged retry uses one snapshot and skips diff; publication-transaction retries reuse the prepared changeset. Neither API authorizes storage access.

## Physical encoding writes

The existing `ChatMessageStep.create` path remains independently validated for physical imports, copies and compatibility. Unlike the logical action it accepts encoding fields and verifies them, regardless of any caller-supplied hash, snapshot or context flags.

```elixir
attrs = StepRequests.create_attributes(compact_request,
  sequence: next_sequence,
  previous_request: previous_compact_request,
  previous_step: previous_step,
  force_full: boundary?,
  max_chain: 32
)

ChatMessageStep
|> Ash.Changeset.for_create(:create,
  Map.merge(attrs, %{chat_message_id: message.id, sequence: next_sequence}),
  actor: actor)
|> Ash.create!(actor: actor)
```

`create_attributes/2` returns **only encoding attributes**, not sequence, owner, message, response or status. `:sequence` defaults to 1. Previous step metadata contains sequence/mode/hash/checkpoint distance (selected by default on the resource); previous request is the reconstructed compact map. Missing or incompatible previous state produces a full checkpoint. Use `:force_full` at logical boundaries and for copies/retries without a retained predecessor.

`normalize!/1` recursively converts atom keys and values to JSON strings, except `nil`, `true`, and `false`. It rejects structs, non-JSON terms, invalid UTF-8, non-string/non-atom keys, and key collisions after normalization. The root must be an object. All object fields, nested arrays, nulls, strings, numbers and booleans are opaque.

| Attribute | Full checkpoint | Patch |
|---|---|---|
| `request_mode` | `:full` (legacy default) | `:patch` |
| `raw_request` | normalized compact map | `%{}` |
| `request_patch` | `nil` | RFC6902 array |
| `request_hash` | SHA-256; nullable for historical full | required result hash |
| `request_base_hash` | `nil` | required preceding logical map hash |
| `request_base_sequence` | `nil` | exactly `sequence - 1`, in the **same message** |
| `request_checkpoint_distance` | `0` | patches since checkpoint, `1..32` |

Hashes are lowercase hexadecimal SHA-256 of UTF-8 compact JSON with object keys sorted lexicographically and decimal numbers normalized (`Decimal.normalize/1`, scientific output, zero without a sign). Numerically equal integer/float/exponent forms hash equally, so PostgreSQL JSONB reserialization cannot invalidate a hash. Array order is retained; this canonical serialization does not modify the stored input map. The applied diff must be semantically equal to the normalized target; otherwise the writer falls back to full. One meaningful apply/equality roundtrip is retained to catch the dependency's overlapping JSON Pointer escape bugs. Equality follows the same decimal canonicalization as hashes, not strict BEAM equality or conversion of all numbers to floats: `1`/`1.0` permit an empty patch, while `10^80 + 1` and `1.0e80` remain distinct. Already materialized large integers retain their exact values. RFC `test` operations, physical rewrites and backfill use the same numeric semantics.

Full is mandatory at sequence 1, forced boundaries, absent/unsafe previous state and the distance limit. `max_chain` is a per-call integer `1..32`, default 32: at most 32 patches between full rows. Patch JSON must be **strictly less than 50% of full JSON bytes**; equality at 50% falls back to full. This compares payload bytes, not PostgreSQL page size or metadata overhead.

Creation validates shape, same-message base, distance and both hashes, with authorized Ash reads and message/step row locks for patches. jsonpatch 2.3.1 is pinned; the adapter enforces strict RFC pointer escapes and array indices rather than the dependency's permissive numeric-prefix parsing.

## Readers

```elixir
request = StepRequests.request_for_step!(step_id, actor: actor)
{:ok, request} = StepRequests.request_for_step(step_id, actor: actor)
requests = StepRequests.requests_for_steps!(steps, actor: actor)
# %{step_id => compact_map, ...}
snapshots = StepRequests.snapshots_for_steps!(steps, actor: actor)
# %{step_id => %Snapshot{request: compact_map, hash: hash, size: bytes}, ...}
```

An explicit actor is mandatory. All reads use Ash authorization, retaining existing shared-read access. Supplied resources/payloads are not proof of access; `authorize?: false` is never forwarded. Missing/inaccessible steps fail closed.

The batch reader accepts resources, projections or IDs. It batches metadata reads (100 IDs), merges bounded ancestry windows, explicitly selects raw/patch fields, and reconstructs each ancestor once with a shared cache. The cache stores normalized requests with verified hash/size, so a reconstructed result is not immediately normalized and hashed again as the next base. Empty patches reuse the base snapshot. Even legacy full rows get a computed cache hash without writing it back. There is no query per predecessor. `raw_request` remains unselected by default; an unselected historical request is loaded, **never substituted with `%{}`**.

Historical full rows without hashes remain valid at any positive sequence, including independent full rows after a gap. Patches require contiguous same-message ancestry. Gaps in a patch chain, malformed encodings, hash mismatches and excessive distances fail explicitly without exposing payloads in errors.

## Immutability

Ordinary `ChatMessageStep :update` accepts response, status, metrics and timings, but rejects sequence and every request encoding field. A change also rejects forced encoding/identity changes on that action.

The non-public `:rewrite_request_encoding` action accepts a private `:encoding` map containing all seven physical attributes. It trusts no caller-supplied original or context flag: authorized row locks, reconstruction and canonical numeric-value equality are checked independently, including the immediate successor patch. It preserves `updated_at`; identities, sequence, responses, statuses, metrics, timestamps and bindings do not change. Only the owner can rewrite, even for shared messages. The action cannot repair corruption by substituting guessed content.

## Manual bounded backfill

There is **no startup hook, migration backfill, scheduler, or implicit all-database loop**. Historical rows remain full with null hashes; normal reads do not mutate them.

```elixir
# Preview one page. actor is the explicitly supplied authenticated owner.
{:ok, preview} = StepRequests.backfill_batch(
  actor: actor, message_limit: 20, after_id: 0, dry_run: true
)

# Apply that SAME page using the SAME starting cursor.
{:ok, result} = StepRequests.backfill_batch(
  actor: actor, message_limit: 20, after_id: 0, dry_run: false
)

# Inspect progress before explicitly requesting another page.
# Resume using after_id: result.next_cursor.
```

Options:

- `:actor`: required; only that actor's own assistant messages are candidates.
- `:message_limit`: required integer `1..100`. One metadata lookahead row sets `has_more`; it is not processed.
- `:after_id`: exclusive ascending message ID cursor, default `0`.
- `:dry_run`: boolean, default `true`.
- `:max_steps_per_message`: integer `1..1000`, default `256`. Oversized messages are skipped before request bodies are loaded.
- `:max_chain`: `1..32`, default `32`, for newly encoded rows. Existing valid patches and their immediate full checkpoints are retained.

Each message is one transaction. An existing generation **reservation**, without changing a fence token, excludes active workers across nodes. Ash row locks follow chat → message → step order. Generating messages, waiting steps, leases, unavailable lease infrastructure, gaps, oversized histories and corrupt/unreadable encodings are skipped. Dry-run uses the same locks and checks without writes.

The bounded message is reconstructed before planning, proposed equality is checked, each rewrite goes through the private equivalence action, and stored requests are reconstructed again before commit. An error rolls back the message. No image references are interpreted or bindings changed. Reruns are idempotent. Results contain only counters, bounded `{message_id, reason}` skips, `next_cursor` and `has_more`—never raw requests.

The cursor advances past **all scanned messages, including skips**. Retain skip IDs/reasons for explicit later retry from an earlier cursor. Do not use a dry-run end cursor to start its apply pass: that would skip the previewed page.

### Supervised execution

```elixir
{:ok, pid} = StepRequests.start_backfill(actor: actor, message_limit: 20, dry_run: false)
{:ok, progress} = StepRequests.backfill_status(pid, actor: actor)
{:ok, progress} = StepRequests.cancel_backfill(pid, actor: actor)
```

One temporary GenServer child runs under existing `IntellectualClub.BackgroundTasks.Supervisor`; **no Application child/edit is needed**. It runs exactly one bounded page. Status and cancellation require the initiating actor. Cancellation is cooperative between message transactions: the in-flight message finishes atomically, then the cursor identifies the last scanned message. Small terminal progress is retained for 60 seconds before the child exits. Persist the cursor externally for restart recovery; resuming from the last observed cursor is safe because transactions are per-message and reruns are idempotent.

## Migration and rollback

`20260925120000_add_step_request_encoding.exs` adds six columns without rewriting requests. Take the normal backup before applying it. The migration must precede code rollout using those columns.

Rollback refuses to drop encoding columns while patch rows exist. First explicitly expand patches to equivalent full encodings under the same ownership/equality checks, in reverse sequence order to avoid invalidating remaining successor patches. No migration-time expansion is automatic.

## Verification

Tests: `step_requests_codec_test.exs`, `step_requests_storage_test.exs`, `step_requests_backfill_test.exs`, `step_requests_pipeline_test.exs`. They cover arbitrary JSON/escaping/arrays and large integers within the configured JSON parser limits, thresholds/checkpoints, legacy rows and unselected payloads, corruption/gaps/base hashes, actor isolation/shared reads, immutable updates, equivalent rewrites, bounded query counts, unchanged bindings, dry-run/cursors/reruns, active/unsafe skips and supervised status/cancellation.

Pipeline regression tests trace codec calls: different target/base preparation computes two snapshots and one diff; unchanged preparation computes one snapshot and no diff; publication performs none of these operations. Snapshot construction does not call a separate recursive normalization pass. A 12-document patch chain computes 12 snapshots, not another hash per base; an unchanged chain computes only its checkpoint snapshot. Fail-closed tests include forged snapshot/context/base/hash input, changed actor/owner/arguments, predecessor metadata drift and full-write runtime mismatches.

Run these with normal project setup against a migrated, isolated test database. `IC_TEST_DATABASE_NAME` can select that database without changing the development database. Do not run concurrent suites against the same SQL sandbox or restart the shared PostgreSQL instance during a suite.
