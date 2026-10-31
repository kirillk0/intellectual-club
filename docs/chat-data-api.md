# Chat data API

The Ash API exposes message search and flat conversation reads independently of
UI-specific BFF ranking. Both use the requesting actor's existing Ash policies;
there is no owner impersonation or new authentication mechanism. Browser-session
login is still required. The generated specification is `/api/ash/open_api`.

## Search stored messages

`GET /api/ash/chat-messages/search?q=hello`

Ash action: `IntellectualClub.Chat.ChatMessage :search` (read).

Arguments:

- `q`: required non-empty, case-insensitive literal substring.
  Surrounding whitespace is trimmed. `%` and `_` are literal text,
  not SQL wildcards. This is not semantic/vector or token-based full-text search.
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
- Matching is performed against individual stored text contents, not against the
  final concatenation: a query cannot span two content records.
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
Ash `Chat :search_list` and `ChatMessage :list_search_hit` actions for grouped
pages; the flat compatibility mode retains its bounded candidate selection and
ranking.

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
Handoff text is included as stored; this endpoint does not concatenate separate
handoff chats into one conversation.

Follow `next_offset` while `has_more` is true. Pagination is over the current
branch, not a snapshot: edits and branch switches between requests can change the
result. Output is bounded by message count, not bytes; large messages still return
full text. Branch traversal and fork-prefix validation may inspect more records
than the returned page.

## Shared implementation

`MessageText` owns text projection, substring matching and snippets. The Ash
`:search` action applies the matching predicate before database pagination. BFF
search reuses the same predicate and keeps only its presentation-specific
behavior (meta matches, active/inactive grouping and one preferred hit per chat).

Matching uses case-insensitive `ILIKE` against raw
`chat_message_contents.content_text`. The existing partial trigram GIN index is
on `content_text gin_trgm_ops`, with `kind = 'text'` and eligible `item_type`
predicates: `input`, `handoff_request`, `handoff_context`, `handoff_history`,
`handoff_message`, `answer`, and `handoff_summary`. Queries include those same
predicates and check the parent item's type as well. Reasoning and opaque
contents are not searchable even if they contain a matching `content_text`.
Search does not depend on a generated/lowercased search column, a composite
owner/text GIN index, or a new `btree_gin` migration. Ash authorization remains
in force; chat-list matching additionally restricts results to the actor's own
chats and messages.

## Chat list search

### Grouped cursor pages

`GET /api/bff/chat-list/search?q=...&sections=drafts,unread,working,other`
returns all requested sections in one response. `sections` is a comma-separated
subset of `drafts`, `unread`, `working`, and `other`. An empty list or unknown
section names return `422`. Drafts may overlap another section. The response
contains unique `chats`, ordered per-section `ids`, a `page` for each section,
`text_search`, and `next_read_state_expiry`.

Parameters:

- `q`: case-insensitive literal substring, with surrounding whitespace trimmed.
  `%`, `_`, and backslashes are literal characters, not SQL pattern syntax.
  A blank term returns empty sections.
- `bot`: optional bot id or `none` for chats without a bot.
- `per_page`: shared section page size, default 20, maximum 100.
- `page_<section>`: positive page number, default 1, used as a display label.
  It does **not** select an SQL offset or allow arbitrary page jumps.
- `after_<section>`: the opaque `next_cursor` from the preceding page of that
  section. A request with `page_<section> > 1` must include a valid cursor.

For example, a response for `sections=other&per_page=1` has this shape (the chat
summary is abbreviated):

```json
{
  "chats": [{"id": 123, "match_type": "active_message", "message_id": 456}],
  "sections": {
    "other": {
      "ids": [123],
      "page": {
        "number": 1,
        "per_page": 1,
        "total": null,
        "has_next": true,
        "next_cursor": "<opaque-signed-cursor>"
      }
    }
  },
  "text_search": true,
  "next_read_state_expiry": null
}
```

The next request keeps the same filters and page size, and adds
`page_other=2&after_other=<opaque-signed-cursor>`. Each section advances with its
own cursor. `total` is always `null`: grouped search does not compute an exact
count. `has_next` is determined by requesting `per_page + 1` candidate rows;
`next_cursor` is `null` when there is no next page, including empty results.
Only the visible `per_page` rows are enriched and returned.

Cursors are signed with `Phoenix.Token`, expire after 24 hours, and are scoped
to the actor, trimmed term, bot filter, section, and page size. Missing cursors
for later pages, invalid signatures, expired tokens, or scope mismatches return
`422` with `code: "invalid_cursor"`. Reset the cursor chain when filters or page
size change. Cursors are not a snapshot: concurrent edits, draft changes, and
read-state changes may alter section membership between requests.

Non-draft search sections use `(updated_at DESC, id DESC)` keyset ordering;
drafts use `(personal_draft_updated_at DESC, id DESC)`. The id breaks timestamp
ties. Section ordering is independent of the flat endpoint's match ranking.

### Matching, bounded reads, and deadlines

Message text is searched only when the term has three letters or digits in a
row (`text_search: true`). Shorter terms cannot narrow a trigram search and
match chat notes and bot names only (`text_search: false`). This threshold is
specific to chat-list search, not the public Ash message-search API.

Grouped candidate reads use the actor-authorized Ash `Chat :search_list` action
with section, hierarchy, bot, and cursor filters applied before the page limit.
For indexable terms, a short correlated `EXISTS` probe tries to stop after the
page fills, rather than collecting all global text matches first. Its budget is
`:chat_search_probe_timeout_ms` (default 250 ms); setting it to 0 disables the
probe. A probe statement timeout falls back to the ordinary indexed query over
raw text, preserving the same filters and order. Both plans return at most
`per_page + 1` candidates per section and do not count all matches. The indexed
fallback can inspect more rows inside PostgreSQL, but the application does not
load a global list of every matching chat or message.

After page selection, metadata matches use their first active-message preview.
For each other selected chat, Ash `ChatMessage :list_search_hit` reads at most
one matching message (`LIMIT 1`), preferring active-branch hits, then user hits,
then newer `(created_at, id)`. Snippets are loaded only for those selected hits,
not all matching messages or off-page chats. The response retains `match_type`,
`message_id`, `message_role`, `message_count`, and `snippet`.

`SearchDeadline.run` bounds the whole search and response enrichment with
`:chat_search_timeout_ms` (default 5,000 ms), including all requested sections,
fallback work, snippets, drafts, and summary construction. Exhaustion cancels
the worker and returns `503` with `code: "search_timeout"` and a localized
`error`, not partial sections. The existing
`:chat_search_statement_timeout_ms` (default 5,000 ms) remains an additional
per-SQL cap, bounded by the remaining overall budget. A successful fallback
need not expose the probe timeout to the client; exhausting the overall budget
or the fallback's SQL timeout does.

### Compatibility modes

- `GET /api/bff/chat-list/search?q=...&section=other&page=2&per_page=20`
  preserves the legacy singular `section` contract: offset pagination, `chats`,
  a top-level `page` with an **exact** `total`, and `next_read_state_expiry`.
  No cursor is required. The supported section names are the same as above.
  Exact counting remains subject to the overall deadline; new clients should
  use grouped cursor pages instead.
- Without `sections` or `section`, the endpoint keeps its flat response
  (`chats`) and returns up to `per_page` best matches. It retains the bounded
  message-candidate cap and ranking of metadata matches, active-message hits,
  then inactive-message hits; it is not exhaustive grouped pagination.
- The overall response budget and `503 search_timeout` apply to all three
  chat-list search modes.
