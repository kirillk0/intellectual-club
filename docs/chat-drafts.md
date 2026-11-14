# Personal chat drafts

Chat drafts are private editor state, not chat messages. They never enter message
history, LLM context, message search, exports, unread state or chat activity.
Attachments upload in the background as soon as they are added. Completed uploads
are durable private files, restored after reload and on other devices. Images retain
the original and, when normalization produces one, the compressed version; the chosen
version is synchronized independently of text.

## Storage and API

`IntellectualClub.Chat.ChatDraft` is an Ash resource keyed by `(user_id, chat_id)`.
Only the chat owner can read or write it. Its text fields are `text`, a monotonically increasing `revision`, and server
`updated_at`. Attachment count and revision track list membership and invalidation
without introducing conflicts with concurrent typing. Deleting the chat or user cascades
to their draft rows. Empty drafts retain their revision as tombstones: a stale
device cannot recreate an already submitted draft using an old version.

- `GET /api/bff/chat-drafts/:chat_id` returns `{draft: {chat_id, text, revision,
  updated_at}}`. An absent row is represented by empty text, revision zero and
  a null timestamp.
- `PUT /api/bff/chat-drafts/:chat_id` takes `{text, expected_revision}`. A successful
  atomic compare-and-swap returns the saved snapshot. A stale version returns
  HTTP 409 with the current snapshot in the same response shape.
- Text is limited to 1 MiB, preserves whitespace, and is never included in list
  summaries or SSE events.
- Accepted send, queue and steer requests may include `draft_revision`. Their
  acceptance transaction clears only a matching revision **and** submitted text.
  Newer edits are preserved. Failed acceptance leaves the draft untouched.

The conditional insert/update is encapsulated in an authorized Ash action,
including the concurrent first-insert case. Personal draft writes do not touch
canonical chat/message timestamps.

## Attachment storage and API

`ChatDraftAttachment` is an owner-authorized Ash resource scoped to a chat and user.
Its stable UUID, independent revision, status (`pending`, `ready`, `deleted`), image
metadata and selected variant are separate from the text synchronization protocol.
Each variant owns a logical `Files.File`; existing SHA-256 storage deduplicates bytes.
Deleted attachment rows retain tombstones to reject late registration/finalization.

- `GET /api/bff/chat-drafts/:chat_id/attachments` lists private attachment snapshots.
- `PUT /api/bff/chat-drafts/:chat_id/attachments/:uuid` supports `start`, `finish`
  (completed original/compressed upload IDs), and `select` (expected revision and
  `keep_original`). Repeated registration/finalization is idempotent. A stale
  selection returns the current snapshot without overwriting it.
- `DELETE` at that URL discards the attachment and its logical files.
- `GET .../:uuid/original` and `GET .../:uuid/compressed` authorize through the
  private attachment before serving bytes. Shared chat access does not grant access.
- Upload sessions with `purpose: "draft"` use the storage limit (500 MiB per variant)
  so a large original can be retained even when only its compressed copy fits the bot.
  The selected variant is validated against the current chat policy on submission.

Send, queue and steer accept `draft_attachments: [{id, revision}]`. They duplicate
logical references without uploading/copying the payload, and consume the exact
snapshots inside the acceptance transaction. New attachments and newer text remain;
stale attachment selections reject acceptance. Failed acceptance preserves both
variants. Explicit deletion and chat deletion release the draft's logical files;
message/queue copies have independent lifetimes.

Pending transfers still depend on the source browser. Navigation within the app can
finish an in-flight transfer against its original chat. Closing the browser before
completion cannot preserve unsent bytes: a restored pending entry explains that the
original device must finish, or the file must be attached again. Local failures can
be retried, and reconnect retries local uploads. Completed files never expire with
the 24-hour staging session. Unfinished staging files retain the existing expiry.

## Client synchronization

The reusable `useSyncedTextDraft` composable keeps immediate local recovery data
under an account-scoped key, including the base server snapshot and whether local
changes remain unsynchronized. Separate per-tab recovery slots prevent another
tab from overwriting unsynchronized local recovery text. Clean cached text is not an instruction to overwrite
the server. Legacy local drafts are imported only after checking chat ownership.

Server saves use a 1-second trailing debounce with a 5-second maximum wait during
continuous typing. Navigation and hiding the page attempt to flush pending edits;
closing a browser cannot guarantee completion, so local recovery remains necessary.
While any edits of the current account are not acknowledged by the server, closing
or reloading the page asks for the browser's standard leave confirmation.
Network errors retain local text and retry with backoff. Foreground/reconnect and
personal SSE invalidations reload the server snapshot.

Before each write, local recovery also records its text and expected revision.
Until the outcome is known, retries repeat that same write while newer edits stay
in the editor. A snapshot at exactly the next revision with the attempted text
acknowledges the write even if its HTTP response was lost. Newer local edits then
save against that revision without a conflict, including after a page reload.
An uncertain write keeps recovery dirty even if the user undoes back to the base
text, so that undo is not overwritten by a late acknowledgement.

A clean editor adopts the remote version. Unsynchronized local changes based on
an outdated revision trigger a conflict instead of a silent overwrite. The editor
shows both texts and lets the user keep the local text or use the server version.
No automatic text merge is attempted. Routine progress (pending, saving, saved) is
not displayed. The composer reports only conflicts and unsynchronized edits that
could not reach the server: offline, a failed request (kept visible across retries
until a write succeeds) and missing local recovery.

## Chat list and events

The list has a first, independently paginated **Drafts** section, filtered before
pagination and sorted by draft update time. It can include nested chats that
ordinary sections omit. A chat may also remain
in Unread, Working or Other; a draft does not replace those classifications.
Search still searches canonical chat metadata/messages, not private draft text.

Attachment-only drafts participate in the same lists and archive protection.
Summaries expose only `has_draft` and `draft_updated_at`. Draft revisions participate
in list idle invalidation. The existing user-scoped SSE stream emits
`chat_draft_changed` with `{chat_id, revision}` after saves and accepted consumption.
Events are invalidations, not a replay log; snapshot refresh repairs missed events.

## Future block drafts

Block drafts can reuse the client synchronization protocol and status UI without
sharing a polymorphic database table. A separate `KnowledgeBlockDraft` resource
should additionally store the published block's base revision. Saving that draft
must not publish the block; applying changes needs a separate base-version check.
The existing local block-draft implementation is unchanged by this feature.
