defmodule IntellectualClub.Tools.Drivers.NativeAgentManagement do
  @moduledoc """
  Native agent management driver.

  This fixed-function tool exposes chat-level orchestration operations that an
  agent may invoke during generation.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  @impl true
  def type, do: "native-agent-management"

  @impl true
  def title, do: "Agent Management"

  @impl true
  def description, do: "Native tools for continuing agent work across chats."

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def supports_artifacts?, do: false

  @impl true
  def supports_handoff?, do: true

  @impl true
  def default_config, do: %{}

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{},
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema, do: nil

  @impl true
  def fixed_functions(%ToolInstance{} = _tool_instance) do
    [
      %{
        "name" => "handoff",
        "description" =>
          "Continue work in a new chat, especially when context is approaching its limit. " <>
            "The summary must be sufficient for the new chat to continue without the old context.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "summary" => %{
              "type" => "string",
              "description" =>
                "Continuation prompt with the goal, current state, decisions, constraints, " <>
                  "touched files or tools, blockers, and next steps."
            }
          },
          "required" => ["summary"],
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "sleep",
        "description" =>
          "Pause agent execution for the requested number of seconds before continuing. " <>
            "Use this when waiting for time to pass.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "seconds" => %{
              "type" => "number",
              "description" =>
                "Non-negative pause duration in seconds. Fractional seconds are allowed.",
              "minimum" => 0
            }
          },
          "required" => ["seconds"],
          "additionalProperties" => false
        },
        "enabled" => true
      }
    ]
  end

  @impl true
  def discover(%ToolInstance{} = _tool_instance) do
    {:error, "Discovery is not supported for this tool type."}
  end

  @impl true
  def execute(%ToolInstance{} = _tool_instance, "handoff", args, %ExecutionContext{} = context)
      when is_map(args) do
    with {:ok, summary} <- required_summary(args),
         {:ok, owner_id} <- required_integer(context.owner_id, "owner_id"),
         {:ok, chat_id} <- required_integer(context.chat_id, "chat_id"),
         {:ok, assistant_message_id} <-
           required_integer(context.assistant_message_id || context.message_id, "message_id"),
         actor = %User{id: owner_id},
         {:ok, result} <-
           Handoff.create_handoff_chat(chat_id, actor, summary,
             source_message_id: assistant_message_id,
             handoff_mode: :tool,
             start_generation?: true
           ) do
      chat = result.chat
      message = result.message
      generation = result.generation
      generation_message_id = if is_map(generation), do: Map.get(generation, :message_id)

      payload = %{
        "chat_id" => chat.id,
        "message_id" => message.id,
        "generation_message_id" => generation_message_id,
        "url" => "/chats/#{chat.id}"
      }

      {:ok,
       %ExecutionResult{
         text: "Generation continued in chat /chats/#{chat.id}.",
         raw: %{"handoff" => payload},
         media: [],
         artifacts: []
       }}
    else
      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "handoff", _args, _context) do
    {:error, "Handoff requires generation execution context."}
  end

  def execute(%ToolInstance{} = _tool_instance, "sleep", args, context) when is_map(args) do
    with {:ok, seconds, timeout_ms} <- read_sleep_seconds(args) do
      {elapsed_ms, remaining_ms} = sleep_timing(timeout_ms, context)

      Process.sleep(remaining_ms)

      {:ok,
       %ExecutionResult{
         text: "Paused for #{format_seconds(seconds)}.",
         raw: %{
           "sleep" => %{
             "seconds" => seconds,
             "milliseconds" => timeout_ms,
             "elapsed_milliseconds" => elapsed_ms,
             "remaining_milliseconds" => remaining_ms
           }
         },
         media: [],
         artifacts: []
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "sleep", _args, _context) do
    {:error, "Sleep arguments must be an object."}
  end

  def execute(%ToolInstance{} = _tool_instance, function_name, _args, _context)
      when is_binary(function_name) do
    {:error, "Unknown function: #{function_name}"}
  end

  defp required_summary(args) when is_map(args) do
    args
    |> Map.get("summary", Map.get(args, :summary, ""))
    |> to_string()
    |> String.trim()
    |> case do
      "" -> {:error, "summary is required"}
      summary -> {:ok, summary}
    end
  end

  defp required_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp required_integer(_value, field), do: {:error, "#{field} is required"}

  defp read_sleep_seconds(args) when is_map(args) do
    case Map.get(args, "seconds", Map.get(args, :seconds)) do
      value when is_integer(value) and value >= 0 ->
        {:ok, value, value * 1000}

      value when is_float(value) and value >= 0 ->
        milliseconds = value |> Kernel.*(1000) |> Float.ceil() |> trunc()
        {:ok, value, milliseconds}

      _other ->
        {:error, "Argument `seconds` must be a non-negative number."}
    end
  end

  defp sleep_timing(timeout_ms, %ExecutionContext{tool_call_created_at: %DateTime{} = started_at})
       when is_integer(timeout_ms) and timeout_ms >= 0 do
    elapsed_ms =
      DateTime.utc_now()
      |> DateTime.diff(started_at, :millisecond)
      |> clamp_milliseconds(0, timeout_ms)

    {elapsed_ms, max(timeout_ms - elapsed_ms, 0)}
  end

  defp sleep_timing(timeout_ms, _context) when is_integer(timeout_ms) and timeout_ms >= 0 do
    {0, timeout_ms}
  end

  defp clamp_milliseconds(value, min_value, max_value) when is_integer(value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp format_seconds(seconds) when is_integer(seconds), do: "#{seconds} seconds"

  defp format_seconds(seconds) when is_float(seconds) do
    "#{:erlang.float_to_binary(seconds, [:compact, decimals: 6])} seconds"
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
