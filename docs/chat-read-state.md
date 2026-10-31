# Chat read state and snooze

Read state belongs to a user/chat pair, including read-only shared viewers. It is
not a field on the shared chat and does not change chat activity ordering.

## Durable state

- `ChatActivity.revision`: monotonic terminal assistant-generation activity.
- `ReadState.read_revision`: last displayed activity acknowledged by this user.
- `ReadState.manual_unread`: explicit reminder independent of new activity.
- `ReadState.snoozed_until`: UTC deadline suppressing the unread indicator.
- `ReadState.state_version`: compare-and-swap version of personal intent.

`has_unread = manual_unread OR activity_revision > read_revision`.
`is_unread = has_unread AND NOT is_snoozed`.

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
Filters and search apply across the dataset before section pagination. Grouped
search returns all requested sections in one request, with unique chat summaries
and separate ordered IDs and pagination metadata for each section (see
[chat data API](chat-data-api.md#chat-list-search)).

Grouped search uses independent keyset cursors, not offsets: send a section's
`next_cursor` as `after_<section>` to continue it. `page_<section>` is only a
display label, and any value greater than 1 requires a valid cursor. Each page
contains `number`, `per_page`, `total: null`, `has_next`, and `next_cursor`;
there is no exact grouped-search count. Use `has_next` rather than deriving
page counts from `total`. On the last or an empty page, `next_cursor` is null.
This does not change the ordinary list or legacy singular `section/page` search
contract, which retain exact totals.

Search cursors are signed and bound to the actor, term, bot filter, section, and
page size. Discard them when those filters change; a first-page refresh starts a
new cursor chain. Non-draft search sections sort by `(updated_at DESC, id DESC)`;
drafts sort by personal draft update time and descending id. This is not a
snapshot: read-state mutations, snooze expiry, drafts, and new activity can move
chats between pages or sections. A grouped response shares one overall search
budget (5 seconds by default), including enrichment; a timeout returns `503`
with `code: "search_timeout"`, not partially refreshed section data.

## Synchronization

`GET /api/bff/chat-events` is a session-authenticated SSE stream in the mixed
session pipeline, not JSON-only negotiation. Events contain chat IDs (and draft revisions for draft events) on a
user-scoped PubSub topic. Personal mutations and assistant status changes publish
invalidations. A connection expires after 60 seconds to recheck session access.

One refcounted EventSource serves mounted views; hidden/offline clients disconnect.
Connection/reconnection refreshes snapshots because events are not replayed.
An invalidation never starts a new read visit. Polling all list sections, foreground
refresh, and local snooze-deadline timers remain recovery mechanisms.

Expired or invalid search cursors reset all section histories and retry the current query once from the first pages; a second failure is shown normally.
