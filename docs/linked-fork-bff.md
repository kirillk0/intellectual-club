# Linked fork presentation contract

New linked forks are identified by a non-null `Chat.fork_task`. Legacy forks with a
null task retain their existing behavior. The child physically stores only its own
messages; the SPA must never insert inherited messages into the local `branch`.

## State and refresh

`GET /api/bff/chat-state/:id` returns:

- `chat.history_read_only`: history mutations are disabled for new linked forks.
  This is independent of `chat.can_edit`: owners can still send/queue follow-ups,
  steer/cancel a running generation, inspect local steps, and export.
- `fork_context`: `null` for legacy chats, otherwise
  `{status, live: true, read_only: true, revision, task, message_count, step_count}`.
  Status is `available` or `unavailable`. The live state does not copy inherited
  messages: the parent relation banner already links to the source conversation.
- `fork_context.task`: the child's own `fork_task`. It is stored on the child, so
  it is returned even when the inherited prefix is unavailable. The UI renders it
  as the first, action-less user-style message of the fork.
- `fork_context.message_count` / `step_count`: size of the projected prefix,
  including nested ancestors. Steps count assistant provider steps only, up to and
  including the fork anchor. Both are `null` for an unavailable prefix, which
  carries no exception details.

`ChatForkContext` calls `ForkHistory.prefix(chat, actor)` and summarizes only its
already projected `steps/items/contents`. It must **not** use
`ChatBranchPayload.branch/4`, reload source steps, or expose raw provider payloads:
that would discard the projection cutoff.

The full state `idle_revision` and idle endpoint revision combine the normal local
revision with the same metadata-only inherited token. Idle probes do not call
`ForkHistory.prefix`, load text/provider payloads, or serialize the presentation.
The inherited token includes readable source lineage and the anchored branch's
record identities, structure and content versions. It catches content-only edits,
deletions and replacements, not just changes to a maximum message timestamp.
Later source messages/steps, active-leaf changes and excluded boundary tool results,
artifacts, errors and post-response steering do not invalidate it. Included source
edits and loss/restoration of source access do. Nested sources contribute recursively;
cycles and missing boundaries fail closed. This is an opaque change token, not a
content hash; harmless included metadata changes may conservatively invalidate it.

The full state reads the inherited token **before** loading the presentation. A
source edit racing that load therefore cannot label old content with a new token
and suppress the following refresh. Every source remains actor-authorized; the
metadata aggregate lives in a private Ash resource without new storage or migrations.
Unexpected metadata or full-prefix read/serialization failures are logged as
warnings and use a retry token that changes once per minute: stale content or an
unavailable presentation is never acknowledged indefinitely, but a persistent
failure does not force a full state reload on every idle probe either. Stable
missing/unreadable sources retain stable unavailable tokens.

## Access and files

Ordinary actor access is required for every source in the chain. Sharing only a
child does not grant broader source access: its prefix is unavailable. There is no
owner impersonation or scoped source-access resolver.

The live UI does not render inherited content, and exports disable source and
attachment URLs. When `ChatForkContext.serialize_messages/4` is called with links
enabled, source links are emitted for the source owner only and projected media
uses the existing authenticated
`/api/bff/chat-messages/:source_message_id/contents/:content_id/file` endpoint.
That endpoint independently verifies actor access and message/content membership.
No new file-grant endpoint or child-local content ID is introduced. Missing file
metadata renders a placeholder. The fork task is the child's own text and is
rendered with the ordinary sanitized chat Markdown renderer, without attachment
reference resolution.

## History mutations

BFF message update/delete/retry-last-step/retry-from-step and chat branch
switch/activate/move-to-new-chat/branch-to-new-chat return HTTP 403 with
`code: "fork_history_read_only"` for linked children. Explicit send/generate
`parent_id` values are allowed only at the current local leaf; ordinary follow-up
send/generate remains available. Parent conversations and legacy children are not
restricted by the presence of descendants. Queue editing/cancellation and local
bookmarks are not history mutations.

Frontend `historyReadonly` controls history actions only. Composer, queue,
settings, inspection, and export continue to use the ordinary ownership/access
flags. Inherited context has its own component and never participates in branch
navigation, polling, counters, or bookmarks.

## Export

Each exported chat has a separate `fork_context` field. Exporting a selected linked
fork does not automatically expand to the full source conversation or future
source steps: the selected linked fork is the export root. Because the export has
no live links, its `fork_context` additionally contains `messages`: presentation-only
entries with `key`, `role`, optional source chat/message references and
`source_url`, and an ordered `content` list of text `parts` and attachment
descriptors. Entries have no local message ID, generation status, usage, bookmarks,
or working-step IDs; synthetic fork results and steering are context, not live tool
activity. An unavailable prefix exports an empty list. HTML shows the summary with
the prefix collapsed and labelled as a read-only snapshot of live context, and the
task as the first message. Source and attachment URLs are disabled;
attachment metadata is retained as placeholders. Exporting ordinary parents keeps
the pre-existing family-export behavior.

## Additional API boundaries

Direct Ash JSON:API message deletion and chat branch/activate/switch/continue
actions enforce the same linked-history restriction. Direct user-message creation
locks the chat and permits only an append at its current leaf. Settings-only chat
copy remains available; independent continuation via history copying is disabled
for linked forks. Their source references cannot be repointed through chat update.

A child's actual provider request contains inherited history. Raw-request inspection
therefore also requires readable inherited context; sharing only the child does not
expose the request. Its own raw response retains normal child-chat read access.
