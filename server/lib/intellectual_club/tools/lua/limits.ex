defmodule IntellectualClub.Tools.Lua.Limits do
  @moduledoc false

  @defaults [
    timeout_ms: 10_000,
    max_instructions: 200_000,
    max_call_depth: 128,
    max_string_bytes: 1_048_576,
    heap_words: 8_000_000,
    max_concurrent: 16,
    max_per_user: 2,
    json_bytes: 262_144,
    json_depth: 32,
    json_nodes: 32_768,
    log_bytes: 8_192,
    http_calls: 8
  ]

  def heap_limit,
    do: %{size: get(:heap_words), kill: true, error_logger: false, include_shared_binaries: true}

  def get(key),
    do:
      Keyword.get(
        Application.get_env(:intellectual_club, :lua_tool_limits, []),
        key,
        Keyword.fetch!(@defaults, key)
      )
end
