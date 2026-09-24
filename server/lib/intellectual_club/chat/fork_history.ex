defmodule IntellectualClub.Chat.ForkHistory do
  @moduledoc """
  Reads the live, virtual history preceding a linked fork's local messages.

  Every chat, anchor and trace is read through Ash as the supplied actor, including
  when the caller supplies a loaded chat. Reading a shared child does not grant
  access to a private source: callers must have read access to every source too.
  No owner impersonation or authorization bypass is used here.

  Sources are followed to the anchored step's message, never their current leaf.
  At most 32 linked sources are followed, and cycles fail closed. Projected records
  and their synthetic items are context only: never persist or execute them.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ForkBoundary
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Generation.ToolCall

  require Ash.Query

  @max_depth 32
  @unavailable {:error, :fork_context_unavailable}

  @spec prefix(Chat.t() | integer(), map()) :: {:ok, [ChatMessage.t()]} | {:error, term()}
  def prefix(chat_or_id, actor) do
    with {:ok, chat} <- readable_chat(chat_or_id, actor) do
      inherited_prefix(chat, actor, MapSet.new(), 0)
    end
  end

  @doc """
  Prepends the inherited prefix to a local branch. A nil target returns only the
  prefix, allowing the first local assistant message to start from inherited context.
  Options are passed to `Threads.branch_to_message/4` for loading local messages.
  """
  @spec effective_branch(Chat.t() | integer(), integer() | nil, map(), keyword()) ::
          {:ok, [ChatMessage.t()]} | {:error, term()}
  def effective_branch(chat_or_id, target_message_id, actor, opts \\ []) do
    with {:ok, chat} <- readable_chat(chat_or_id, actor),
         {:ok, inherited} <- inherited_prefix(chat, actor, MapSet.new(), 0),
         {:ok, local} <- local_branch(chat, target_message_id, actor, opts) do
      {:ok, inherited ++ local}
    end
  end

  defp readable_chat(%Chat{id: id}, actor), do: readable_chat(id, actor)

  defp readable_chat(id, %{id: actor_id} = actor)
       when is_integer(id) and is_integer(actor_id) do
    read_one(Chat, id, actor)
  end

  defp readable_chat(_chat, _actor), do: @unavailable

  defp read_one(resource, id, actor) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: actor, authorize?: true)
    |> case do
      {:ok, nil} -> @unavailable
      {:error, %Ash.Error.Forbidden{}} -> @unavailable
      other -> other
    end
  end

  defp inherited_prefix(chat, actor, visited, depth) do
    cond do
      MapSet.member?(visited, chat.id) ->
        @unavailable

      is_nil(Map.get(chat, :fork_source_step_id)) ->
        if is_nil(Map.get(chat, :fork_task)), do: {:ok, []}, else: @unavailable

      depth >= @max_depth ->
        @unavailable

      true ->
        linked_prefix(chat, actor, MapSet.put(visited, chat.id), depth)
    end
  end

  defp linked_prefix(chat, actor, visited, depth) do
    with step_id when is_integer(step_id) <- Map.get(chat, :fork_source_step_id),
         call_id when is_integer(call_id) <- chat.parent_tool_call_item_id,
         task when is_binary(task) <- Map.get(chat, :fork_task),
         {:ok, source} <- readable_chat(chat.parent_chat_id, actor),
         {:ok, anchor} <- read_one(ChatMessageStep, step_id, actor),
         true <- anchor.chat_message_id == chat.parent_message_id,
         {:ok, branch} <- source_branch(source, anchor.chat_message_id, actor),
         {:ok, projected} <- project_branch(branch, source.id, step_id, call_id, task),
         {:ok, ancestors} <- inherited_prefix(source, actor, visited, depth + 1) do
      {:ok, ancestors ++ projected}
    else
      {:error, _reason} = error -> error
      _other -> @unavailable
    end
  end

  defp source_branch(source, message_id, actor) do
    case local_branch(source, message_id, actor, load: history_load()) do
      {:ok, [%{parent_id: nil} | _rest] = branch} -> {:ok, branch}
      {:ok, _incomplete_branch} -> @unavailable
      {:error, :message_not_found} -> @unavailable
      {:error, _reason} = error -> error
    end
  end

  defp local_branch(_chat, nil, _actor, _opts), do: {:ok, []}

  defp local_branch(chat, message_id, actor, opts) do
    Threads.branch_to_message(chat, message_id, actor, opts)
  rescue
    _error in Ash.Error.Forbidden -> @unavailable
  end

  defp project_branch(branch, source_chat_id, step_id, call_id, task) do
    boundary = List.last(branch)

    with %ChatMessage{role: :assistant} <- boundary,
         %ChatMessageStep{response_final: true} = step <-
           Enum.find(History.steps(boundary), &(&1.id == step_id)),
         {:ok, projected_step} <- project_step(step, call_id, task) do
      steps =
        boundary
        |> History.steps()
        |> Enum.filter(&(&1.sequence < step.sequence))
        |> Enum.sort_by(&History.sort_seq/1)
        |> Kernel.++([projected_step])

      boundary = %{boundary | status: :done, error_detail: nil, steps: steps}

      projected =
        (Enum.drop(branch, -1) ++ [boundary])
        |> Enum.map(fn message ->
          message
          |> ordered_trace()
          |> Map.put(:fork_inherited, %{
            source_chat_id: source_chat_id,
            source_message_id: message.id
          })
        end)

      {:ok, projected}
    else
      {:error, _reason} = error -> error
      _other -> @unavailable
    end
  end

  defp ordered_trace(message) do
    steps =
      message
      |> History.steps()
      |> Enum.sort_by(&History.sort_seq/1)
      |> Enum.map(fn step ->
        items =
          step
          |> History.items()
          |> Enum.sort_by(&History.sort_seq/1)
          |> Enum.map(fn item ->
            %{item | contents: Enum.sort_by(History.contents(item), &History.sort_seq/1)}
          end)

        %{step | items: items}
      end)

    %{message | steps: steps}
  end

  defp project_step(step, selected_item_id, task) do
    items =
      step
      |> History.items()
      |> Enum.filter(&provider_boundary_item?/1)
      |> Enum.sort_by(&History.sort_seq/1)

    with {:ok, calls} <- tool_calls(items),
         %ToolCall{} = selected <- Enum.find(calls, &(&1.item_id == selected_item_id)) do
      first_sequence =
        items |> Enum.map(&History.sort_seq/1) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

      results =
        calls
        |> Enum.zip(ForkBoundary.results(calls, selected, task))
        |> Enum.with_index(first_sequence)
        |> Enum.map(fn {{call, result}, sequence} ->
          result_item(step, call, result, sequence)
        end)

      steering = steering_item(step, task, first_sequence + length(results))
      {:ok, %{step | status: :done, items: items ++ results ++ [steering]}}
    else
      _other -> @unavailable
    end
  end

  defp provider_boundary_item?(item) do
    case History.item_type(item) do
      type when type in [:tool_result, :artifact, :error] -> false
      :steering -> steering_before_response?(item)
      _other -> true
    end
  end

  defp steering_before_response?(item) do
    item
    |> History.opaque_payloads()
    |> Enum.find_value(fn payload ->
      case Map.get(payload, "placement") do
        "before_response" -> :before_response
        "after_response" -> :after_response
        _other -> nil
      end
    end)
    |> Kernel.==(:before_response)
  end

  defp tool_calls(items) do
    items
    |> Enum.filter(&(History.item_type(&1) == :tool_call))
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, calls} ->
      case tool_call(item) do
        {:ok, call} -> {:cont, {:ok, [call | calls]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  # Mirror Persistence's canonical identity/argument decoding without using its
  # owner-authorized followup loader, which would bypass this reader's authority.
  defp tool_call(item) do
    opaque = item |> History.opaque_payloads() |> List.last() || %{}
    opaque = RequestPayload.stringify_keys(opaque)

    raw =
      case opaque do
        %{"raw" => %{} = raw} -> raw
        %{"responses_item" => %{} = raw} -> raw
        _other -> opaque
      end

    function = if is_map(raw["function"]), do: raw["function"], else: %{}

    call_id =
      first_string([opaque["tool_call_id"], opaque["call_id"], raw["call_id"], raw["id"]]) ||
        "item_#{item.id}"

    name = first_string([opaque["name"], raw["name"], function["name"]])
    arguments = raw["arguments"] || function["arguments"] || opaque["arguments"]

    if is_binary(name) do
      {:ok,
       %ToolCall{
         item_id: item.id,
         step_id: item.chat_message_step_id,
         sequence: item.sequence,
         created_at: item.created_at,
         call_id: call_id,
         name: name,
         args: parse_arguments(arguments),
         raw: raw
       }}
    else
      @unavailable
    end
  end

  defp first_string(values) do
    case Enum.find(values, &(is_binary(&1) and String.trim(&1) != "")) do
      nil -> nil
      value -> String.trim(value)
    end
  end

  defp parse_arguments(%{} = arguments), do: arguments

  defp parse_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = parsed} -> parsed
      _other -> %{}
    end
  end

  defp parse_arguments(_arguments), do: %{}

  defp result_item(step, call, result, sequence) do
    # Negative IDs are stable, virtual-only identities, never database references.
    %ChatMessageItem{
      id: -2 * call.item_id,
      chat_message_step_id: step.id,
      sequence: sequence,
      type: :tool_result,
      tool_call_item_id: call.item_id,
      contents: [
        text_content(result.text),
        opaque_content(%{
          "tool_call_id" => result.call_id,
          "call_id" => result.call_id,
          "tool_call_item_id" => call.item_id,
          "name" => result.name,
          "raw" => result.result_raw,
          "responses_item" => %{
            "type" => "function_call_output",
            "call_id" => result.call_id,
            "output" => result.text
          }
        })
      ]
    }
  end

  defp steering_item(step, task, sequence) do
    %ChatMessageItem{
      id: -2 * step.id - 1,
      chat_message_step_id: step.id,
      sequence: sequence,
      type: :steering,
      tool_call_item_id: nil,
      contents: [
        text_content(ForkBoundary.steering(task)),
        opaque_content(%{"placement" => "after_response"})
      ]
    }
  end

  defp text_content(text) do
    %ChatMessageContent{sequence: 1, kind: :text, content_text: text}
  end

  defp opaque_content(payload) do
    %ChatMessageContent{sequence: 1_000_000, kind: :opaque, content_json: payload}
  end

  defp history_load do
    [
      steps: [
        items: [
          contents: [
            file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
          ]
        ]
      ]
    ]
  end
end
