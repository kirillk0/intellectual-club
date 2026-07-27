defmodule IntellectualClub.Tools.Drivers.NativeAgentManagement do
  @moduledoc """
  Native agent management driver.

  This fixed-function tool exposes chat-level orchestration operations that an
  agent may invoke during generation.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Chat.Fork, as: AgentFork
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Spawn, as: AgentSpawn
  alias IntellectualClub.Chat.Subagent
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
        "nested_subchats_limit" => %{
          "type" => "integer",
          "minimum" => 0,
          "default" => 0,
          "title" => "Nested subchats limit",
          "description" =>
            "How many additional subchats a subagent may create. " <>
              "0 disables fork and spawn inside subchats."
        },
        "allow_handoff_in_subchats" => %{
          "type" => "boolean",
          "default" => false,
          "title" => "Allow handoff in subchats",
          "description" => "Allow subagents to continue work through handoff chats."
        }
      },
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
        "enabled" => true,
        "enabled_by_default" => true
      },
      %{
        "name" => "fork",
        "description" =>
          "IMPORTANT: isolated delegation, not a continuation. Call this tool by itself to " <>
            "delegate exactly one task and wait for the answer. The current model state and " <>
            "full conversation are copied into a new branch, where the copied model becomes " <>
            "the subagent. In that branch it must discard every pending intention from the " <>
            "parent turn, including plans and tool calls before or after this fork; perform " <>
            "only the task argument; write one final answer; and stop. It must not continue " <>
            "the parent agent's task. The parent alone continues the original work, using the " <>
            "subagent's final answer, which becomes this tool call's result.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "task" => %{
              "type" => "string",
              "description" =>
                "Complete instructions for the only task the copied subagent must perform. " <>
                  "When this task appears in the copied branch, abandon the parent turn's plan, " <>
                  "complete only these instructions, answer once, and stop."
            }
          },
          "required" => ["task"],
          "additionalProperties" => false
        },
        "enabled" => false,
        "enabled_by_default" => false
      },
      %{
        "name" => "fork_background",
        "description" =>
          "IMPORTANT: isolated delegation, not a continuation. Call this tool by itself to " <>
            "delegate exactly one task without waiting for the answer. The current model state " <>
            "and full conversation are copied into a new branch, where the copied model becomes " <>
            "the subagent. In that branch it must discard every pending intention from the " <>
            "parent turn, including plans and tool calls before or after this fork; perform " <>
            "only the task argument; write one final answer; and stop. It must not continue the " <>
            "parent agent's task. The parent alone continues the original work. This call " <>
            "returns a background task id; check it to retrieve the subagent's final answer.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "task" => %{
              "type" => "string",
              "description" =>
                "Complete instructions for the only task the copied subagent must perform. " <>
                  "When this task appears in the copied branch, abandon the parent turn's plan, " <>
                  "complete only these instructions, answer once, and stop."
            }
          },
          "required" => ["task"],
          "additionalProperties" => false
        },
        "is_background_function" => true,
        "enabled" => false,
        "enabled_by_default" => false
      },
      %{
        "name" => "spawn",
        "description" =>
          "Start a linked subagent chat with the same bot and chat settings but no copied " <>
            "conversation history, and wait for it to finish.",
        "schema" => spawn_schema(),
        "enabled" => false,
        "enabled_by_default" => false
      },
      %{
        "name" => "spawn_background",
        "description" =>
          "Start a linked subagent chat with an empty conversation without waiting for it to " <>
            "finish. Save the returned background task id and check it explicitly.",
        "schema" => spawn_schema(),
        "is_background_function" => true,
        "enabled" => false,
        "enabled_by_default" => false
      },
      %{
        "name" => "check_background_task_status",
        "description" =>
          "Check a background task and return only new progress since the optional cursor.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "background_task_id" => %{
              "type" => "string",
              "format" => "uuid",
              "description" => "Background task id returned by a background tool."
            },
            "cursor" => %{
              "type" => "string",
              "description" => "Opaque cursor returned by the previous status check."
            }
          },
          "required" => ["background_task_id"],
          "additionalProperties" => false
        },
        "provides_background_task_status" => true,
        "enabled" => false,
        "enabled_by_default" => false
      },
      %{
        "name" => "cancel_background_task",
        "description" => "Cancel a background task owned by the current user.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "background_task_id" => %{
              "type" => "string",
              "format" => "uuid",
              "description" => "Background task id returned by a background tool."
            }
          },
          "required" => ["background_task_id"],
          "additionalProperties" => false
        },
        "enabled" => false,
        "enabled_by_default" => false
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
        "enabled" => true,
        "enabled_by_default" => true
      }
    ]
  end

  @impl true
  def discover(%ToolInstance{} = _tool_instance) do
    {:error, "Discovery is not supported for this tool type."}
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, "handoff", args, %ExecutionContext{} = context)
      when is_map(args) do
    with {:ok, summary} <- required_summary(args),
         :ok <- Subagent.ensure_handoff_allowed(tool_instance, context),
         {:ok, owner_id} <- required_integer(context.owner_id, "owner_id"),
         {:ok, chat_id} <- required_integer(context.chat_id, "chat_id"),
         {:ok, assistant_message_id} <-
           required_integer(context.assistant_message_id || context.message_id, "message_id"),
         {:ok, tool_call_item_id} <-
           required_integer(context.tool_call_item_id, "tool_call_item_id"),
         actor = %User{id: owner_id},
         {:ok, result} <-
           Subagent.with_parent_generation_fence(context, fn ->
             Handoff.create_handoff_chat(chat_id, actor, summary,
               source_message_id: assistant_message_id,
               parent_tool_call_item_id: tool_call_item_id,
               handoff_mode: :tool,
               start_generation?: false
             )
           end) do
      chat = result.chat
      message = result.message

      payload = %{
        "chat_id" => chat.id,
        "message_id" => message.id,
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

  def execute(%ToolInstance{} = tool_instance, "fork", args, %ExecutionContext{} = context)
      when is_map(args) do
    with {:ok, task} <- required_task(args),
         {:ok, owner_id} <- required_integer(context.owner_id, "owner_id"),
         actor = %User{id: owner_id},
         {:ok, result} <- AgentFork.create_and_run(tool_instance, task, context, actor) do
      {:ok, result}
    else
      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "fork", _args, _context) do
    {:error, "Fork requires generation execution context."}
  end

  def execute(
        %ToolInstance{} = tool_instance,
        "fork_background",
        args,
        %ExecutionContext{} = context
      )
      when is_map(args) do
    with {:ok, task} <- required_task(args),
         :ok <- Subagent.preflight_creation_allowed(tool_instance, context),
         {:ok, result} <- BackgroundTasks.start_fork(tool_instance, task, context) do
      {:ok, result}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "fork_background", _args, _context) do
    {:error, "Background fork requires generation execution context."}
  end

  def execute(%ToolInstance{} = tool_instance, "spawn", args, %ExecutionContext{} = context)
      when is_map(args) do
    with {:ok, brief, prompt} <- required_spawn_args(args),
         {:ok, owner_id} <- required_integer(context.owner_id, "owner_id"),
         actor = %User{id: owner_id},
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
    with {:ok, brief, prompt} <- required_spawn_args(args),
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

  def execute(
        %ToolInstance{} = _tool_instance,
        "check_background_task_status",
        args,
        %ExecutionContext{} = context
      )
      when is_map(args) do
    with {:ok, task_id} <- required_background_task_id(args),
         {:ok, cursor} <- optional_background_cursor(args),
         {:ok, owner_id} <- required_integer(context.owner_id, "owner_id"),
         {:ok, snapshot} <- BackgroundTasks.snapshot(task_id, cursor, owner_id) do
      {:ok, background_snapshot_result(snapshot, "check", cursor)}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def execute(
        %ToolInstance{} = _tool_instance,
        "check_background_task_status",
        _args,
        _context
      ) do
    {:error, "Background task status requires generation execution context."}
  end

  def execute(
        %ToolInstance{} = _tool_instance,
        "cancel_background_task",
        args,
        %ExecutionContext{} = context
      )
      when is_map(args) do
    with {:ok, task_id} <- required_background_task_id(args),
         {:ok, owner_id} <- required_integer(context.owner_id, "owner_id"),
         {:ok, snapshot} <- BackgroundTasks.cancel(task_id, owner_id) do
      {:ok, background_snapshot_result(snapshot, "cancel", nil)}
    else
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "cancel_background_task", _args, _context) do
    {:error, "Background task cancellation requires generation execution context."}
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
    |> Map.get("summary", "")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> {:error, "summary is required"}
      summary -> {:ok, summary}
    end
  end

  defp required_task(args) when is_map(args) do
    args
    |> Map.get("task", "")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> {:error, "task is required"}
      task -> {:ok, task}
    end
  end

  defp required_spawn_args(args) when is_map(args) do
    with :ok <- reject_extra_spawn_args(args),
         {:ok, brief} <- required_trimmed_string(args, "brief"),
         {:ok, prompt} <- required_trimmed_string(args, "prompt") do
      {:ok, brief, prompt}
    end
  end

  defp required_trimmed_string(args, key) when is_map(args) and is_binary(key) do
    case Map.get(args, key) do
      nil ->
        {:error, "#{key} is required"}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "#{key} is required"}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, "#{key} must be a string"}
    end
  end

  defp reject_extra_spawn_args(args) when is_map(args) do
    extras = Map.keys(args) -- ["brief", "prompt"]

    case extras do
      [] -> :ok
      _other -> {:error, "spawn arguments contain unsupported fields"}
    end
  end

  defp spawn_schema do
    %{
      "type" => "object",
      "properties" => %{
        "brief" => %{
          "type" => "string",
          "description" => "Short task description stored as the new chat note."
        },
        "prompt" => %{
          "type" => "string",
          "description" => "First user message sent to the spawned subagent."
        }
      },
      "required" => ["brief", "prompt"],
      "additionalProperties" => false
    }
  end

  defp required_background_task_id(args) when is_map(args) do
    args
    |> Map.get("background_task_id", "")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> {:error, "background_task_id is required"}
      task_id -> {:ok, task_id}
    end
  end

  defp optional_background_cursor(args) when is_map(args) do
    case Map.get(args, "cursor") do
      nil -> {:ok, nil}
      cursor when is_binary(cursor) -> {:ok, cursor}
      _other -> {:error, "cursor must be a string"}
    end
  end

  defp required_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp required_integer(_value, field), do: {:error, "#{field} is required"}

  defp read_sleep_seconds(args) when is_map(args) do
    case Map.get(args, "seconds") do
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

  defp background_snapshot_result(snapshot, operation, requested_cursor)
       when is_map(snapshot) and operation in ["check", "cancel"] do
    snapshot =
      snapshot
      |> stringify_json()
      |> Map.put_new("status_detail", nil)
      |> Map.put_new("progress", [])
      |> Map.put_new("result", nil)
      |> Map.put_new("error", nil)

    media = get_in(snapshot, ["result", "media"]) || []
    artifacts = get_in(snapshot, ["result", "artifacts"]) || []

    request = %{
      "operation" => operation,
      "cursor" => requested_cursor
    }

    model_snapshot =
      Map.take(snapshot, [
        "background_task_id",
        "kind",
        "status",
        "cancel_requested",
        "target_chat_id",
        "status_detail",
        "url",
        "progress",
        "next_cursor",
        "result",
        "error",
        "created_at",
        "started_at",
        "finished_at",
        "updated_at"
      ])

    text =
      "If this response is truncated, do not advance `next_cursor`; repeat the status check " <>
        "with the same cursor (or omit it again if it was omitted).\n\n" <>
        "Background task snapshot:\n" <> Jason.encode!(model_snapshot, pretty: true)

    ExecutionResult.normalize(%ExecutionResult{
      text: text,
      raw: %{"background_task" => snapshot, "background_task_request" => request},
      media: List.wrap(media),
      artifacts: List.wrap(artifacts)
    })
  end

  defp stringify_json(%{} = value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_json(nested)} end)
  end

  defp stringify_json(value) when is_list(value), do: Enum.map(value, &stringify_json/1)
  defp stringify_json(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify_json(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_json(value), do: value

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
