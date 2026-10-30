# Personal chat drafts

Chat drafts are private editor state, not chat messages. They never enter message
history, LLM context, message search, exports, unread state or chat activity.
The first version synchronizes text only. Pending attachments remain device-local
until sent; the composer explicitly states this limitation.

## Storage and API

`IntellectualClub.Chat.ChatDraft` is an Ash resource keyed by `(user_id, chat_id)`.
Only the chat owner can read or write it. Its fields are `text`, a monotonically
increasing `revision`, and server `updated_at`. Deleting the chat or user cascades
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

A clean editor adopts the remote version. Unsynchronized local changes based on
an outdated revision trigger a conflict instead of a silent overwrite. The editor
shows both texts and lets the user keep the local text or use the server version.
No automatic text merge is attempted. Routine progress (pending, saving, saved) is
not displayed. The composer reports only conflicts and unsynchronized edits that
could not reach the server: offline, a failed request (kept visible across retries
until a write succeeds) and missing local recovery.

## Chat list and events

The list has a first, independently paginated **Drafts** section, filtered before
pagination and sorted by draft update time. It can include nested chats and older
continuation chats that ordinary sections group or hide. A chat may also remain
in Unread, Working or Other; a draft does not replace those classifications.
Search still searches canonical chat metadata/messages, not private draft text.

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
