# Live-linked forks

New `fork` and `fork_background` chats inherit context by reference. Existing copied
forks are not migrated and keep their previous behavior.

## Storage and boundary

A linked child has private `fork_source_step_id` and `fork_task` attributes. Its
existing parent chat/message/tool-call references identify the selected invocation.
All message `parent_id` links remain local to their chat. Preparing a fork creates
one local root assistant message and its own first provider step, not copies of
historical messages, steps, items, usage or files.

The first provider request is built from the persisted source request/response.
It is saved normally as the child's actual request. This still serializes a request
payload and pins its request images; it does not duplicate the source trace.
Payload construction runs outside the short parent publication fence. Publishing
the child still checks generation/task authority, preserving cancellation safety.

`ForkHistory` projects the source branch up to the selected step, not the source's
current active leaf. The boundary includes the full completed provider response,
including all parallel tool calls. The selected call gets a synthetic fork-init
result; every other boundary call gets a skipped result. Real boundary tool
results, tool artifacts, later steering and later steps/messages are excluded.
The task is then appended as synthetic steering. These records are context only:
never persist or execute them. The boundary is virtually complete regardless of
the source message's subsequent completion/cancellation status.

## Live semantics and follow-ups

The inherited prefix is live, not a frozen snapshot. A later canonical follow-up
can observe edits to earlier source messages. Changing the parent's active branch
or continuing it cannot move the recorded cutoff. An already running provider
request is not rewritten by a later source edit.

Follow-ups append to the child's own local history; generation resolves inherited
context followed by the chosen local branch. The creating invocation continues to
reference its original root generation even after user follow-ups. Local edit,
retry, delete-message and branching operations are disabled in linked-fork UI/API;
new follow-ups, steering, cancellation and inspection remain available.

Background forks retain the existing generation-bound task lifecycle: finishing
or canceling the parent cancels its unfinished tasks. The parent must await their
status before finishing, or transfer them with a handoff. Linked storage does not
make these tasks detached jobs.

Nested forks recursively compose these prefixes. Reading checks every source
with the same actor, rejects cycles and limits inheritance to 32 sources. Sharing
a child does not implicitly share a private source. Missing or unreadable context
is reported as unavailable rather than silently continuing with a partial prefix.
Inherited file access is similarly restricted to media present in this projection;
it does not grant access to future results, sibling branches or all parent files.

## Source deletion and accounting

Deleting an anchor step (including source retry), its message or its chat removes
its linked descendants through Ash destroy actions. Legacy copied descendants are
detached, not removed. Runtime work is stopped after the outer transaction commits;
rollback must not cancel a surviving generation. Accounting ledger snapshots and
background-task envelopes survive with live foreign keys cleared where needed.
New child statistics count only the child's own actual provider steps.

Deletion and retry prepare one operation-wide plan. Explicit scopes distinguish
whole chats, message subtrees, single messages, keep-children reparenting, and
retry step ranges. Deleted records and surviving lock-only dependencies are separate;
a retry never walks or fences retained message descendants or unrelated fork chats.
Each of the three discovery passes uses frontier batches and visits each linked
node once. Initial chat fences use `FOR NO KEY UPDATE`, then affected message
fences precede steps, usage and task updates. Growth requiring an earlier lock
fails closed rather than acquiring locks out of order.

Nested destroys receive an explicit capability through plan-aware cascade changes.
It is valid only in the same process, transaction and lexical operation; it cannot
be reused after success, failure or rollback. The capability does not bypass Ash
permissions or local-history mutation restrictions. Ordinary relation cascades use
Ash's per-record callbacks even for bulk/JSON API callers, avoiding the Ash 3.29
batch-to-single notification adapter. Reference cleanup runs once,
using conditional atomic updates so accounting snapshots and surviving foreign
keys remain intact. Content and request-file destroy actions remain unchanged.

Retry preparation runs inside the lease transaction, after manager liveness RPCs
but before row locks, and passes its operation to persistence. There is no outer
row-lock transaction around Lease manager calls and no second plan in persistence.
Keep-children deletion prepares before its first reparent and reuses the plan for
the final destroy. All writes remain atomic, including nested rollback.

Only operations with runtime/upload cleanup capture their PostgreSQL xid8. The
supervised cleanup task waits for that exact outer transaction's committed/aborted
outcome before side effects; row absence is not a commit signal. This covers a root
created and deleted in one transaction and a delayed job after rollback followed by
a different deletion. Metadata queries are encapsulated in private authorized Ash
actions, with no schema change (PostgreSQL 14+). Waiting holds no row locks or open
transaction; ordinary finished-history deletion needs no outcome queries.

See [BFF and UI contract](linked-fork-bff.md) for the separate read-only inherited
context payload, revision updates and export behavior.

## Regression checks

Focused coverage lives in `fork_history_test.exs`, `linked_fork_cleanup_test.exs`,
`linked_fork_files_test.exs`, `linked_fork_cleanup_locks_concurrency_test.exs`,
`linked_fork_reparent_concurrency_test.exs`, `linked_fork_cleanup_plan_test.exs`,
`linked_fork_cleanup_operation_test.exs`, `linked_fork_cleanup_performance_test.exs`,
`linked_fork_cleanup_commit_test.exs`, `retry_cleanup_transaction_test.exs`,
`orphaned_recovery_test.exs` and
`chat_linked_fork_test.exs`, plus frontend view/export tests. It covers source edits,
branch switches, continuation, nested/cyclic/unavailable anchors, canonical provider
formats, attachments, cancellation, cleanup commit/rollback and legacy behavior.
