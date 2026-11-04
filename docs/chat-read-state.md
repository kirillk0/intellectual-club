# Chat read state and snooze

Read state belongs to a user/chat pair, including read-only shared viewers. It is
not a field on the shared chat and does not change chat activity ordering.

## Durable state

- `ChatActivity.revision`: monotonic terminal assistant-generation activity.
- `ReadState.read_revision`: last displayed activity acknowledged by this user.
- `ReadState.manual_unread`: explicit reminder independent of new activity.
- `ReadState.snoozed_until`: UTC deadline suppressing the unread indicator.
- `ReadState.state_version`: compare-and-swap version of personal intent.
- `ReadState.archived_revision`: nullable observed activity revision at archive time.

`has_unread = manual_unread OR activity_revision > read_revision`.
`is_unread = has_unread AND NOT is_snoozed`.

`is_archived = archived_revision IS NOT NULL AND activity_revision <= archived_revision`.
Archiving is personal, including for shared read-only viewers, and preserves read
state, snooze, drafts, and chat ordering. A new terminal generation (`done`,
`error`, or `canceled`) returns the chat to the inbox without rewriting personal
rows. Reading, opening, or completing a subchat does not unarchive its parent.
Only standalone chats (`subagent=false`) can be archived directly. Subchats,
including their draft section entries, follow the nearest standalone parent’s
list mode. Independent forks remain independent.

The read-state endpoint also accepts `archive` (with `observed_revision`) and
`unarchive`, using the same `expected_state_version` CAS as other personal actions.
A newer result arriving concurrently remains visible. Existing history starts
unarchived; the schema migration does not archive any user data.

The list offers Inbox and Archive modes, stored as `view=inbox|archive` in the
URL. Search, pagination, and sidebar counts use that mode. The Other section’s
Archive all command previews an actor/filter-bound snapshot across all pages,
then requires confirmation. Chats with a nonempty draft or active snooze anywhere
in their subchat tree are excluded. A changed eligible set, activity revision,
or personal state version invalidates confirmation with 409; no partial writes
are committed. Personal writes acquire chat key-share locks before their upsert;
bulk archive locks authorized owned chats, then draft/state rows, in ID order.
This also serializes first inserts without reversing foreign-key lock order.

Snoozed list rows show a clock and a visible local deadline, including on mobile.
Expiry refreshes the presentation through the existing deadline timers.

Snooze sets manual unread, so a reminder appears even without a new response.
Expiry changes presentation without requiring a scheduled database mutation.
It does not send a push notification. Generation error/cancellation indicators
remain visible independently of unread and snooze.

Activity is advanced transactionally by a trigger declared in the Ash activity
resource on `generating -> done/error/canceled`. Retrying the same message creates
new activity; repeated terminal writes do not. Existing history starts at zero.
The activity row is created with the chat, avoiding a late chat FK lock during
message finalization. Writers must never lock activity before chat/message rows.

## API and presence

`POST /api/bff/chat-state/:id/read-state` takes an action, expected state version,
and for read, the observed activity revision. Stale versions return 409. A read
acknowledges only the displayed revision, not the latest server revision.
Automatic acknowledgements do not clear manual unread or snooze; explicit entry
or the read command does. Clients must not blindly retry a 409 with a fresh version.

A visible, focused, active stack layer reads after loading/rendering the chat.
Background tabs and inactive layers do not read results. Manual unread/snooze
suppresses automatic reads during the current visit, including new results and
expiry. A later activation starts a new visit and can consume the reminder.

The list contains independent, paginated Drafts, Unread, Working, and Other sections.
Drafts is an overlapping personal section; see [chat drafts](chat-drafts.md).
Unread takes precedence over working; snoozed chats can still appear as working.
The ordinary list and its idle probe each use one grouped request with independent
`page_<section>` offsets and a shared revision (see
[chat data API](chat-data-api.md#grouped-chat-list)).

Filters apply across the dataset before section pagination. Search replaces the
sections with chats whose note matches and message hits ordered newest first;
clients group neighbouring hits of one chat and load more pages with a signed
keyset cursor (see [chat data API](chat-data-api.md#chat-list-search)). There is
no search count. Cursors are bound to the actor, query, exact flag and bot
filter; discard them when those change. Search is not a snapshot: read-state
mutations, snooze expiry, drafts, and new activity can change chat summaries
between pages. A response shares one overall search budget (5 seconds by
default), including enrichment; a timeout returns `503` with
`code: "search_timeout"`.

## Synchronization

`GET /api/bff/chat-events` is a session-authenticated SSE stream in the mixed
session pipeline, not JSON-only negotiation. Events contain chat IDs (and draft revisions for draft events) on a
user-scoped PubSub topic. Personal mutations and assistant status changes publish
invalidations. A connection expires after 60 seconds to recheck session access.

One refcounted EventSource serves mounted views; hidden/offline clients disconnect.
Connection/reconnection refreshes snapshots because events are not replayed.
An invalidation never starts a new read visit. Polling all list sections, foreground
refresh, and local snooze-deadline timers remain recovery mechanisms.

An expired or invalid search cursor restarts the current query once from the first page; a second failure is shown normally.
