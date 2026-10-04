# History modes

Bots choose the history sent at the start of a generation:

| Mode | Included history |
| --- | --- |
| `agent` (default, also for No bot) | User messages, steering, answers, tool calls and results |
| `chat` | User messages, steering and visible answers, including handoff summaries |
| `full` | Agent history plus reusable reasoning from messages with the current configuration ID |

Configuration compatibility means equality of non-null `llm_configuration_id` values.
Provider and model names are not compatibility signals. Editing a configuration
does not change its identity. Switching A → B → A restores eligibility of reasoning
from A. Missing or deleted configurations never qualify.

`Generation.History.for_mode/3` filters canonical history before role-boundary
repair. Chat mode omits tool items and synthetic interruption markers. Existing
completion and linked-fork boundaries still apply. The selected mode does not
change the trace stored in the database, ongoing tool rounds, or saved-request retries.

The context panel uses the latest provider usage for agent/full. Chat mode shows
an estimate of the visible dialogue (including steering) plus prompt blocks.

Reasoning replay reads only opaque contents of eligible reasoning items. Historical
raw responses are never loaded or parsed for replay. Old reasoning without reusable
opaque content is omitted; it is not reconstructed from displayed text.

All reasoning-producing adapters save opaque content regardless of history mode:

- Responses HTTP/WSS: native reasoning items, including encrypted content.
- Google Interactions: native thought steps under `google_interaction_step`.
- Anthropic Messages: each native thinking/redacted-thinking block under
  `anthropic_content_block`, preserving block order and signatures.
- OpenRouter and NVIDIA Chat Completions: original `reasoning_details`, `reasoning`
  and `reasoning_content` fields under `chat_completion_reasoning`.

Opaque-only reasoning is retained even when there is no visible text. The demo
adapter does not produce reasoning. Adapters project their own native payloads;
visible answers continue to come from canonical contents so edits are respected.

The introduction migration changes the database default to `agent` and converts
existing `chat` values to `agent`, preserving their previous effective behavior.
