# Chat data API

The Ash API exposes message search and flat conversation reads independently of
UI-specific BFF ranking. Both use the requesting actor's existing Ash policies;
there is no owner impersonation or new authentication mechanism. Browser-session
login is still required. The generated specification is `/api/ash/open_api`.

## Search stored messages

`GET /api/ash/chat-messages/search?q=hello`

Ash action: `IntellectualClub.Chat.ChatMessage :search` (read).

Arguments:

- `q`: plain text, not raw `tsquery`/regex syntax. Words are case-insensitive
  and separated by punctuation or whitespace. In the default mode **all word
  prefixes** must occur anywhere in the same visible message, in any order.
  Tokens shorter than three letters/digits are ignored. An input with no
  eligible token yields no hits. Requests over 4,096 bytes, 16 search terms, or
  256 bytes per token return an empty search rather than a broader match
  from a truncated query. A word beginning with `postgres` can match
  `postgresql`; the infix `gres` cannot match it.
- `exact`: the existing wire flag now selects **Words in order**. Long tokens
  are still prefixes, but must occupy consecutive positions: `план выполн запрос`
  matches `план выполнения запроса`, not `план нового выполнения запроса`.
  Short words in such a sequence are whole words in their original positions,
  including repeats; at least one token must still be long enough. It is not
  a literal substring, a requirement on spaces, or a third whole-word mode.
- `chat_id`, `bot_id`: optional integer filters.
- `role`: optional `user` or `assistant`.
- Standard JSON:API `sort`, `filter`, `fields`, and `page` parameters work.
  Default order: `-created_at,-id`. Default page size: 25, maximum: 100.
  Offset and keyset pagination are supported; follow the response's `links.next`.
  Request `page[count]=true` when a total count is needed.

The response is a JSON:API collection of `chat-messages`. Each hit includes
`chat_id`, `parent_id`, `role`, `status`, `created_at`, `finished_at`, `text`, and
`active_branch` by default, plus the JSON:API record `id`.

- Every matching stored message is returned once, including multiple messages
  from the same chat and inactive branches. There is no per-chat grouping or
  UI ranking, and no exclusion of the current chat, subchats or shared chats.
- `text` assembles user input or assistant answer/handoff text in step/item/content
  order. Reasoning, tool arguments/results, artifacts and opaque payloads are not
  included. Files are not downloaded or OCR-searched.
- One search document represents one stored message. Words can span text fragments
  of one item; different terms and consecutive words may span visible items.
- `active_branch` means membership in the message's own chat's **local** active
  branch. It is computed after pagination and is not a searchable/sortable field.
- `chat_id` restricts stored messages belonging to that chat. Inherited linked-fork
  messages are not duplicated into search results. Search their source chat or
  search globally; use the conversation reader to obtain the projected context.
- Public `text` and `active_branch` calculations can also be requested on ordinary
  message reads using `fields[chat-messages]=text,active_branch,...`.

Example (URL-encode brackets and query text as necessary):

```text
/api/ash/chat-messages/search?q=release&role=user&sort=created_at,id&page[limit]=20
```

Direct Ash callers can use `Ash.Query.for_read(:search, %{q: "release"}, actor:
actor)`, `Ash.Query.load([:text, :active_branch])` and `Ash.read(page: [limit: 20])`.
The calculations are opt-in for direct Ash reads so candidate-only consumers do
not load every candidate's full text. Apply an explicit query sort before
`for_read` if overriding the default. In-chat BFF search opts out of pagination
with `page: false` and applies its own limit. Chat-list search uses the internal
owner-only Ash `ChatMessage :list_search` action with the same arguments plus
an explicit query plan (`strategy`).

## Read an active conversation

`GET /api/ash/chats/123/messages?offset=0&limit=25`

Ash action: `IntellectualClub.Chat.Chat :read_messages` (generic action).

- `id`: required chat id, taken from the route.
- `offset`: optional non-negative message offset, default 0.
- `limit`: optional integer from 1 to 100, default 25.

The response is a typed plain JSON object (not a JSON:API resource collection):

```json
{
  "chat_id": 123,
  "messages": [
    {
      "id": 456,
      "chat_id": 123,
      "role": "user",
      "status": "done",
      "text": "Question",
      "created_at": "2026-10-28T12:00:00.000000Z",
      "finished_at": "2026-10-28T12:00:00.000000Z",
      "inherited": false
    }
  ],
  "next_offset": null,
  "has_more": false
}
```

Messages are in conversation order, from root to active leaf. An empty chat returns
an empty `messages` array. `finished_at` may be null. Timestamps are ISO 8601 UTC
strings. Empty text is valid for messages with no user-facing text.

A linked fork includes its authorized inherited prefix, projected at its fork
boundary, followed by its local branch. Inherited messages retain their source
`id` and `chat_id` and have `inherited: true`; they are read-only context. The
reader never reloads their full source trace after projection. If the source is
private or unavailable, the whole read fails without returning partial context.
Checkpoint text is included as stored, in its position in the current branch.

