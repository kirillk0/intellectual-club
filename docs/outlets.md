# Outlet Architecture and Protocol

This document describes the outlet subsystem at the architecture and protocol level.
It intentionally does not specify any particular runner implementation, UI, language, or
packaging format.

## Purpose

An outlet is a tool transport that lets the server execute tool calls outside the
server process, usually on a user-controlled machine or in a separate runtime
environment.

The server owns chats, tool definitions, permissions, and call orchestration. The
runner owns local execution of a provider-specific tool surface and communicates with
the server over authenticated HTTP polling.

At a high level:

1. A user creates or pairs an outlet tool instance on the server.
2. The server gives the runner a secret token for that tool instance.
3. The runner repeatedly polls the server for pending calls.
4. The server assigns calls to the active runner session.
5. The runner executes calls locally and posts completions back to the server.

## Core Entities

### Outlet Tool Instance

An outlet tool instance is the server-side resource that represents one remote tool
surface. It stores the outlet configuration and a secret token used by runners to
authenticate.

The token identifies the tool instance. All runtime presence, pending calls, running
calls, and poll waiters are tracked per outlet tool instance.

### Runner

A runner is the remote process that polls for work and executes calls. Protocol-wise,
a runner has two identities:

- `runner_id`: stable identity of the logical runner.
- `runner_session_id`: identity of one concrete process lifetime.

These ids deliberately have different lifetimes and must not be collapsed into one
field.

### Runner ID

`runner_id` identifies the logical runner installation or profile. It should remain
stable across process restarts for the same configured connection.

Examples of what `runner_id` represents:

- the same local outlet profile after app restart;
- the same daemon configured with the same token;
- the same user-approved runner installation.

`runner_id` is used to distinguish a restart of the same logical runner from a second,
different runner trying to use the same outlet token.

If an implementation cannot persist `runner_id`, every process start looks like a
different logical runner. That makes restart handling worse and can cause avoidable
`Runner already active` conflicts.

### Runner Session ID

`runner_session_id` identifies one concrete runner process lifetime. It must be new
for each process start.

The session id exists so the server can tell old in-flight work from work claimed by a
new process after restart. It is used for:

- binding claimed tasks to the session that received them;
- validating completions from the session that executed the call;
- recalculating capacity for a session with already running calls;
- running automatic discovery once per fresh session;
- failing or ignoring stale work when a session is replaced.

`runner_session_id` must not be made stable across restarts. If it is reused, the
server cannot reliably distinguish an old process from a new one, and stale
completions may be mixed with current work.

## Authentication

The runner authenticates each outlet API request with the outlet token. The token is
the authority to use a specific outlet tool instance.

The token is not a runner identity. Multiple processes can know the same token, so the
server still needs `runner_id` and `runner_session_id` to manage presence and
single-runner semantics.

## Metadata Protocol

The runner may fetch server-owned outlet metadata with `GET /api/outlet/metadata/`.
This endpoint is authenticated with the same outlet token as the runtime protocol.

The metadata endpoint is intentionally separate from the poll loop. It is meant for
setup, startup refresh, profile display, and future low-frequency metadata needs. A
runner should not depend on metadata being returned from `/api/outlet/poll/`.

The response includes the outlet tool instance identity and display name:

```json
{
  "status": "ok",
  "metadata": {
    "tool_instance": {
      "id": 123,
      "type": "outlet",
      "name": "Shell Outlet"
    }
  }
}
```

The response must not expose secrets, owner data, or live runner metadata.

## Poll Protocol

The runner polls the server for work with a payload containing:

- `runner_id`;
- `runner_session_id`;
- available `capacity`;
- requested long-poll wait time;
- runner metadata.

On each successful poll, the server updates runner presence for the outlet tool
instance and may return tasks. Each returned task contains:

- `call_id`;
- function name;
- arguments.

If no task is immediately available and the runner has capacity, the server may hold
the request as a long poll. A later server-side tool call can then be delivered by
replying to that pending poll.

There is at most one pending poll waiter per outlet tool instance. A newer poll
replaces the previous waiter and the previous waiter receives an idle response.

## Complete Protocol

After executing a task, the runner posts a completion with:

- `runner_id`;
- `runner_session_id`;
- `call_id`;
- completion status;
- result payload, media, artifacts, and/or error text;
- runner metadata.

