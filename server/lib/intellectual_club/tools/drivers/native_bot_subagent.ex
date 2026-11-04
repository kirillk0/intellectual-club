defmodule IntellectualClub.Tools.Drivers.NativeBotSubagent do
  @moduledoc """
  Native bot subagent driver.

  Spawns linked subagent chats run by the bot selected in the tool instance
  configuration. The subagent uses that bot's prompt and tools. An explicit
  LLM configuration takes precedence over the bot's default and the calling
  generation's configuration.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Spawn, as: AgentSpawn
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Tools.Drivers.SubagentArguments
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ToolInstance

  @function_names ["spawn", "spawn_background"]

  @impl true
  def type, do: "native-bot-subagent"

  @impl true
  def title, do: "Bot Subagent"

  @impl true
  def description, do: "Runs a configured bot as a subagent in a linked chat."

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def supports_artifacts?, do: false

  @impl true
  def supports_handoff?, do: false

  @impl true
  def interruptible?, do: false

  @impl true
  def default_config do
    %{
      "nested_subchats_limit" => 0,
      "allow_handoff_in_subchats" => false
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "bot_id" => %{
          "type" => "integer",
          "minimum" => 1,
          "title" => "Bot",
          "description" => "Bot whose prompt and tools run the subagent.",
          "x-ui" => %{"widget" => "bot-select", "order" => 0}
        },
        "llm_configuration_id" => %{
          "type" => "integer",
          "minimum" => 1,
          "title" => "Configuration",
          "description" =>
            "Overrides the bot's default configuration for this tool. Leave empty to use the usual configuration selection.",
          "x-ui" => %{"widget" => "llm-configuration-select", "order" => 1}
        },
        "nested_subchats_limit" => %{
          "type" => "integer",
          "minimum" => 0,
          "default" => 0,
          "title" => "Nested subchats limit",
          "description" =>
            "How many additional subchats a subagent may create. " <>
              "0 disables spawning this bot inside subchats."
        },
        "allow_handoff_in_subchats" => %{
          "type" => "boolean",
          "default" => false,
          "title" => "Allow handoff in subchats",
          "description" => "Allow subagents to compact context and continue work."
        }
      },
      "required" => ["bot_id"],
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema, do: nil

  @impl true
  def normalize_config(config) when is_map(config) do
    config = Map.new(config, fn {key, value} -> {to_string(key), value} end)

    config
    |> normalize_id("bot_id")
    |> normalize_llm_configuration_id()
    |> Map.put(
      "nested_subchats_limit",
      non_negative_integer(Map.get(config, "nested_subchats_limit"), 0)
    )
    |> Map.put(
      "allow_handoff_in_subchats",
      Map.get(config, "allow_handoff_in_subchats") in [true, "true", "1", 1]
    )
  end

  def normalize_config(_config), do: normalize_config(%{})

  @impl true
  def validate_config(%ToolInstance{} = tool_instance, config, actor) when is_map(config) do
    actor = owner_actor(tool_instance, actor)

    with :ok <- validate_bot_id(Map.get(config, "bot_id"), actor) do
      validate_llm_configuration_id(Map.get(config, "llm_configuration_id"), actor)
    end
  end

  def validate_config(_tool_instance, _config, _actor), do: :ok

  defp validate_bot_id(bot_id, actor) do
    case bot_id do
      nil ->
        # The required-field check reports a missing bot.
        :ok

      bot_id when is_integer(bot_id) and bot_id > 0 ->
        case Ash.get(Bot, bot_id, actor: actor) do
          {:ok, %Bot{}} -> :ok
          _other -> {:error, "Bot is not available."}
        end

      _other ->
        {:error, "Bot must be a positive integer."}
    end
  end

  defp validate_llm_configuration_id(nil, _actor), do: :ok

  defp validate_llm_configuration_id(id, actor) when is_integer(id) and id > 0 do
    case Ash.get(LlmConfiguration, id, actor: actor) do
      {:ok, %LlmConfiguration{}} -> :ok
      _other -> {:error, "Configuration is invalid or not accessible."}
    end
  end

  defp validate_llm_configuration_id(_id, _actor),
    do: {:error, "Configuration is invalid or not accessible."}

  @impl true
  def fixed_functions(%ToolInstance{} = _tool_instance) do
    [
      %{
        "name" => "spawn",
        "description" =>
          "Start a linked subagent chat run by the configured bot with its own prompt and " <>
            "tools, using the selected configuration and no copied conversation history, and wait for it " <>
            "to finish.",
        "schema" => spawn_schema(),
        "enabled" => true,
        "enabled_by_default" => true
      },
      %{
        "name" => "spawn_background",
        "description" =>
          "Start a linked subagent chat run by the configured bot without waiting for it " <>
            "to finish. Save the returned background task id and check it explicitly.",
        "schema" => spawn_schema(),
        "is_background_function" => true,
        "enabled" => false,
        "enabled_by_default" => false
      }
    ]
  end

  @impl true
  def unavailable_functions(%ToolInstance{} = tool_instance, chat, actor) do
    tool_instance
    |> Subagent.unavailable_functions(chat, actor)
    |> Enum.filter(&(&1 in @function_names))
  end

  @impl true
  def spawn_target(%ToolInstance{config: config} = tool_instance) do
    case configured_bot_id(tool_instance) do
      bot_id when is_integer(bot_id) ->
        case Map.get(config, "llm_configuration_id") do
          nil -> {:bot, bot_id}
          id -> {:bot, bot_id, id}
        end

      nil ->
        {:error, "Bot subagent tool has no bot configured."}
    end
  end

  @impl true
  def discover(%ToolInstance{} = _tool_instance) do
    {:error, "Discovery is not supported for this tool type."}
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, "spawn", args, %ExecutionContext{} = context)
      when is_map(args) do
    with {:ok, brief, prompt} <- SubagentArguments.parse(args, "spawn"),
         {:ok, actor} <- required_actor(context),
         {:ok, result} <- AgentSpawn.create_and_run(tool_instance, brief, prompt, context, actor) do
      {:ok, result}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "spawn", _args, _context) do
    {:error, "Spawn requires generation execution context."}
  end

  def execute(
        %ToolInstance{} = tool_instance,
        "spawn_background",
        args,
        %ExecutionContext{} = context
      )
      when is_map(args) do
    with {:ok, brief, prompt} <- SubagentArguments.parse(args, "spawn"),
         :ok <- Subagent.preflight_creation_allowed(tool_instance, context),
         {:ok, result} <- BackgroundTasks.start_spawn(tool_instance, brief, prompt, context) do
      {:ok, result}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "spawn_background", _args, _context) do
    {:error, "Background spawn requires generation execution context."}
  end

  def execute(%ToolInstance{} = _tool_instance, function_name, _args, _context)
      when is_binary(function_name) do
    {:error, "Unknown function: #{function_name}"}
  end

  @doc "Returns the bot id configured on the tool instance, if valid."
  @spec configured_bot_id(ToolInstance.t()) :: pos_integer() | nil
  def configured_bot_id(%ToolInstance{config: config}) when is_map(config) do
    case positive_integer(Map.get(config, "bot_id") || Map.get(config, :bot_id)) do
      {:ok, bot_id} -> bot_id
      :error -> nil
    end
  end

  def configured_bot_id(_tool_instance), do: nil

  defp spawn_schema do
    SubagentArguments.schema("First user message sent to the spawned bot subagent.")
  end

  defp normalize_id(config, key) do
    case positive_integer(Map.get(config, key)) do
      {:ok, id} -> Map.put(config, key, id)
      :error -> config
    end
  end

  defp normalize_llm_configuration_id(config) do
    key = "llm_configuration_id"
    value = Map.get(config, key)

    if is_nil(value) or (is_binary(value) and String.trim(value) == "") do
      Map.delete(config, key)
    else
      normalize_id(config, key)
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> :error
    end
  end

  defp positive_integer(_value), do: :error

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> default
    end
  end

  defp non_negative_integer(_value, default), do: default

  defp owner_actor(%ToolInstance{owner_id: owner_id}, _fallback) when is_integer(owner_id) do
    %User{id: owner_id}
  end

  defp owner_actor(_tool_instance, %{id: id} = actor) when is_integer(id), do: actor
  defp owner_actor(_tool_instance, _fallback), do: nil

  defp required_actor(%ExecutionContext{owner_id: owner_id})
       when is_integer(owner_id) and owner_id > 0,
       do: {:ok, %User{id: owner_id}}

  defp required_actor(_context), do: {:error, "owner_id is required"}

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
