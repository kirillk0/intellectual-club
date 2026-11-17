# Lua tools

Lua is a fixed-function ToolInstance type for small, reviewable tools. It uses
[`tv-labs/lua`](https://github.com/tv-labs/lua), pinned to **1.0.2**, entirely on
BEAM. It is independent of outlet UI embedding: this release adds a settings
editor, not an application frontend or a general-purpose shell.

## Create a tool

In the tool catalog, select **Lua**. The initial source and manifest implement a
counter. Edit the source and manifest, save, then attach the tool to a bot or chat
in the usual way. Source syntax and the manifest are checked on save, but source
is **not executed** to discover functions or validate the configuration.

Configuration has exactly two fields: `source` and `manifest`. Source returns a
table of handlers, each called as `handler(args, ctx)`. Only functions explicitly
listed in the manifest are exposed to the agent. A function returns one
JSON-compatible value, or no value (`null`). Its tool response is
`{"result": ..., "logs": [...]}`. Helper functions stay private.

```lua
local exports = {}

function exports.increment(args, ctx)
  ctx.state.count = (ctx.state.count or 0) + (args.amount or 1)
  return {count = ctx.state.count}
end

return exports
```

```json
{
  "functions": [{
    "name": "increment",
    "description": "Increment this chat family's counter.",
    "input_schema": {
      "type": "object",
      "properties": {"amount": {"type": "integer", "default": 1}},
      "additionalProperties": false
    }
  }],
  "permissions": {"http": []}
}
```

Function names match `[a-zA-Z][a-zA-Z0-9_]{0,63}`. There must be 1–32 unique
exports. Descriptions are required. Arguments are validated before executing
source. Schemas support `type` (including type unions), `properties`, `required`,
`additionalProperties`, `items`, `minItems`, `maxItems`, `minLength`, `maxLength`,
`minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`,
`enum`, `const`, `anyOf`, `oneOf`, `allOf`, and annotations `description`, `title`,
`default`. Each argument schema must have root `type: "object"`. Defaults are
annotations, not injected values. References, regex keywords, boolean schemas,
and unknown keywords are rejected rather than silently ignored.

## State and JSON

`ctx.state` starts as `{}`. It is automatically persisted as one JSON object
only after a successful call and successful result/state validation. Replacing
`ctx.state` is allowed, provided it remains an object. `pcall`/`xpcall` preserve changes made before a
handled error; these changes commit if the exported handler ultimately succeeds.

The scope is **(ToolInstance, executing user, root chat)**. Subagent chats and
forks that inherit the same conversation root use the same state, not a
snapshot. A new root, another tool instance or another executing user gets
independent state. Tool owners cannot read the private state of users of their
shared tools. Host-derived execution context determines the scope; arguments
cannot select another user's or chat's state. State has no public API routes.
Deleting its tool, root chat or executing user removes the corresponding state.
Changing code does not reset state: use a `ctx.state.version` convention when
migrating your own data structure.

Same-scope calls are serialized with a PostgreSQL transaction-scoped advisory
lock, including concurrent first calls, across server processes/nodes. Different
scopes are independent. Lock waits are bounded and callbacks are never retried.
Secrets are authorized and loaded **before** opening this transaction; the Lua
worker never queries the database.

JSON uses UTF-8 strings and string object keys. Lua tables with consecutive
integer keys `1..n` become arrays; untagged empty tables become objects. Mixed
keys, holes, cycles, functions, non-JSON userdata, invalid UTF-8 and excessive
size/depth are errors. Metamethods are not invoked during serialization.

- `json.array()` / `json.array(table)` creates or marks an array, including `[]`.
- `json.object()` / `json.object(table)` creates or marks an object, including `{}`.
- `json.null` preserves explicit nulls inside tables; Lua `nil` removes a key.
- `json.encode(value)` returns JSON text; `json.decode(text)` preserves empty
  collections and nulls. JSON values entering through arguments, persisted state
  and HTTP responses carry the same collection tags.

## Standard library and helpers

No manifest permission is needed for normal data operations:

- Base functions: `assert`, `error`, `ipairs`, `next`, `pairs`, `pcall`, `xpcall`,
  `rawequal`, `rawget`, `rawset`, `rawlen`, `select`, `setmetatable`,
  `getmetatable`, `tonumber`, `tostring`, `type`, `unpack`.
- `math`, including `random` and `randomseed`; `string`, `table`, `utf8`.
- Read-only time helpers: `os.clock`, `os.date`, `os.difftime`, `os.time`,
  `os.time_ms`, `os.time_us`.
- `print(...)` collects bounded per-call logs instead of writing to server stdout.
- `seq.map(xs, f)`, `seq.filter(xs, f)`, `seq.reduce(xs, f, initial)`,
  `seq.find(xs, f)`, `seq.any(xs, f)`, `seq.all(xs, f)`. Callbacks receive
  `(value, index)`, or `(accumulator, value, index)` for reduce. Find returns
  `value, index`, or `nil`. Map/filter return JSON-tagged arrays.

`string.format`, `string.pack`, `string.gsub` and `table.concat` have additional
allocation guards around the interpreter implementations. Their normal signatures
are preserved; conservative preflights can reject large intermediate strings.

The allowlist is explicit. There is no `io`, `debug`, `package`, `require`,
`load`, `loadfile`, `dofile`, `collectgarbage`, environment access, process
execution, file access, or host application/Elixir object access. Every call gets
both a fresh Lua VM and a fresh BEAM process, including its random generator.

## A small deck

Use an empty object schema for `draw`, with `additionalProperties: false`.
The deck configuration can simply be a constant in the source; no custom UI is
required. This example deliberately does not expose reset/edit functions to the
agent.

```lua
local initial = {"Ace", "King", "Queen", "Jack"}

return {
  draw = function(args, ctx)
    if not ctx.state.cards then
      ctx.state.cards = seq.map(initial, function(card) return card end)
    end
    local cards = ctx.state.cards
    if #cards == 0 then return {empty = true} end
    local card = table.remove(cards, math.random(#cards))
    return {card = card, remaining = #cards}
  end
}
```

## HTTP and secrets

HTTP is denied by default. Add exact origins and allowed methods to the manifest:

```json
{
  "functions": [{
    "name": "summary",
    "description": "Fetch the configured report.",
    "input_schema": {"type": "object", "properties": {}, "additionalProperties": false}
  }],
  "permissions": {
    "http": [{
      "methods": ["GET"],
      "url": "https://api.example.com/v1/reports/*",
      "secrets": ["REPORT_TOKEN"]
    }]
  }
}
```

Attach a managed secret named `REPORT_TOKEN` on this ToolInstance's **Secrets**
tab. Lua cannot read its value; it can request injection by reference:

```lua
return {
  summary = function(args, ctx)
    local response = http.request({
      method = "GET",
      url = "https://api.example.com/v1/reports/latest",
      bearer_secret = "REPORT_TOKEN",
      query = {format = "compact"}
    })
    assert(response.status == 200, "Report service rejected the request")
    return response.json
  end
}
```

`http.request` accepts `method` (default GET), `url`, `headers`, `query`, `json`
or `body`, `bearer_secret`, and `secret_headers` (header name → attached secret
name). It returns `status`, `headers` (lowercase names → arrays), `body` (UTF-8
text) and `json` (decoded JSON, otherwise `json.null`). Network/policy failures
raise a catchable Lua error; HTTP error statuses remain responses.

A single matching rule must permit the method, URL and every requested secret.
`*` is allowed only in the path and can span `/`. Rules cannot contain host
wildcards, credentials, fragments or query strings; query parameters are **not**
restricted by the path rule. Put fixed recipients, SQL templates and other
application-level policy in the reviewed Lua source rather than agent arguments.

Only named environment-secret attachments of this ToolInstance are considered,
authorized as the executing user through existing sharing policies. Knowledge
block secrets, driver credentials and ambient server environment are excluded.
Actual values are never inserted into the Lua VM. Exact credential values are
redacted from upstream text/headers/JSON, but an upstream service intentionally
transforming credentials is outside this trust model. Do not put credentials in
source, a URL, the manifest or ordinary request headers.

Only public HTTP(S) destinations are supported in v1. All resolved addresses
must pass the public-address policy; the selected IP is pinned for the actual
connection while preserving Host, TLS SNI and certificate verification. Private,
loopback, link-local, metadata, special-use and IPv4-mapped IPv6 addresses are
blocked. Redirects, retries, environment proxies, compression and binary response
bodies are disabled/rejected. Ambiguous paths and transport-controlling headers
are rejected. There is no localhost/private-network escape hatch in a manifest.

## Failure semantics and limits

An error, timeout or worker termination does not commit changed state. **External
HTTP effects are not rolled back.** A request may have succeeded even if the
script later fails or the response is lost. There is no exactly-once guarantee;
use upstream idempotency keys for effects and do not blindly retry failed calls.

Defaults:

| Boundary | Default |
|---|---:|
| Source | 64 KiB |
| Argument schema | 64 KiB, depth 32 |
| Argument / result / state JSON | 256 KiB, depth 32, bounded element count |
| VM loop/call instruction budget | 200,000 |
| Lua call depth | 128 |
| Individual VM string allocation | 1 MiB |
| Worker lifetime, including HTTP | 10 seconds |
| Worker heap | 8,000,000 words, shared binaries counted at GC |
| Concurrent calls / workers | 16 per server node, 2 per user |
| HTTP calls per invocation | 8, including failures |
| HTTP request / response body | 256 KiB / 1 MiB |
| Printed logs | 8 KiB |
| State lock wait / transaction | 2 / 15 seconds |

The instruction counter does not cover all native-library or HTTP work. An
independent coordinator enforces wall time and caller-death cleanup. Whole-call
admission happens before database work, so state-lock waiters also count against
the concurrency limit. It waits for worker termination before returning or releasing capacity.
Heap limits are BEAM GC limits, **not a hard OS memory sandbox**. This protects
against ordinary mistakes in relatively trusted, user-installed scripts; it is
not intended to run sophisticated hostile programs. Cross-user data access is
still enforced by host-side authorization and state scoping.

Server operators can tune `:lua_tool_limits`, `:lua_tool_http`, and
`IntellectualClub.Tools.LuaState` application settings (see their modules).
Keep the state transaction timeout above the worker deadline plus lock/persistence
headroom. No Lua-supplied option can change host limits or HTTP transport options.
The driver is non-interruptible at the transaction boundary; the bounded worker
must finish/stop before the transaction is released.

## Implementation maintenance

`Codec`, `Host`, allocation guards and the runtime's chunk boundary use Lua VM table/raw execution APIs to
avoid lossy default table decoding and eager display traversal. This is why the
dependency is pinned. Review these adapters and run the complete Lua test suite
before changing the interpreter version. Standard-library additions are not
automatically admitted by a dependency update.
