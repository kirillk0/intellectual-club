defmodule IntellectualClub.ToolsFixtures do
  @moduledoc """
  Fixtures for tool instances, tool functions and chat/bot tool bindings.
  """

  import IntellectualClub.Fixtures

  require Ash.Query

  alias IntellectualClub.Tools.{BotToolBinding, ChatToolBinding, ToolFunction, ToolInstance}

  @doc """
  Creates a tool instance. Defaults depend on `:type` (default `"mcp-http"`):

    * all types: a unique `name`, `config: %{}`, `secrets: %{}`;
    * `"mcp-http"`: `config: %{"server_url" => "https://example.com/mcp"}`,
      `secrets: %{"bearer_token" => "token"}`;
    * `"native-agent-management"`: `name: "Agent management"`,
      `alias: "agent_management"`, `description: ""`.

  Everything else (`:alias`, `:max_output_tokens`, `:rps_limit`, ...) falls
  back to the resource defaults unless given.
  """
  def create_tool_instance!(actor, attrs \\ %{}) do
    attrs = to_attrs(attrs)
    type = Map.get(attrs, :type, "mcp-http")

    defaults =
      %{type: type, name: unique_name("Tool"), config: %{}, secrets: %{}}
      |> Map.merge(type_defaults(type))

    create!(ToolInstance, Map.merge(defaults, attrs), actor)
  end

  defp type_defaults("mcp-http") do
    %{
      config: %{"server_url" => "https://example.com/mcp"},
      secrets: %{"bearer_token" => "token"}
    }
  end

  defp type_defaults("native-agent-management") do
    %{name: "Agent management", alias: "agent_management", description: ""}
  end

  defp type_defaults(_type), do: %{}

  @doc """
  Creates a function of `tool` (a tool instance or its id). Defaults:
  `name: "tool"`, `description: ""`, `parameters_schema: %{"type" => "object"}`,
  `enabled: true`, `discovered_at: DateTime.utc_now()`.
  """
  def create_tool_function!(actor, tool, attrs \\ %{}) do
    defaults = %{
      tool_instance_id: id_of(tool),
      name: "tool",
      description: "",
      parameters_schema: %{"type" => "object"},
      enabled: true,
      discovered_at: DateTime.utc_now()
    }

    create!(ToolFunction, merge_attrs(defaults, attrs), actor)
  end

  @doc "Binds `tool` to `chat`. Defaults: `enabled: true`, `sequence: 0`."
  def create_chat_tool_binding!(actor, chat, tool, attrs \\ %{}) do
    defaults = %{chat_id: chat.id, tool_instance_id: tool.id, enabled: true, sequence: 0}
    create!(ChatToolBinding, merge_attrs(defaults, attrs), actor)
  end

  @doc "Reads the tool bindings of `chat` (a record or an id) ordered by sequence."
  def chat_tool_bindings!(actor, chat) do
    chat_id = id_of(chat)

    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: actor)
  end

  @doc """
  Binds `tool` to `bot`. Defaults: `sharing_mode: :shared`, `enabled: true`,
  `sequence: 0`.
  """
  def create_bot_tool_binding!(actor, bot, tool, attrs \\ %{}) do
    defaults = %{
      bot_id: bot.id,
      tool_instance_id: tool.id,
      sharing_mode: :shared,
      enabled: true,
      sequence: 0
    }

    create!(BotToolBinding, merge_attrs(defaults, attrs), actor)
  end
end
