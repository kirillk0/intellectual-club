# Intellectual Club System Design

## 1. Architecture

### 1.1 High-level diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              Phoenix Application                         │
│                                                                          │
│  ┌──────────────────────────┐      ┌───────────────────────────────────┐ │
│  │      MDM Subsystem       │◄────►│       Generation Subsystem        │ │
│  │      (Ash Domain)        │      │ (GenServer workers + persistence) │ │
│  │  Resources + Policies    │      │ Ash-staged durable generation     │ │
│  └──────────────────────────┘      └───────────────────────────────────┘ │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                           Web / API Layer                          │  │
│  │  - `/api/ash/*` : AshJsonApi (generic JSON:API over Ash resources)│  │
│  │  - `/api/bff/*` : BFF endpoints for SPA (chat-centric, aggregated) │  │
│  │  - Session auth (AshAuthentication) + CSRF                         │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                            SPA Frontend                            │  │
│  │  Vue 3 + TypeScript (Vite build), served by Phoenix                │  │
│  │  - `/` `/chats/*` (and later `/catalogs/*`)                        │  │
│  │  - Streaming via polling to `/api/bff/.../poll`                    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────┐      ┌───────────────────────────────────┐ │
│  │     Outlet Subsystem     │      │        Scheduling (Oban)          │ │
│  │ (Phoenix Controllers/API)│      │   DB-backed, SQLite + PostgreSQL  │ │
│  └──────────────────────────┘      └───────────────────────────────────┘ │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Subsystem dependencies

```
SPA ───────────► BFF (Controllers) : aggregated endpoints, start/cancel/poll generation
SPA ───────────► AshJsonApi        : generic CRUD (JSON:API)
BFF ───────────► MDM (Ash)         : Ash.read!/Ash.get!/Ash.create!/Ash.update!/Ash.destroy! (policies apply)
BFF ───────────► Generation        : start/cancel/poll via Supervisor
Generation ─────► MDM (Ash)        : Context.build!/authorize and durable persistence actions
Generation ─────► Ash transactions : staged provider/tool/message commits
Outlet ─────────► MDM (Ash)        : ToolInstance, OutletCall
```

### 1.3 Key principles

1. **Ash resources are the single source of truth** for the data model, validations, and access control.
2. **Public data access goes only through APIs**: `/api/ash` (generic AshJsonApi) and `/api/bff` (UX-oriented BFF). The BFF reads and writes only through Ash actions, so policies and validations always apply.
3. **Provider stream and client stream are fundamentally decoupled**:
   - the LLM provider streams into the server through a provider abstraction
   - the browser receives progress through polling on the BFF API
   - one transport or provider must not dictate the format of the other
4. **The canonical trace boundary is at the provider edge**. Providers must normalize raw chunks into canonical events (`step` / `item` / `content`) so the rest of the code does not depend on provider-specific payload shapes.
5. **Partial chunks are UI-only; durable rows are authoritative after provider completion**. The worker accumulates partial provider chunks in memory only to keep the UI responsive. Once the provider response completes, `Generation.Persistence` commits the provider step through Ash; persisted `chat_message_items` and raw provider output become the source of truth for tool execution, recovery, history, and finalization.
6. **Polling-first streaming for the browser**:
   - for the runtime trace (the latest unfinished step), a full snapshot is preferred because structural deltas become complex and unstable when stream order is non-deterministic
   - old steps are never polled because they are immutable after finalization
7. **The SPA is served by Phoenix**. There is one build pipeline (`mix assets.*`) and one dev watcher flow, without a separate Vite dev server.
8. **Module calculations handle aggregates** and work the same way on SQLite and PostgreSQL.

### 1.4 Generation streaming model (trace-only)

Generation is described by two streaming layers and one canonical data format.

1) **Provider -> Server (canonical events)**

- `llm_core` receives the raw provider stream (SSE / HTTP chunks) and converts it into a stream of canonical events.
- One **step** corresponds to one request to the model, that is, one provider call.
- A step contains many **items**, and an item contains many **content blocks**.
- Important: the order of provider events is not guaranteed to be deterministic. For example, reasoning and answer may stream in parallel.

2) **Server runtime state and durable persistence**

- `Generation.Worker` keeps in memory:
  - the **runtime trace**: the latest unfinished provider stream in canonical form (`items` / `contents`)
- This runtime trace is not used for system decisions after `response_complete`; it is a UI cache for the latest partial step.
- Persistence is staged through Ash actions and Ash transactions:
  - `waiting_provider`: a step row is created before the provider call starts.
  - `provider complete`: the provider step, raw response, and provider items are committed together. This committed snapshot replaces stale item/content rows for the step.
  - `waiting_tools`: tools are selected only from persisted `tool_call` items. Tool results are committed one at a time as persisted `tool_result` items.
  - `done` / `error` / `canceled`: final step and message metadata are committed after the provider/tool stage is durable.
- If recovery finds a message in `waiting_tools`, it resumes from persisted calls/results and executes only calls that do not already have a linked result. If recovery finds `waiting_provider`, the unfinished provider attempt is rolled back and retried.
- `tool_result` items link to their canonical `tool_call` item through `tool_call_item_id`; provider `call_id` remains stored in opaque JSON for provider-wire payloads and legacy fallback only.

3) **Server -> Client (polling)**

- The client polls the BFF endpoint and receives:
  - the **runtime trace snapshot** (the full latest step; the UI renders the bubble from `input` / `answer` items and compactly displays the remaining item types)
- The client **must not** poll historical steps because they are already finalized and immutable.

Consequence: fields such as `reasoning_deltas` or `content_deltas` are only special cases and must not be the foundation of the protocol. The UI is built from the canonical runtime trace snapshot.

---

## 2. Technology stack

| Layer | Technology | Rationale |
|------|------------|-----------|
| Language | Elixir | BEAM VM: lightweight processes, fault tolerance, hot code reload |
| Web framework | Phoenix 1.8+ | Router/Controllers/Plug, serves SPA + APIs, sessions/CSRF |
| Domain framework | Ash 3.16+ | Declarative resources, policies, auto CRUD |
| API (generic) | AshJsonApi | Standard JSON:API over Ash resources |
| API (BFF) | Phoenix Controllers | UX-oriented endpoints still backed by Ash actions |
| Frontend | Vue 3 + TypeScript SPA | decoupled from server rendering |
| Frontend build | Vite (build-only) | Outputs to `priv/static`, Phoenix serves in dev and prod |
| Streaming (browser) | HTTP polling | Predictable UX, mobile-friendly, reconnect via snapshots |
| Database (desktop) | SQLite via AshSqlite | Zero-config, single file |
| Database (server) | PostgreSQL via AshPostgres | Concurrent access, production workloads |
| Background jobs | Oban | DB-backed scheduler, supports SQLite + PostgreSQL, no Redis |
| HTTP client | Req / Finch | LLM provider streaming, tool execution |
| Auth | ash_authentication | Session-based auth, local-mode auto-login |
| Token counting | Custom heuristic | `ceil(byte_size(text) / 3.5)` is good enough for rough estimates |
| Release | `mix release` | Single binary distribution |
