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
│  │  Resources + Policies    │      │ chunks in memory, batch write     │ │
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
Generation ─────► MDM (Ash)        : Context.build!/authorize (single boundary)
Generation ─────► Ecto (write)     : Persistence (batch writes)
Outlet ─────────► MDM (Ash)        : ToolInstance, OutletCall
Oban ───────────► MDM (Ash)        : scheduled jobs
```

### 1.3 Key principles

1. **Ash resources are the single source of truth** for the data model, validations, and access control.
2. **Public data access goes only through APIs**: `/api/ash` (generic AshJsonApi) and `/api/bff` (UX-oriented BFF). The BFF reads and writes only through Ash actions, so policies and validations always apply.
3. **Generation does not depend on Ash directly**. It only receives `Generation.Context` plus an explicit authorization check at startup.
4. **Provider stream and client stream are fundamentally decoupled**:
   - the LLM provider streams into the server through a provider abstraction
   - the browser receives progress through polling on the BFF API
   - one transport or provider must not dictate the format of the other
5. **The canonical trace boundary is at the provider edge**. Providers must normalize raw chunks into canonical events (`step` / `item` / `content`) so the rest of the code does not depend on provider-specific payload shapes.
6. **Chunks stay in memory, the database is updated at completion**. The worker accumulates the runtime trace in memory, and persistence does a batch write when a step or message is finalized.
7. **Polling-first streaming for the browser**:
   - for the runtime trace (the latest unfinished step), a full snapshot is preferred because structural deltas become complex and unstable when stream order is non-deterministic
   - old steps are never polled because they are immutable after finalization
8. **The SPA is served by Phoenix**. There is one build pipeline (`mix assets.*`) and one dev watcher flow, without a separate Vite dev server.
9. **Module calculations handle aggregates** and work the same way on SQLite and PostgreSQL.
10. **Oban is used for scheduling** as a DB-backed scheduler without Redis or Celery.

### 1.4 Generation streaming model (trace-only)

Generation is described by two streaming layers and one canonical data format.

1) **Provider -> Server (canonical events)**

- `llm_core` receives the raw provider stream (SSE / HTTP chunks) and converts it into a stream of canonical events.
- One **step** corresponds to one request to the model, that is, one provider call.
- A step contains many **items**, and an item contains many **content blocks**.
- Important: the order of provider events is not guaranteed to be deterministic. For example, reasoning and answer may stream in parallel.

2) **Server runtime state (accumulation)**

- `Generation.Worker` keeps in memory:
  - the **runtime trace**: the latest unfinished step in canonical form (`items` / `contents`)
- When the step or generation finishes, the worker performs **one** batch write to the database:
  - `chat_message_steps/items/contents` (canonical trace; the only source of truth for message body, history, and UI)
  - `chat_messages.token_count/status/error_detail` (message metadata)

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