The server uses `call_id` to find the running call and uses the runner/session ids to
keep the runtime state coherent. A completion for a missing call is treated as stale
or already resolved and is not applied to another call.

## Server Runtime State

The outlet runtime is in-memory runtime state for active transport. Durable data such
as tool instances and pairing records lives in the normal server data model, but
pending and running outlet calls are runtime state.

For each outlet tool instance, the runtime tracks:

- current runner presence;
- pending calls waiting to be assigned;
- running calls already claimed by a runner session;
- call waiters waiting for results;
- at most one poll waiter;
- the last session that received automatic discovery.

Because calls are runtime state, server restart loses pending/running transport state.
The durable chat/tool state remains the source of truth for higher-level recovery.

## Presence and Single-Runner Policy

The server treats a runner as online while its last successful poll or completion is
within the configured runner online timeout.

The protocol is single-active-runner per outlet tool instance:

- the same `runner_id` and same `runner_session_id` is the current session and may
  continue polling;
- the same `runner_id` with a new `runner_session_id` represents a restart of the same
  logical runner;
- a different `runner_id` while the current runner is online represents another
  logical runner trying to use the same token and should be rejected with
  `Runner already active`;
- when the current runner is offline, a new runner/session may replace it.

When a session is replaced, running calls from the previous session must not be allowed
to complete into the new session. The server should fail or drop those calls and let
the higher-level orchestration decide whether to retry.

## `Runner already active`

`Runner already active` means "another logical runner is already using this outlet
tool instance". It should protect an outlet token from being used by two independent
runners at the same time.

It should not mean "the same logical runner restarted and now has a fresh
`runner_session_id`". That case is a session replacement problem, not a competing
runner problem.

The distinction is only possible when `runner_id` is stable:

- same `runner_id`, new `runner_session_id`: restart or process replacement;
- different `runner_id`: competing logical runner.

If `runner_id` is random on every start, the server must treat each restart as a
possible competing runner and may return `Runner already active` until the previous
session ages out.

## Restart Semantics

A clean restart should create a new `runner_session_id` and reuse the same
`runner_id`.

This gives the server enough information to handle the restart safely:

- stable `runner_id` says "this is the same configured runner";
- new `runner_session_id` says "work claimed by the old process should not be trusted
  as current session work";
- stale completions from the old session can be ignored or rejected by call/session
  ownership rules.

If the runner instead generates a new `runner_id` on each start, the server cannot
tell whether this is a restart or a second runner using the same token. During the
online timeout window it should conservatively return `Runner already active`.

If the runner reuses `runner_session_id` across starts, the server cannot distinguish
old and new process lifetimes. That breaks the reason `runner_session_id` exists.

## Capacity and Task Ownership

The runner reports available capacity on each poll. The server assigns up to that many
pending calls and marks them running for the polling `runner_id` and
`runner_session_id`.

Capacity is evaluated against calls already running for the same session so repeated
polls from a busy runner do not over-assign work.

Task ownership belongs to the session that claimed the task. A later session must not
implicitly inherit running calls from an older session.

## Automatic Discovery

The server may schedule an internal discovery call so it can reconcile the function
surface exposed by the runner.

Discovery is session-scoped. A fresh `runner_session_id` can trigger discovery because
a new process may have a different executable, environment, permissions, or tool
surface. Repeating discovery for every heartbeat of the same session is unnecessary.

## Pairing

Pairing is the setup flow that creates or updates an outlet tool instance and gives
the runner its token. Pairing is separate from the poll/complete runtime protocol.

The runtime protocol starts after the runner has a token. From that point on, the token
selects the outlet tool instance, while `runner_id` and `runner_session_id` describe
the runner process using that token.

## Protocol Invariants

- `runner_id` is stable for the same logical runner.
- `runner_session_id` is fresh for each process lifetime.
- A token authorizes access to one outlet tool instance; it is not enough to identify a
  specific runner process.
- Running calls are owned by the session that claimed them.
- Stale completions must not be applied to unrelated calls or newer sessions.
- A different logical runner using the same token while another runner is online must
  be rejected.
- Long polling is an optimization for delivery latency; correctness must not depend on
  a poll request staying open.
