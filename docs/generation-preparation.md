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

`QueueCoordinator` remains responsible for active-generation exclusion, FIFO queue
state and queue-head changes. Lease/task fences still protect worker and subagent
publication. These frequently changing lifecycle checks are independent of content
freshness and must not be removed. Tool/secret access at execution time is a separate
concern; this change does not implement mid-cycle revocation of tool bindings.

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
