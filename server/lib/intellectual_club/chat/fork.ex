defmodule IntellectualClub.Chat.Fork do
  @moduledoc """
  Creates forked subagent chats from a persisted tool-call step.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatSettingsCopy
  alias IntellectualClub.Chat.MessageTreeCopy
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.ToolCall
  alias IntellectualClub.Repo
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @relation_kind :fork
  @poll_interval_ms 100
  @max_parent_hops 64

  def relation_kind, do: @relation_kind

  @spec create_and_run(ToolInstance.t(), String.t(), ExecutionContext.t(), User.t()) ::
          {:ok, ExecutionResult.t()} | {:error, term()}
  def create_and_run(
        %ToolInstance{} = tool_instance,
        task,
        %ExecutionContext{} = context,
        %User{} = actor
      )
      when is_binary(task) do
    with :ok <- validate_context(context),
         {:ok, source} <- fetch_owned_chat(context.chat_id, actor),
         :ok <- ensure_fork_allowed(tool_instance, source, actor),
         {:ok, fork_state} <- create_subagent_state(source, task, context, actor),
         {:ok, generation} <- start_subagent_generation(fork_state, context, actor),
         {:ok, final} <- await_final_answer(generation.message_id, actor) do
      text = final_text(final)

      payload = %{
        "chat_id" => fork_state.chat.id,
        "message_id" => fork_state.message_id,
        "generation_message_id" => generation.message_id,
        "final_chat_id" => final.chat_id,
        "final_message_id" => final.message_id,
        "chain" => final.chain,
        "url" => "/chats/#{fork_state.chat.id}"
      }

      {:ok,
       %ExecutionResult{
         text: text,
         raw: %{"fork" => payload},
         media: [],
         artifacts: []
       }}
    end
  end

  def create_and_run(_tool_instance, _task, _context, _actor),
    do: {:error, :invalid_fork_context}

  @spec ensure_handoff_allowed(ToolInstance.t(), ExecutionContext.t()) ::
          :ok | {:error, String.t()}
  def ensure_handoff_allowed(%ToolInstance{} = tool_instance, %ExecutionContext{} = context) do
    actor = actor_from_context(context)

    cond do
      is_nil(actor) or not is_integer(context.chat_id) ->
        :ok

      allow_handoff_in_forks?(tool_instance) ->
        :ok

      true ->
        case fetch_owned_chat(context.chat_id, actor) do
          {:ok, %Chat{subagent: true}} ->
            {:error, "Handoff is disabled inside forked subagents."}

          _other ->
            :ok
        end
    end
  end

  def ensure_handoff_allowed(_tool_instance, _context), do: :ok

  defp validate_context(%ExecutionContext{} = context) do
    cond do
      not is_integer(context.chat_id) ->
        {:error, "chat_id is required"}

      not is_integer(context.assistant_message_id || context.message_id) ->
        {:error, "assistant_message_id is required"}

      not is_integer(context.step_id) ->
        {:error, "step_id is required"}

      not is_integer(context.tool_call_item_id) ->
        {:error, "tool_call_item_id is required"}

      true ->
        :ok
    end
  end

  defp create_subagent_state(%Chat{} = source, task, %ExecutionContext{} = context, actor) do
    assistant_message_id = context.assistant_message_id || context.message_id

    with {:ok, branch} <-
           Threads.branch_to_message(source, assistant_message_id, actor,
             load: MessageTreeCopy.load_spec(),
             strict?: true
           ),
         {:ok, source_message} <- find_message(branch, assistant_message_id),
         followup_state = Persistence.load_step_for_followup!(context.step_id),
         {:ok, source_call} <-
           find_tool_call(followup_state.tool_calls, context.tool_call_item_id) do
      Repo.transaction(fn ->
        chat = create_target_chat!(source, source_message.id, task, actor)
        ChatSettingsCopy.copy_bindings!(source.id, chat.id, actor)

        copied_ids = MessageTreeCopy.copy_messages!(branch, chat, actor)
        copied_message_id = Map.fetch!(copied_ids, source_message.id)

        copied_message =
          copied_message_id
          |> load_message_with_steps!(actor)
          |> restore_copied_message!(actor)

        source_step = followup_state.step
        copied_step = copied_step_for_source!(copied_message, source_step)
        copied_call = prepare_copied_tool_step!(copied_step, source_step, source_call, actor)

        result =
          Persistence.persist_tool_result!(
            copied_message_id,
            copied_step.id,
            copied_call,
            synthetic_result(source_call, task)
          )

        followup_state = Persistence.load_step_for_followup!(copied_step.id)

        %{
          chat: Ash.get!(Chat, chat.id, actor: actor, load: [:last_message]),
          message_id: copied_message_id,
          step_id: copied_step.id,
          step_sequence: copied_step.sequence,
          step_raw_request: copied_step.raw_request || %{},
          runtime_step: followup_state.runtime_step,
          results: [result]
        }
      end)
      |> unwrap_transaction()
    end
  end

  defp start_subagent_generation(fork_state, %ExecutionContext{} = parent_context, actor) do
    context =
      IntellectualClub.Generation.Context.build_prepared!(
        fork_state.chat.id,
        fork_state.message_id,
        fork_state.step_id,
        fork_state.step_raw_request,
        actor: actor,
        available_file_external_ids: parent_context.available_file_external_ids || []
      )

    followup =
      context.adapter_module.build_followup_request(%{
        context: context,
        runtime_step: fork_state.runtime_step,
        results: fork_state.results,
        tools: context.tools_payload || RequestPayload.tools(fork_state.step_raw_request || %{})
      })

    :ok = Persistence.mark_step_done!(fork_state.step_id)

    next_step_id =
      Persistence.ensure_step_started!(
        fork_state.message_id,
        fork_state.step_sequence + 1,
        followup.raw_request || %{},
        started_at: DateTime.utc_now()
      )

    with {:ok, _context} <-
           GenerationSupervisor.start_prepared_generation(
             fork_state.chat.id,
             fork_state.message_id,
             next_step_id,
             followup.raw_request || %{},
             actor: actor,
             available_file_external_ids: parent_context.available_file_external_ids || []
           ) do
      {:ok, %{message_id: fork_state.message_id, step_id: next_step_id}}
    end
  end

  defp create_target_chat!(%Chat{} = source, source_message_id, task, actor) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: task,
        bot_id: source.bot_id,
        llm_configuration_id: source.llm_configuration_id,
        parent_chat_id: source.id,
        parent_message_id: source_message_id,
        parent_relation_kind: @relation_kind,
        subagent: true
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp restore_copied_message!(%ChatMessage{} = message, actor) do
    message
    |> Ash.Changeset.for_update(
      :set_generation_state,
      %{status: :generating, error_detail: nil, finished_at: nil},
      actor: actor
    )
    |> Ash.update!()
    |> load_message_with_steps!(actor)
  end

  defp prepare_copied_tool_step!(
         %ChatMessageStep{} = copied_step,
         %ChatMessageStep{} = source_step,
         %ToolCall{} = source_call,
         actor
       ) do
    copied_step =
      copied_step
      |> trim_to_tool_call!(source_call, actor)
      |> update_copied_step!(source_step, source_call, actor)
      |> load_step_with_items!(actor)

    copied_item =
      copied_step
      |> ordered_items()
      |> Enum.find(fn item ->
        item.type in [:tool_call, "tool_call"] and item.sequence == source_call.sequence
      end)

    if is_nil(copied_item) do
      raise "Copied fork tool call was not found"
    end

    %ToolCall{
      source_call
      | item_id: copied_item.id,
        step_id: copied_step.id,
        created_at: copied_item.created_at
    }
  end

  defp trim_to_tool_call!(%ChatMessageStep{} = step, %ToolCall{} = source_call, actor) do
    step
    |> ordered_items()
    |> Enum.each(fn item ->
      delete? =
        cond do
          item.type in [:tool_result, "tool_result", :artifact, "artifact"] ->
            true

          item.type in [:tool_call, "tool_call"] ->
            item.sequence != source_call.sequence

          true ->
            false
        end

      if delete? do
        Ash.destroy!(item, actor: actor)
      end
    end)

    step
  end

  defp update_copied_step!(
         %ChatMessageStep{} = copied_step,
         %ChatMessageStep{} = source_step,
         %ToolCall{} = source_call,
         actor
       ) do
    copied_step
    |> Ash.Changeset.for_update(
      :update,
      %{
        status: :waiting_tools,
        raw_response: filter_raw_response_for_call(source_step.raw_response, source_call),
        response_final: source_step.response_final || true,
        input_tokens: source_step.input_tokens,
        output_tokens: source_step.output_tokens,
        cached_input_tokens: source_step.cached_input_tokens,
        reasoning_tokens: source_step.reasoning_tokens,
        cost: source_step.cost,
        first_token_at: source_step.first_token_at,
        finished_at: nil
      },
      actor: actor
    )
    |> Ash.update!()
  end

  defp synthetic_result(%ToolCall{} = call, task) do
    text =
      "You are a subagent. Task: #{task}\n\n" <>
        "Continue from the copied context and write the final answer for this task."

    %{
      text: text,
      result_raw: %{
        "fork_instruction" => %{
          "subagent" => true,
          "task" => task
        }
      },
      media_contents: [],
      artifact_contents: [],
      call_id: call.call_id,
      name: call.name,
      args: call.args || %{}
    }
  end

  defp await_final_answer(message_id, actor) when is_integer(message_id) do
    await_final_answer(message_id, actor, [])
  end

  defp await_final_answer(message_id, actor, chain) when is_integer(message_id) do
    message = load_final_message!(message_id, actor)
    status = normalize_status(message.status)

    case status do
      :generating ->
        Process.sleep(@poll_interval_ms)
        await_final_answer(message_id, actor, chain)

      :done ->
        chain = chain ++ [chain_entry(message)]

        case handoff_generation_message_id(message) do
          id when is_integer(id) and id > 0 ->
            await_final_answer(id, actor, chain)

          _other ->
            {:ok,
             %{
               chat_id: message.chat_id,
               message_id: message.id,
               text: History.project_text_for_item_type(message, :answer),
               chain: chain
             }}
        end

      :error ->
        {:error, message.error_detail || "Subagent generation failed."}

      :canceled ->
        {:error, "Subagent generation was canceled."}

      _other ->
        Process.sleep(@poll_interval_ms)
        await_final_answer(message_id, actor, chain)
    end
  end

  defp handoff_generation_message_id(%ChatMessage{} = message) do
    message
    |> ordered_items()
    |> Enum.filter(&(&1.type in [:tool_result, "tool_result"]))
    |> Enum.find_value(fn item ->
      item
      |> History.opaque_payloads()
      |> Enum.find_value(fn
        %{"raw" => %{"handoff" => %{"generation_message_id" => id}}} when is_integer(id) -> id
        %{"handoff" => %{"generation_message_id" => id}} when is_integer(id) -> id
        _other -> nil
      end)
    end)
  end

  defp chain_entry(%ChatMessage{} = message) do
    %{
      "chat_id" => message.chat_id,
      "message_id" => message.id
    }
  end

  defp final_text(%{text: text}) when is_binary(text) do
    case String.trim(text) do
      "" -> "Subagent completed without a final answer."
      value -> value
    end
  end

  defp final_text(_final), do: "Subagent completed without a final answer."

  defp ensure_fork_allowed(%ToolInstance{} = tool_instance, %Chat{} = chat, actor) do
    depth = fork_depth(chat, actor)
    limit = nested_forks_limit(tool_instance)

    if depth == 0 or depth <= limit do
      :ok
    else
      {:error,
       "Nested fork is disabled for this subagent. Increase nested_forks_limit to allow it."}
    end
  end

  defp fork_depth(%Chat{} = chat, actor) do
    chat
    |> ancestor_chain(actor, [])
    |> Enum.count(&(normalize_relation_kind(&1.parent_relation_kind) == @relation_kind))
  end

  defp ancestor_chain(%Chat{} = chat, actor, acc) do
    if length(acc) >= @max_parent_hops or not is_integer(chat.parent_chat_id) do
      acc
    else
      case fetch_owned_chat(chat.parent_chat_id, actor) do
        {:ok, parent} -> ancestor_chain(parent, actor, [chat | acc])
        _other -> [chat | acc]
      end
    end
  end

  defp nested_forks_limit(%ToolInstance{} = tool_instance) do
    value =
      tool_instance
      |> Map.get(:config, %{})
      |> config_get("nested_forks_limit", 0)

    case value do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_non_negative_integer(value)
      _other -> 0
    end
  end

  defp allow_handoff_in_forks?(%ToolInstance{} = tool_instance) do
    tool_instance
    |> Map.get(:config, %{})
    |> config_get("allow_handoff_in_forks", false)
    |> truthy?()
  end

  defp config_get(config, key, default) when is_map(config) and is_binary(key) do
    Map.get(config, key, Map.get(config, String.to_atom(key), default))
  end

  defp config_get(_config, _key, default), do: default

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp actor_from_context(%ExecutionContext{owner_id: owner_id})
       when is_integer(owner_id) and owner_id > 0 do
    %User{id: owner_id}
  end

  defp actor_from_context(_context), do: nil

  defp fetch_owned_chat(chat_id, %{id: actor_id} = actor)
       when is_integer(chat_id) and is_integer(actor_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id and owner_id == ^actor_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load([:last_message])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> {:ok, chat}
      {:ok, []} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_owned_chat(_chat_id, _actor), do: {:error, :invalid_chat_id}

  defp find_message(messages, message_id) when is_list(messages) and is_integer(message_id) do
    case Enum.find(messages, &(&1.id == message_id)) do
      %ChatMessage{} = message -> {:ok, message}
      _other -> {:error, :message_not_in_branch}
    end
  end

  defp find_tool_call(tool_calls, item_id) when is_list(tool_calls) and is_integer(item_id) do
    case Enum.find(tool_calls, &(&1.item_id == item_id)) do
      %ToolCall{} = call -> {:ok, call}
      _other -> {:error, :tool_call_not_found}
    end
  end

  defp copied_step_for_source!(%ChatMessage{} = copied_message, %ChatMessageStep{} = source_step) do
    copied_message.steps
    |> List.wrap()
    |> Enum.find(&(&1.sequence == source_step.sequence))
    |> case do
      %ChatMessageStep{} = step -> step
      _other -> raise "Copied fork step was not found"
    end
  end

  defp load_message_with_steps!(message_id, actor) when is_integer(message_id) do
    Ash.get!(ChatMessage, message_id,
      actor: actor,
      load: [
        steps: [
          :sequence,
          items: [
            :sequence,
            :type,
            contents: [
              :sequence,
              :kind,
              :content_text,
              :content_json,
              :file_id
            ]
          ]
        ]
      ]
    )
  end

  defp load_message_with_steps!(%ChatMessage{} = message, actor) do
    load_message_with_steps!(message.id, actor)
  end

  defp load_final_message!(message_id, actor) do
    Ash.get!(ChatMessage, message_id,
      actor: actor,
      load: [
        :chat,
        steps: [
          :sequence,
          items: [
            :sequence,
            :type,
            contents: [
              :sequence,
              :kind,
              :content_text,
              :content_json,
              :file_id
            ]
          ]
        ]
      ]
    )
  end

  defp load_step_with_items!(step_id, actor) when is_integer(step_id) do
    Ash.get!(ChatMessageStep, step_id,
      actor: actor,
      load: [
        items: [
          :sequence,
          :type,
          contents: [
            :sequence,
            :kind,
            :content_text,
            :content_json,
            :file_id
          ]
        ]
      ]
    )
  end

  defp load_step_with_items!(%ChatMessageStep{} = step, actor) do
    load_step_with_items!(step.id, actor)
  end

  defp ordered_items(%{steps: steps}) when is_list(steps) do
    steps
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(&ordered_items/1)
  end

  defp ordered_items(%{items: items}) when is_list(items) do
    Enum.sort_by(items, &sort_seq/1)
  end

  defp ordered_items(_other), do: []

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp normalize_status(value) when value in [:generating, :done, :error, :canceled], do: value
  defp normalize_status("generating"), do: :generating
  defp normalize_status("done"), do: :done
  defp normalize_status("error"), do: :error
  defp normalize_status("canceled"), do: :canceled
  defp normalize_status(_other), do: nil

  defp normalize_relation_kind(value) when is_atom(value), do: value
  defp normalize_relation_kind("fork"), do: :fork
  defp normalize_relation_kind("handoff"), do: :handoff
  defp normalize_relation_kind(_value), do: nil

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp filter_raw_response_for_call(nil, _call), do: nil

  defp filter_raw_response_for_call(%{} = raw_response, %ToolCall{} = call) do
    raw_response
    |> RequestPayload.stringify_keys()
    |> filter_tool_collections(call)
  end

  defp filter_raw_response_for_call(raw_response, _call), do: raw_response

  defp filter_tool_collections(%{} = map, %ToolCall{} = call) do
    map
    |> update_tool_list("tool_calls", call)
    |> update_tool_list("content", call)
    |> update_tool_list("output", call)
    |> update_tool_list("steps", call)
    |> update_choices(call)
  end

  defp update_choices(%{"choices" => choices} = map, %ToolCall{} = call) when is_list(choices) do
    choices =
      Enum.map(choices, fn
        %{} = choice ->
          choice
          |> update_nested_map("message", call)
          |> update_nested_map("delta", call)

        other ->
          other
      end)

    Map.put(map, "choices", choices)
  end

  defp update_choices(map, _call), do: map

  defp update_nested_map(%{} = map, key, %ToolCall{} = call) do
    case Map.get(map, key) do
      %{} = nested -> Map.put(map, key, filter_tool_collections(nested, call))
      _other -> map
    end
  end

  defp update_tool_list(%{} = map, key, %ToolCall{} = call) do
    case Map.get(map, key) do
      items when is_list(items) -> Map.put(map, key, filter_tool_items(items, call))
      _other -> map
    end
  end

  defp filter_tool_items(items, %ToolCall{} = call) when is_list(items) do
    Enum.filter(items, fn
      %{} = item ->
        not tool_item?(item) or tool_item_matches?(item, call)

      _other ->
        true
    end)
  end

  defp tool_item?(%{} = item) do
    type =
      item
      |> Map.get("type", "")
      |> to_string()
      |> String.trim()

    type in ["tool_call", "tool_use", "function_call"]
  end

  defp tool_item_matches?(%{} = item, %ToolCall{} = call) do
    call_id = call.call_id |> to_string() |> String.trim()

    id_match? =
      [
        Map.get(item, "id"),
        Map.get(item, "call_id"),
        Map.get(item, "tool_call_id"),
        Map.get(item, "tool_use_id")
      ]
      |> Enum.map(&(to_string(&1 || "") |> String.trim()))
      |> Enum.any?(&(&1 != "" and &1 == call_id))

    id_match? or
      (tool_item_name(item) == call.name and tool_item_args(item) == normalized_args(call.args))
  end

  defp tool_item_name(%{} = item) do
    [
      Map.get(item, "name"),
      get_in(item, ["function", "name"])
    ]
    |> Enum.find("", &(to_string(&1 || "") |> String.trim() != ""))
    |> to_string()
    |> String.trim()
  end

  defp tool_item_args(%{} = item) do
    [
      Map.get(item, "arguments"),
      Map.get(item, "input"),
      get_in(item, ["function", "arguments"])
    ]
    |> Enum.find(%{}, fn value ->
      case normalize_args(value) do
        %{} = map when map_size(map) > 0 -> true
        _other -> false
      end
    end)
    |> normalize_args()
  end

  defp normalized_args(args), do: normalize_args(args)

  defp normalize_args(%{} = args), do: RequestPayload.stringify_keys(args)

  defp normalize_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = decoded} -> RequestPayload.stringify_keys(decoded)
      _other -> %{}
    end
  end

  defp normalize_args(_args), do: %{}
end
