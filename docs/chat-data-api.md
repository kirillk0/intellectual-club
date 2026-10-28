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
`for_read` if overriding the default. Internal BFF callers opt out of pagination
with `page: false` and retain their bounded candidate selection/ranking.

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
search invokes that action and keeps only its presentation-specific behavior
(meta matches, active/inactive grouping and one preferred hit per chat). No new
search index or data migration is required; matching uses the existing trigram
index on eligible text contents.
