# Generation polling

The SPA uses `poll_protocol=cursor` on the message poll endpoint. The Worker is
already the canonical in-memory trace owner; there is no UI snapshot process,
periodic snapshot publication, or full-text hashing on provider events.

## Runtime contract

A reader keeps `runtime_cursor`, `view_revision`, `content_revision`, and
`revision`. The cursor is a bounded JSON object identifying the Worker epoch,
step, structural revision, selected item/content, text generation, and UTF-8 byte
offset. It is not an authorization token. Every HTTP request is authorized anew.
Missing, invalid, stale, out-of-range, and non-UTF-8-boundary offsets reset the
current step. The cursor is acknowledged only after the response is applied.
Lost responses can be replayed using the previous cursor. Branch replacement,
navigation, and incompatible deltas discard all polling revisions.

Structural changes reset the runtime step and return candidate `runtime_targets`.
The client chooses which text block to follow, preferring `answer`, then
`handoff_summary`, then `reasoning`. Only that cursor is sent back. Ordinary
polling returns `runtime_delta` with `[from, to)` byte offsets and the new suffix.
A text replacement advances its generation even if the byte length is unchanged.
The server slices binaries; it does not compare or hash the old text prefix.
Small live metrics are returned separately as `runtime_summary`.

This is intentionally approximate streaming. Existing, unselected blocks may
change without immediate delivery. Structural resets may reveal them earlier;
a persisted step boundary always reconciles canonical content and identifiers.
No server-side subscriber state, per-block cursor manifest, or delta journal is
maintained. New clients may always request a full current representation.

## Persistence and cheap unchanged polls

`ChatMessagePollRevision` is a database-maintained counter declared as an Ash
resource, loaded through the authorized message. Its separate row never upgrades
a generation fence lock on the message itself. Its custom statements install
transactional triggers on steps, items, and contents. Creation, update, deletion, bulk writes, and cascades therefore
invalidate the parent revision in the same transaction, without extra per-row
Ash round trips. All application reads and mutations still pass through Ash and
its authorization policies. The counter does not change on runtime chunks.

Cursor polling compares compact message/runtime revisions before enumerating
trace metadata or reading completed bodies. Subchat costs retain their existing
authorized, parent-phase-based refresh policy. Runtime summary changes do not
require full content projection. A successful `204` does not scan persisted
items/contents or serialize/hash accumulated runtime text.

After a persisted revision changes, the response supplies canonical content for
the whole message, not just the completed step. This conservative boundary reload
also covers historical edits and deletions; ordinary streaming remains suffix-only.
This is a level-triggered condition, not a one-shot completion event: a reader
that missed finalization, cancellation, retry, or several steps still reloads
what it lacks on its next request, including after the Worker exits. A committed
step or successor takes precedence over an unacknowledged stale runtime step.
Worker timeout is `busy`, never proof of absence or a reason to cancel generation.

The non-cursor endpoint behavior remains supported for existing callers and
working-step detail loads; those snapshots are built only on explicit reads.

## Retired runtime cursors

Canonical reconciliation can return a compact cursor containing only `epoch`,
`step`, `sequence`, and `retired: true`. For that exact Worker and step, polling
returns no runtime step or summary and keeps the cursor stable with `reset: false`.
It does not inspect the old trace, even if its text, metrics, or structure changes.
A new epoch or step identity/sequence resets normally. This also covers a provider
response committed while the Worker still reports `waiting_provider`, before ACK.
The full response computes its view/revision from this effective retired runtime,
so the very next unchanged request can return `204`.

Retirement is only an approximate-streaming hint, not proof of canonical delivery
or an authorization token; a client may intentionally opt out of streaming a step.
A missing or mismatched `content_revision` clears the cursor in the controller
before polling. Persisted invalidation always wins and canonical content is sent
again, including when the prior canonical response was lost. Clients acknowledge
both revisions and the retired cursor only after applying that response.

## Independently loaded step inspector

The inspector may load `/working` independently of the message cursor. Each such
load advances a small client-owned `working_sync` generation. The next poll includes
that token in its view, forcing one full projection to align the inspector and
message body. Until it succeeds, the client does not reuse `working_revision`.
A response for an older inspector session may update the message body, but cannot
append its suffix to the newly loaded inspector. Subsequent polls keep the same
token and return to the cheap suffix/unchanged path.
