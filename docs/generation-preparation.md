# Generation request preparation

`Generation.Context.prepare/2` builds an authorized, read-only request draft before
acquiring the chat publication lock. It does not create messages, steps or image
pins. It reads content and settings once, best-effort, using the ordinary Ash read
path; it does not promise a transaction-wide snapshot of database or external
inputs. There is no history/settings digest and no repeated metadata walk.

Concurrent edits to historical text, knowledge blocks, tool bindings, provider or
model settings may affect this request or a later request. Once prepared, a draft
is not invalidated merely because those inputs changed. Publication uses the draft's
request and runtime settings, subject to normal provider/request finalization.
Bindings and history are still resolved through their authorized relationships;
this is not permission to include unrelated context.

## Publication boundary

`publish!/2` locks the owned chat and checks:

- the same actor, chat and selected parent identify the draft;
- the active leaf still equals the leaf observed at preparation;
- the pending user contents and other publication intent still match the draft;
- a non-null selected parent still exists and belongs to this chat.

The expected active leaf is separate from the selected parent, which may explicitly
refer to an earlier message. A changed leaf rejects the draft even in that case.
Normal repeated publication is rejected after the first publication advances the leaf.
No historical items/contents, prompt blocks or tool definitions are reread to validate
freshness. Branch-state conflicts may retry preparation, then use the protected path.

`QueueCoordinator` remains responsible for excluding unfinished ancestors on the
selected branch, FIFO queue state and queue-head changes. Lease/task fences still protect worker and subagent
publication. These frequently changing lifecycle checks are independent of content
freshness and must not be removed. Tool/secret access at execution time is a separate
concern; this change does not implement mid-cycle revocation of tool bindings.

## Parallel branches

Independent branches of one chat may generate concurrently, including sibling
answers to the same user message with different models. Admission rejects a
continuation whose selected parent or ancestor is still generating, not an
unrelated generation elsewhere in the chat. Explicit `parent_id: null` selects
an empty history. Callbacks that create or select a parent are checked again
inside the publication transaction, and rejection rolls back their mutations.

Worker registration, distributed ownership and durable lease/fence tokens remain
exclusive per message. Short chat/message transaction locks still protect shared
metadata; no worker reserves the whole chat for the duration of a provider call.
Prepared starts and retries do not cancel neighboring generations. Retry rejects
active ancestors or descendants rather than mutating a running branch. Cancellation
of a message includes only its own subagent lineage; explicit chat-wide
cancellation still stops all generations of that chat.

The active leaf and configuration remain chat settings. Each started generation
retains its pinned configuration and request. The queue remains one chat-wide
FIFO: a nonempty queue still prevents a direct start, switching its anchor pauses
it with `branch_changed`, and Send next explicitly reanchors it to the selected
branch. A generating sibling does not block delivery on that selected branch.
Handoff transfers only follow-ups anchored to its source message and steering
addressed to that generation.

## Fallbacks and subchats

Existing spawn and linked-fork chats can use ordinary preparation, including tools
whose prompt context has dynamic dependencies. Linked-fork source edits after
preparation do not force a rebuild of the already collected inherited prefix.

Calls already inside a transaction use protected construction directly: an inner
preparation cannot release its caller's locks. The first spawn therefore continues
to create its chat, copied bindings, prompt and generation together. The first fork
retains its specialized source-request preparation before the parent publication
fence. Pending media and native request images retain their protected fallback so
image publication side effects remain inside the existing safe boundary.

## Pinned configuration

A generation pins the chat configuration observed at preparation: the assistant
message stores its `llm_configuration_id`, and the step request stores the model,
parameters and system prompt. The chat configuration selector may change while the
generation runs; the new selection applies to the next message only.

Retry and orphan recovery resolve the configuration from the message (the chat
configuration is only a fallback when the message has none or it is unreadable) and
derive prompt-block file and secret grants from that same configuration. Work
derived from a running turn — spawn and fork subagent chats and tool handoff
targets — inherits the turn's configuration (`Chat.GenerationConfiguration`).
Manual handoff targets and queued follow-ups wait for the next user message and
therefore follow the current chat selection.

## Branch options

`POST /api/bff/chat-generation/:id/branch` (in-chat) and
`POST /api/bff/chat-generation/:id/branch-to-new-chat` accept the selected
`message_id`, replacement contents for user messages, an optional
`llm_configuration_id` and `start_generation` (default `true`). A user message gets
a replacement sibling; an assistant message is regenerated from its parent.

For a new chat the configuration becomes the target chat configuration; the source
chat is untouched. In-chat, the configuration is written to the chat under the
same chat lock and branch-generation/queue admission as the direct generation it
precedes, so a rejected branch leaves no partial change. With
`start_generation: false` the branch only moves the active leaf (the replacement
user message or the assistant's parent) through
`QueueCoordinator.run_direct_mutation/3`, and the response carries
`generation: null`; the composer Continue action starts the generation later.

New attachments of a branch message follow the configuration the branch is sent
with. `POST /api/bff/chat-uploads/:chat_id` accepts the same optional
`llm_configuration_id` so a file can be staged for a configuration the chat does
not use yet, and every consumer of staged uploads (send, queue, edit, branches)
revalidates them against its own upload policy when they are materialized; the
policy at upload start may be stale. Copied existing attachments are not
revalidated: providers already degrade unsupported history media.

The SPA exposes these options only in the user-message branch dialog; the dialog's
attach button, accepted types and client validation use the selected
configuration, and files added under a more permissive selection block saving. Branching
from an assistant response stays a one-click action without options: in-chat it
regenerates through `generate` with the response's parent, and to a new chat it
uses the current chat configuration and starts immediately.