Follow `next_offset` while `has_more` is true. Pagination is over the current
branch, not a snapshot: edits and branch switches between requests can change the
result. Output is bounded by message count, not bytes; large messages still return
full text. Branch traversal and fork-prefix validation may inspect more records
than the returned page.

## Shared implementation

`MessageText` owns tokenization, tsquery construction, text assembly and
snippets. PostgreSQL searches a private **positional `tsvector` per message**
(`simple` configuration) with GIN and the owner/time indexes. No second copy
of the original text or manually materialized table of prefixes is stored.
Text fragments of each eligible item concatenate in `(sequence,id)` order;
visible items are separated by paragraphs in step/item order. Only user
input/handoff and assistant answer/handoff-summary text is eligible: opaque,
reasoning, tool and file payloads are not searchable. The vector is maintained
on the message's private trace-revision row in the same transaction as a source
change, independently of the generation fence. It is not exposed in the API.
If an exceptionally large vocabulary exceeds PostgreSQL’s 1 MiB `tsvector`
limit, a fitting leading portion is indexed; the stored message is not rewritten.
As with PostgreSQL positional FTS generally, a lexeme records at most 256
positions and positions saturate at 16,383; ordered searches cannot distinguish
all later occurrences in exceptionally long/repetitive messages. The migration
backfills the current history and builds the GIN before reopening the service;
allow a maintenance window for upgrading large installations. Administrative reparenting of
trace foreign keys is serialized; a maintenance transaction spanning other trace
writes must take the same transaction advisory lock `(1229145684,1297045061)`
first or run offline. Normal message writes do not take this lock.
An ordinary read still applies the actor's Ash policies; only the global list
is additionally restricted to the actor's own non-subagent chats.

## Grouped chat list

`GET /api/bff/chat-list?sections=drafts,unread,working,other` returns the ordinary
list in one request. `sections` is a non-empty comma-separated subset of these
four names; duplicates are ignored and unknown names return `422`.

- `page_<section>`: independent positive offset page number, default 1.
- `per_page`: shared page size, default 20, maximum 100.
- `bot`: omitted for all bots, `none`, or a positive bot id.
- `preview_len`: first-message preview budget, default 200, maximum 500.

The response contains unique top-level `chats`, `sections`, shared `stats`,
`idle_revision`, and `next_read_state_expiry`. Each section has ordered `ids` and
`page: {number, per_page, total, has_next}`. Counts are exact; out-of-range pages
have empty IDs and retain the requested page number. Unlike grouped search,
ordinary list pagination needs no cursors. The client clamps pages after deletions
and reloads if necessary.

Drafts overlap the inbox and may include nested chats. They sort by personal draft
update time and descending id. Unread, Working, and Other exclude subagents and
sort by last activity and descending id; unread takes precedence over working.
Bot and ownership filters apply before counting and pagination. Sidebar stats
remain independent of the selected bot and sections.

All reads retain Ash authorization. A single lightweight membership query loads
classification and sorting metadata for matching chats; grouping and pagination
happen in memory. Detailed summaries, previews, and read states are loaded only
for the unique selected page IDs, and shared markers/stats are computed once.
Metadata memory is linear in the matching chat count, with sorting O(N log N);
this is not a bounded SQL-window implementation or a transactional snapshot.

`GET /api/bff/chat-list/idle-state` accepts the same section/page/bot parameters
and `revision=<idle_revision>`. One shared revision covers all selected pages,
personal read/draft markers, and visible subchat lifecycle state. Unchanged state
returns `204` when no snooze expiry is pending; otherwise the existing idle payload
contains `revision`, `next_read_state_expiry`, and
`active_generation_message_id`. The client acknowledges the revision only after
successfully applying the full list response.

Without `sections`, both endpoints retain the singular `section`/`page` contract
for already-open clients and other existing callers.

## Chat list search

`GET /api/bff/chat-list/search?q=...&exact=1&bot=...&after=...&limit=30`

Chat-list search covers both inbox and archived chats. It returns message
hits, newest first, plus chats whose note matches. Bot names are not searched;
the bot filter panel covers that. There are no list sections in search mode and
no per-chat grouping or ranking on the server: clients group neighbouring hits
of one chat themselves.

Parameters:

- `q`: the query, tokenized exactly like the Ash `:search` action above. A
  blank query returns empty results.
- `exact`: `1`/`true` requires consecutive prefix positions (Words in order).
- `compact`: `1`/`true` requests only the search card: `id`, `note`, `bot_id`,
  `bot_name`, `created_at`, `updated_at`, `read_state`, and `message_count`.
  Hits, notes, ordering, archive scope and cursor semantics are unchanged.
  The compact expiry marker refers to the displayed chats. Without this flag
  the endpoint retains full summaries for existing clients.
