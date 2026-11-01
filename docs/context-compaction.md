# Context compaction

Handoffs compact context within the current chat. There is no continuation-chat
relation, navigation or runtime recovery transition. A one-time migration joins
safe, unbranched historical chains and leaves ambiguous cases as standalone chats.

## Tool handoff

`native-agent-management.handoff` must still be called alone and obeys the
subagent lineage policy. Its successful tool result requests compaction rather
than completing the generation. The worker:

1. Builds a rolloff from the original selected branch, including persisted work
   in the running assistant message and the authorized linked-fork prefix.
2. Atomically attaches a `handoff_history` / `handoff_message` pair to the source
   tool step and publishes its next provider request with full request encoding.
3. Continues the same message with its pinned model, system prompt and tools.

The message remains generating; background tasks, steering and queued follow-ups
keep their message anchor. There is no intermediate completion notification.
Tool/refusal round counters restart at the checkpoint, as they did in a new
handoff generation; accumulated usage and costs do not reset. The provider
session is restarted so a remote response prefix cannot reintroduce old context.
Pending and already committed after-response steering reach the next request
verbatim. Pending queue entries are stored once in the receiving step; committed
steering stays on its original step. The history projection carries it across the
checkpoint without creating a second UI entry. Steering injection uses the fresh
compacted request snapshot, including its history length and cache boundaries.

Rolloff is computed once per transition, outside the bounded queue-conflict retry.
A retry rebuilds only the receiving request and transactional publication.

Publication is fenced. Archive ownership, checkpoint items and the successor
request commit together. Lost acknowledgements are resolved by reading that
transition, not by publishing a second checkpoint. Saved-request retry and orphan
recovery retain the normal step request contract.

An explicit preparation refusal, such as unavailable linked-fork context, becomes
a durable tool error instead of ending the generation. The worker replaces the
unpublished compaction receipt and uses the ordinary tool follow-up with the
pinned request. No checkpoint or archive is published; existing context, steering
and queued work remain available. Recovery reads the same refusal rather than
replaying a successful compaction receipt. Database failures, unexpected exceptions
and publication failures retain the normal persistence/recovery error handling;
they are not treated as recoverable tool refusals.

## Manual compaction

The UI command generates a `handoff_summary` after a `handoff_request`, then
appends a user-role checkpoint message in the same chat. It does not automatically
start an assistant answer unless queued work is waiting. Completion is idempotent
and does not steal an independently selected sibling branch. The next turn uses
the chat's current configuration.

## Context versus archive

`History.after_compaction/1` operates on the already selected branch before
completion/history-mode filtering. It projects the latest complete adjacent
checkpoint pair as a completed user trace and retains only the later suffix.
It includes both items and their media, not just the summary item. The virtual
checkpoint has its own identity and points to its original message; the assistant
suffix retains the original message ID. A fork's boundary excludes checkpoint
items written after its provider response.

Every checkpoint includes `full_conversation.md`, attached as media to its
`handoff_history` item. This is a cumulative snapshot of original dialogue,
steering and artifact references, not a dump of reasoning or tool results.
Earlier checkpoint copies are not recursively added to subsequent archives.

The complete supplied summary is stored and readable. The model-facing rolloff
retains the existing 20,000-token budget and truncation strategies, including
last-resort truncation of an oversized summary. Only the latest checkpoint's
archive is automatically announced in new model context; older files remain
available in their original trace subject to ordinary file authorization.

## Presentation

Each checkpoint is a separate collapsed block at its step position, including
its summary, history and attachments. Its files are excluded from the ordinary
bottom-of-message attachment list. Full text and media remain inspectable, and
exports retain the chronological checkpoint sections. Ordinary assistant editing
leaves checkpoint contents and archives unchanged.

There is no new history-search function or general working-file classification.
The existing Artifact Reader can read/search the snapshot when bound to the chat.

## Historical data migration

`20261101120000_merge_legacy_handoff_families` retires the old relation in a single
transaction. It is self-contained and does not call the removed runtime APIs.
Back up the database before upgrading. The migration runs automatically with
the release and never fails or cancels work because of busy chats: a family
with active generations, steps, pending queues or background tasks is logged
with the blocking IDs and left as separate chats. To merge as many historical
chains as possible, let that work finish on the old version before upgrading.

A whole connected family is merged only when:

- The chat graph is one rooted, same-owner chain, with no multiple continuations,
  cycles or missing anchors.
- In each member the selected path from the leaf (`last_message_id`) to a message
  root is simple and stays inside the chat; each continuation points to the
  previous member's final message. Side branches from edits and regenerations
  and additional message roots are allowed and move along unchanged.
- Each child begins with a supported user checkpoint/summary.
- Tool and knowledge bindings, ACLs and inherited tool policy agree; drafts,
  uploads and snooze state introduce no conflicting data.

Bot, configuration and note differences do not block a merge: as after an
ordinary in-chat change, the terminal chat's bot and configuration win, and the
note is the terminal chat's note or, when that is empty, the latest note still
present in the chain. Pinned per-message configurations are unchanged.

A real fork/spawn root and off-chain fork/spawn children are supported. The oldest
chat survives, takes the final leaf and terminal settings, and keeps its genuine
subagent ancestry. Messages are moved, not copied; child roots are attached to
the preceding source messages. Message, step, item, content and file IDs stay
unchanged. Old single-item summaries gain an empty `handoff_history` item before
the original summary item. Historical runs remain separate assistant messages.
Provider requests (full or patch), hashes and responses remain byte-for-byte
unchanged. The old `<continued in new chat>` history placeholder, which is
rendered into later prompts and the UI rather than stored in any provider
payload, becomes readable text. Usage, completed queue rows, uploads, child-chat
links and operational background-task references move with the messages. The
merged chat keeps the newest member's `updated_at`; detached chats keep their own.
Read state is combined by per-chat unread semantics rather than comparing
unrelated revision counters.

Empty draft rows are revision tombstones, not merge conflicts. For each user, at
most one nonempty draft across the family is allowed. Its text and timestamp (or
the latest empty tombstone timestamp) are retained on the root chat, with a
revision greater than every source revision so stale clients cannot overwrite or
resurrect drafts. Multiple nonempty drafts for the same user, or a revision that
cannot be safely advanced, leave the whole family unmerged and all drafts intact.

Any family that fails these checks is left entirely unmerged. Its handoff links
are cleared, its former continuation chats become visible independent chats,
and obsolete `handoff_context` items become ordinary input. Existing checkpoint
pairs and files remain readable; a detached chat no longer reads files of its
former parent chat. There is no legacy redirect or continuation navigation: old
URLs of successfully merged child chats are not preserved, and historical tool
prose/results may still contain those URLs.

The migration can be retried safely but cannot be reversed by `down`; restore the
backup to return to the old structure. A following generated migration rebuilds
the text-search index without the retired item type.