- `bot`: optional bot id or `none` for chats without a bot; applies to notes
  and hits.
- `limit`: hits per page, default 30, maximum 100.
- `after`: the opaque `next_cursor` of the preceding page. Cursors are signed
  and scoped to the actor, query, `exact` and `bot`; a cursor from another
  scope, another actor, or older than a day returns `422` with
  `code: "invalid_cursor"`. Clients then restart from the first page.

Response:

```json
{
  "chats": [{"id": 12, "message_count": 7, "...": "chat summary"}],
  "notes": [12],
  "hits": [
    {"message_id": 456, "chat_id": 12, "role": "assistant",
     "created_at": "2026-01-01T12:00:00.000000Z", "active": true,
     "snippet": "...text around the earliest term..."}
  ],
  "next_cursor": "opaque or null",
  "text_search": true,
  "terms": ["release", "notes"],
  "next_read_state_expiry": null
}
```

- `notes` lists chats (ids, `updated_at` descending, at most 20) whose note
  satisfies the same word-prefix/positional query; it is only populated on the first page.
- `hits` are stored messages of the actor's own non-subagent chats whose text
  contains every term, ordered by `(created_at DESC, id DESC)`. `active` is
  membership in the chat's local active branch; inactive-branch hits are
  included. `snippet` is a window of the matching content around the earliest
  term occurrence, or `null`; `terms` lets clients highlight matches.
- `chats` carries one summary per chat referenced by `notes` or `hits`, note
  chats first, then hit chats in order of their first hit. `message_count` is
  the active-branch length.
- `text_search` is `false` when there is no usable search. With only short
  tokens (or only punctuation) both `notes` and `hits` are empty. `terms`
  contains normalized individual tokens, also in Words in order mode.

### Bounded reads and deadlines

1. Within a small statement budget (`:chat_search_probe_timeout_ms`, default
   250 ms; 0 disables the probe), read up to `:chat_search_probe_window` newest
   eligible message IDs after the cursor (default 96). Check only these vectors
   in time order, without a global GIN scan. If the page plus its lookahead
   row is full or the window exhausted the corpus, no indexed tail is read.
2. Otherwise the indexed read is restricted to positions strictly older than
   the last inspected `(created_at,id)`, with a limit of only the missing rows.
   On a probe timeout the whole probe is discarded and the indexed plan starts
   at the original cursor. Only the final page's source texts are assembled
   for snippets. A broad prefix never triggers an unbounded count in the list.
3. The compact UI does not load full drafts, tools, configurations or nested
   chat summaries to present its first hits. Active/inactive flags and active
   counts are obtained from branch metadata only for the chats on the page.

`SearchDeadline.run` bounds the whole search and response enrichment with
`:chat_search_timeout_ms` (default 5,000 ms), including snippets, drafts and
summary construction. Exhaustion cancels the worker and returns `503` with
`code: "search_timeout"` and a localized `error`. The existing
`:chat_search_statement_timeout_ms` (default 5,000 ms) remains an additional
per-SQL cap, bounded by the remaining overall budget.

## In-chat search

`GET /api/bff/chat-search/:id/messages?q=...&exact=1` searches one readable
chat with the same tokenization and returns `active` and `inactive` branch hits
in conversation order, each with the full `content` and a `snippet`.

## Personal archive in the chat-list BFF

`GET /api/bff/chat-list` and `/api/bff/chat-list/idle-state` accept
`view=inbox|archive` (default `inbox`). The selected view scopes grouped and
individual section reads before pagination, sidebar counts and idle revisions.
Sidebar counts include all bots in that view. For compatibility,
`/api/bff/chat-list/search` still accepts either view value. Both yield the
same results, and a search cursor works across views. Invalid view values return 422.

`read_state.is_archived` is an additive boolean in chat summaries and detail
payloads. Archive state is independent of `can_edit`. The existing
`POST /api/bff/chat-state/:id/read-state` accepts `archive` and `unarchive`;
`archive` requires the observed activity revision, and both require the expected
personal state version. Direct subchat archive attempts return 422.

`GET /api/bff/chat-list/archive-other-preview?bot=...` returns `{count, revision}`
for all eligible Other chats in the inbox, not just the visible page. Bot filtering
has the same syntax as the ordinary list. Drafts and future snoozes on a chat or
any nested subchat protect the standalone parent.

`POST /api/bff/chat-list/archive-other` accepts `{bot, expected_revision}` and
returns `{count}`. The authorized Ash action locks and rechecks the snapshot,
then commits all personal archive writes together. A changed snapshot returns
409 with `error: "stale_archive_preview"`; refresh the preview and obtain a new
explicit confirmation. Empty valid snapshots return count zero. Successful
writes invalidate the requesting user's list through the existing SSE stream.
