defmodule IntellectualClub.Chat.Fork do
  @moduledoc """
  Creates forked subagent chats from a persisted tool-call step.
  """

  @behaviour IntellectualClub.BackgroundTasks.Adapter

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks.BackgroundTask
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
  @progress_page_max_bytes 48_000
  @parent_tool_call_unique_constraint "chats_unique_parent_tool_call_item_id_index"

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
    with {:ok, reference} <- start_or_resume(tool_instance, task, context, actor),
         {:ok, snapshot} <- await_snapshot(reference, actor),
         result = sync_execution_result_from_snapshot(snapshot, actor),
         :ok <- persist_parent_tool_result(context, result) do
      {:ok, result}
    else
      {:error, {:fork_result, message}} ->
        result = error_result(message)

        with :ok <- persist_parent_tool_result(context, result) do
          {:ok, result}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def create_and_run(_tool_instance, _task, _context, _actor),
    do: {:error, :invalid_fork_context}

  @doc """
  Starts a forked subagent or resumes the subagent already linked to this tool call.

  Unlike `create_and_run/4`, this function never waits for the subagent to finish.
  The returned reference is durable: the generation message and its steps remain the
  source of truth across application restarts.
  """
  @spec start_or_resume(ToolInstance.t(), String.t(), ExecutionContext.t(), User.t()) ::
          {:ok, map()} | {:error, term()}
  def start_or_resume(
        %ToolInstance{} = tool_instance,
        task,
        %ExecutionContext{} = context,
        %User{} = actor
      )
      when is_binary(task) do
    start_or_resume(tool_instance, task, context, actor, [])
  end

  def start_or_resume(_tool_instance, _task, _context, _actor),
    do: {:error, :invalid_fork_context}

  @doc false
  @spec start_or_resume(ToolInstance.t(), String.t(), ExecutionContext.t(), User.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_or_resume(
        %ToolInstance{} = tool_instance,
        task,
        %ExecutionContext{} = context,
        %User{} = actor,
        opts
      )
      when is_binary(task) and is_list(opts) do
    with :ok <- validate_context(context),
         {:ok, source} <- fetch_owned_chat(context.chat_id, actor),
         {:ok, source_context} <- build_source_context(source, task, context, actor),
         {:ok, fork_ref} <-
           find_or_create_subagent(tool_instance, source_context, context, actor),
         {:ok, reference} <- start_subagent_reference(fork_ref, context, actor, opts) do
      {:ok, reference}
    end
  end

  def start_or_resume(_tool_instance, _task, _context, _actor, _opts),
    do: {:error, :invalid_fork_context}

  @doc """
  Returns a non-blocking, answer-only snapshot for a fork reference.

  The cursor is opaque to callers. A valid cursor returns only answer text appended
  since the previous snapshot. If a provider retry rewrites already observed text,
  the snapshot returns the full answer with `mode: "replace"`.
  """
  @spec snapshot(map(), User.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def snapshot(reference, actor, cursor \\ nil)

  def snapshot(reference, %User{} = actor, cursor) when is_map(reference) do
    with {:ok, reference} <- normalize_reference(reference, actor),
         {:ok, state} <- resolve_snapshot_chain(reference.generation_message_id, actor) do
      {progress, next_cursor} = answer_progress(state.answer, cursor, reference)

      {:ok,
       %{
         status: state.status,
         progress: progress,
         next_cursor: next_cursor,
         result: snapshot_result(reference, state),
         error: Map.get(state, :error),
         url: reference.url
       }}
    end
  end

  def snapshot(_reference, _actor, _cursor), do: {:error, :invalid_fork_reference}

  @doc false
  @impl true
  def execute_background(
        task_record,
        %ToolInstance{} = tool_instance,
        "fork",
        args,
        %ExecutionContext{} = context
      )
      when is_map(args) do
    task = args |> Map.get("task", "") |> to_string() |> String.trim()

    with true <- task != "",
         task_id when is_binary(task_id) <- task_record_value(task_record, :id),
         %User{} = actor <- actor_from_context(context),
         {:ok, reference} <-
           start_or_resume(tool_instance, task, context, actor,
             on_reference: &set_background_reference(task_record, &1)
           ) do
      await_background_snapshot(reference, actor)
    else
      false -> {:error, "task is required"}
      nil -> {:error, "Background task context is invalid."}
      {:error, _reason} = error -> error
      _other -> {:error, "Background task context is invalid."}
    end
  end

  def execute_background(_task_record, _tool_instance, _function_name, _args, _context) do
    {:error, "Invalid background fork execution context."}
  end

  @doc false
  def await_background_snapshot(reference, actor) do
    case await_snapshot(reference, actor) do
      {:ok, terminal} ->
        background_execution_result(terminal)

      {:error, _reason} = error ->
        cancel_reference_generation(reference, actor)
        error
    end
  rescue
    exception ->
      cancel_reference_generation(reference, actor)
      {:error, Exception.message(exception)}
  catch
    kind, reason ->
      cancel_reference_generation(reference, actor)
      {:error, {kind, reason}}
  end

  @doc false
  @impl true
  def snapshot_background(task_record, cursor) do
    case background_reference(task_record) do
      {:ok, reference, actor} -> snapshot(reference, actor, cursor)
      {:error, :target_not_ready} -> :default
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @impl true
  def recover_background(_task_record), do: :restart

  @doc false
  @impl true
  def cancel_background(task_record) do
    case background_reference(task_record) do
      {:ok, reference, actor} ->
        cancel_reference_generation(reference, actor)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

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

  defp build_source_context(%Chat{} = source, task, %ExecutionContext{} = context, actor) do
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
      {:ok,
       %{
         source: source,
         source_message: source_message,
         source_call: source_call,
         branch: branch,
         followup_state: followup_state,
         task: task
       }}
    end
  end

  defp find_or_create_subagent(
         %ToolInstance{} = tool_instance,
         source_context,
         %ExecutionContext{} = context,
         actor
       ) do
    with nil <- fetch_fork_chat_by_tool_call_item_id(context.tool_call_item_id, actor),
         {:legacy, nil} <- {:legacy, claim_legacy_fork_chat(source_context, context, actor)},
         :ok <- ensure_fork_allowed(tool_instance, source_context.source, actor) do
      with {:ok, fork_state} <- create_subagent_state(source_context, context, actor) do
        {:ok, {:new, fork_state}}
      end
    else
      %Chat{} = chat ->
        {:ok, {:existing, chat}}

      {:legacy, %Chat{} = chat} ->
        {:ok, {:existing, chat}}

      {:legacy, {:ambiguous, message}} ->
        {:error, {:fork_result, message}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_fork_chat_by_tool_call_item_id(tool_call_item_id, actor)
       when is_integer(tool_call_item_id) do
    Chat
    |> Ash.Query.filter(
      parent_tool_call_item_id == ^tool_call_item_id and parent_relation_kind == ^@relation_kind
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.load([:last_message])
    |> Ash.read!(actor: actor)
    |> List.first()
  end

  defp fetch_fork_chat_by_tool_call_item_id(_tool_call_item_id, _actor), do: nil

  defp claim_legacy_fork_chat(source_context, %ExecutionContext{} = context, actor) do
    candidates =
      Chat
      |> Ash.Query.filter(
        parent_chat_id == ^source_context.source.id and
          parent_message_id == ^source_context.source_message.id and
          parent_relation_kind == ^@relation_kind and
          subagent == true and
          is_nil(parent_tool_call_item_id)
      )
      |> Ash.Query.sort(created_at: :asc, id: :asc)
      |> Ash.Query.load(
        [
          :last_message,
          messages: [
            steps: [
              items: [
                :tool_call_item_id,
                contents: [:content_json, :content_text, :kind]
              ]
            ]
          ]
        ],
        strict?: true
      )
      |> Ash.read!(actor: actor)
      |> Enum.filter(&legacy_fork_candidate_matches?(&1, source_context))

    case candidates do
      [] ->
        nil

      [%Chat{} = chat] ->
        claim_fork_chat!(chat, context.tool_call_item_id, actor)

      _many ->
        {:ambiguous, "Existing fork subagent is ambiguous; refusing to create a duplicate."}
    end
  end

  defp legacy_fork_candidate_matches?(%Chat{} = chat, source_context) do
    String.trim(to_string(chat.note || "")) == String.trim(to_string(source_context.task || "")) and
      Enum.any?(List.wrap(Map.get(chat, :messages)), fn message ->
        Enum.any?(List.wrap(Map.get(message, :steps)), fn step ->
          legacy_step_matches?(step, source_context)
        end)
      end)
  end

  defp legacy_step_matches?(step, source_context) do
    items = List.wrap(Map.get(step, :items))

    Enum.any?(items, &legacy_tool_call_matches?(&1, source_context.source_call)) and
      Enum.any?(items, &legacy_fork_instruction_matches?(&1, source_context.task))
  end

  defp legacy_tool_call_matches?(item, %ToolCall{} = call) do
    History.item_type(item) == :tool_call and
      History.sort_seq(item) == call.sequence and
      Enum.any?(History.opaque_payloads(item), fn opaque ->
        raw = Map.get(opaque, "raw") || %{}

        call_id =
          [
            Map.get(opaque, "tool_call_id"),
            Map.get(opaque, "call_id"),
            Map.get(raw, "call_id"),
            Map.get(raw, "id")
          ]
          |> Enum.find("", &present_string?/1)
          |> to_string()
          |> String.trim()

        name =
          [
            Map.get(opaque, "name"),
            Map.get(raw, "name"),
            get_in(raw, ["function", "name"])
          ]
          |> Enum.find("", &present_string?/1)
          |> to_string()
          |> String.trim()

        call_id == call.call_id and name == call.name
      end)
  end

  defp legacy_fork_instruction_matches?(item, task) do
    History.item_type(item) == :tool_result and
      Enum.any?(History.opaque_payloads(item), fn opaque ->
        instruction =
          case Map.get(opaque, "raw") do
            %{"fork_instruction" => %{} = value} -> value
            _other -> Map.get(opaque, "fork_instruction")
          end

        is_map(instruction) and
          instruction["subagent"] == true and
          to_string(instruction["task"] || "") == to_string(task || "")
      end)
  end

  defp claim_fork_chat!(%Chat{} = chat, tool_call_item_id, actor)
       when is_integer(tool_call_item_id) do
    changeset =
      Ash.Changeset.for_update(
        chat,
        :update,
        %{parent_tool_call_item_id: tool_call_item_id},
        actor: actor
      )

    case Ash.update(changeset, actor: actor) do
      {:ok, %Chat{} = claimed} ->
        Ash.load!(claimed, [:last_message], actor: actor)

      {:error, %Ash.Error.Invalid{} = error} ->
        recover_claim_race!(error, tool_call_item_id, actor)

      {:error, error} ->
        raise error
    end
  end

  defp recover_claim_race!(%Ash.Error.Invalid{} = error, tool_call_item_id, actor) do
    if parent_tool_call_unique_constraint_error?(error) do
      case fetch_fork_chat_by_tool_call_item_id(tool_call_item_id, actor) do
        %Chat{} = chat -> chat
        nil -> raise error
      end
    else
      raise error
    end
  end

  defp parent_tool_call_unique_constraint_error?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &parent_tool_call_unique_constraint_error?/1)
  end

  defp parent_tool_call_unique_constraint_error?(%{private_vars: vars}) when is_list(vars) do
    Keyword.get(vars, :constraint) == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(_error), do: false

  defp create_subagent_state(source_context, %ExecutionContext{} = context, actor) do
    Repo.transaction(fn ->
      chat =
        create_target_chat!(
          source_context.source,
          source_context.source_message.id,
          source_context.task,
          context.tool_call_item_id,
          actor
        )

      ChatSettingsCopy.copy_bindings!(source_context.source.id, chat.id, actor)

      copied_ids = MessageTreeCopy.copy_messages!(source_context.branch, chat, actor)
      copied_message_id = Map.fetch!(copied_ids, source_context.source_message.id)

      copied_message =
        copied_message_id
        |> load_message_with_steps!(actor)
        |> restore_copied_message!(actor)

      source_step = source_context.followup_state.step
      copied_step = copied_step_for_source!(copied_message, source_step)

      copied_call =
        prepare_copied_tool_step!(copied_step, source_step, source_context.source_call, actor)

      result =
        Persistence.persist_tool_result!(
          copied_message_id,
          copied_step.id,
          copied_call,
          synthetic_result(source_context.source_call, source_context.task)
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

  defp start_subagent_reference(
         {:new, fork_state},
         %ExecutionContext{} = parent_context,
         actor,
         opts
       ) do
    reference = fork_reference(fork_state.chat, fork_state.message_id, fork_state.message_id)

    with :ok <- notify_reference_or_cancel(reference, actor, opts) do
      case start_subagent_generation(fork_state, parent_context, actor) do
        {:ok, generation} ->
          {:ok, %{reference | generation_message_id: generation.message_id}}

        {:error, _reason} = error ->
          cancel_reference_generation(reference, actor)
          error
      end
    end
  end

  defp start_subagent_reference(
         {:existing, %Chat{} = chat},
         %ExecutionContext{},
         actor,
         opts
       ) do
    with {:ok, message_id} <- fork_generation_message_id(chat, actor),
         reference = fork_reference(chat, message_id, message_id),
         :ok <- notify_reference_or_cancel(reference, actor, opts) do
      case resume_fork_generation_if_needed(message_id, actor) do
        :ok ->
          {:ok, reference}

        {:error, _reason} = error ->
          cancel_reference_generation(reference, actor)
          error
      end
    end
  end

  defp notify_reference_or_cancel(reference, actor, opts)
       when is_map(reference) and is_list(opts) do
    result =
      case Keyword.get(opts, :on_reference) do
        callback when is_function(callback, 1) -> callback.(reference)
        _other -> :ok
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        cancel_reference_generation(reference, actor)
        error

      other ->
        cancel_reference_generation(reference, actor)
        {:error, {:invalid_reference_callback_result, other}}
    end
  end

  defp cancel_reference_generation(reference, actor) when is_map(reference) do
    message_id = reference.generation_message_id

    case GenerationSupervisor.cancel_generation(message_id,
           include_background_tasks?: true
         ) do
      :not_found ->
        case Ash.get(ChatMessage, message_id, actor: actor) do
          {:ok, %ChatMessage{status: :generating}} ->
            Persistence.cancel_orphaned_generating_message!(message_id)

          _other ->
            :ok
        end

      _other ->
        :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp fork_reference(%Chat{} = chat, message_id, generation_message_id) do
    %{
      chat_id: chat.id,
      message_id: message_id,
      generation_message_id: generation_message_id,
      url: "/chats/#{chat.id}"
    }
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

  defp fork_generation_message_id(%Chat{last_message_id: message_id}, _actor)
       when is_integer(message_id) do
    {:ok, message_id}
  end

  defp fork_generation_message_id(%Chat{id: chat_id}, actor) when is_integer(chat_id) do
    case Ash.get(Chat, chat_id, actor: actor, load: [:last_message]) do
      {:ok, %Chat{last_message_id: message_id}} when is_integer(message_id) ->
        {:ok, message_id}

      {:ok, _chat} ->
        {:error, "Existing fork subagent has no generation message."}

      {:error, _error} ->
        {:error, :not_found}
    end
  end

  defp fork_generation_message_id(_chat, _actor), do: {:error, "Invalid fork subagent."}

  defp resume_fork_generation_if_needed(message_id, actor) when is_integer(message_id) do
    message = Ash.get!(ChatMessage, message_id, actor: actor)

    if message.status == :generating and
         GenerationSupervisor.get_generation_state(message_id) == :not_found do
      case GenerationSupervisor.resume_orphaned_message(message_id, actor: actor) do
        {:ok, _context} ->
          :ok

        {:error, :already_running} ->
          :ok

        {:error, :invalid_status} ->
          :ok

        {:error, :no_steps_to_retry} ->
          :ok = Persistence.cancel_orphaned_generating_message!(message_id)
          :ok

        {:error, reason} ->
          {:error, "Failed to resume fork subagent: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  defp error_result(reason) do
    text = to_string(reason || "Subagent generation failed.")

    %ExecutionResult{
      text: text,
      raw: %{"isError" => true, "error" => text},
      media: [],
      artifacts: []
    }
  end

  defp persist_parent_tool_result(
         %ExecutionContext{} = parent_context,
         %ExecutionResult{} = result
       ) do
    payload = %{
      text: result.text,
      result_raw: result.raw || %{},
      media_contents: [],
      artifact_contents: []
    }

    try do
      parent_message_id = parent_context.message_id || parent_context.assistant_message_id
      followup_state = Persistence.load_step_for_followup!(parent_context.step_id)

      {:ok, source_call} =
        find_tool_call(followup_state.tool_calls, parent_context.tool_call_item_id)

      _ =
        Persistence.persist_tool_result!(
          parent_message_id,
          parent_context.step_id,
          source_call,
          payload
        )

      :ok
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      :exit, reason -> {:error, Exception.format_exit(reason)}
    end
  end

  defp create_target_chat!(
         %Chat{} = source,
         source_message_id,
         task,
         parent_tool_call_item_id,
         actor
       ) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: task,
        bot_id: source.bot_id,
        llm_configuration_id: source.llm_configuration_id,
        parent_chat_id: source.id,
        parent_message_id: source_message_id,
        parent_tool_call_item_id: parent_tool_call_item_id,
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
        item.type == :tool_call and item.sequence == source_call.sequence
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
          item.type in [:tool_result, :artifact] ->
            true

          item.type == :tool_call ->
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

  defp await_snapshot(reference, actor) do
    case snapshot(reference, actor) do
      {:ok, %{status: :running}} ->
        Process.sleep(@poll_interval_ms)
        await_snapshot(reference, actor)

      {:ok, %{status: status} = snapshot}
      when status in [:completed, :failed, :canceled] ->
        {:ok, snapshot}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_reference(reference, actor) when is_map(reference) do
    generation_message_id = Map.get(reference, :generation_message_id)
    message_id = Map.get(reference, :message_id) || generation_message_id
    requested_chat_id = Map.get(reference, :chat_id)

    with true <- is_integer(generation_message_id) and generation_message_id > 0,
         {:ok, %ChatMessage{} = message} <-
           Ash.get(ChatMessage, generation_message_id, actor: actor),
         chat_id = requested_chat_id || message.chat_id,
         true <- is_integer(chat_id) and chat_id > 0,
         {:ok, %Chat{} = chat} <- fetch_owned_chat(chat_id, actor),
         true <- message.chat_id == chat.id do
      {:ok,
       %{
         chat_id: chat.id,
         message_id: if(is_integer(message_id), do: message_id, else: generation_message_id),
         generation_message_id: generation_message_id,
         url: Map.get(reference, :url) || "/chats/#{chat.id}"
       }}
    else
      false -> {:error, :invalid_fork_reference}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_fork_reference}
    end
  end

  defp resolve_snapshot_chain(message_id, actor) when is_integer(message_id) do
    do_resolve_snapshot_chain(message_id, actor, MapSet.new(), [], [])
  end

  defp do_resolve_snapshot_chain(_message_id, _actor, _visited, chain, answers)
       when length(chain) >= @max_parent_hops do
    {:ok,
     %{
       status: :failed,
       answer: join_answers(answers),
       final: nil,
       error: "Subagent handoff chain exceeded the supported depth."
     }}
  end

  defp do_resolve_snapshot_chain(message_id, actor, visited, chain, answers)
       when is_integer(message_id) do
    if MapSet.member?(visited, message_id) do
      {:ok,
       %{
         status: :failed,
         answer: join_answers(answers),
         final: nil,
         error: "Subagent handoff chain contains a cycle."
       }}
    else
      with :ok <- resume_fork_generation_if_needed(message_id, actor) do
        message = load_final_message!(message_id, actor)
        message_answer = message_answer_text(message)
        answers = append_answer(answers, message_answer)

        case message.status do
          :generating ->
            {:ok,
             %{
               status: :running,
               answer: join_answers(answers),
               final: nil,
               error: nil
             }}

          :done ->
            chain = chain ++ [chain_entry(message)]

            case handoff_generation_message_id(message) do
              id when is_integer(id) and id > 0 ->
                do_resolve_snapshot_chain(
                  id,
                  actor,
                  MapSet.put(visited, message_id),
                  chain,
                  answers
                )

              _other ->
                {:ok,
                 %{
                   status: :completed,
                   answer: join_answers(answers),
                   final: %{
                     chat_id: message.chat_id,
                     message_id: message.id,
                     text: message_answer,
                     chain: chain
                   },
                   error: nil
                 }}
            end

          :error ->
            {:ok,
             %{
               status: :failed,
               answer: join_answers(answers),
               final: nil,
               error: message.error_detail || "Subagent generation failed."
             }}

          :canceled ->
            {:ok,
             %{
               status: :canceled,
               answer: join_answers(answers),
               final: nil,
               error: "Subagent generation was canceled."
             }}

          _other ->
            {:ok,
             %{
               status: :failed,
               answer: join_answers(answers),
               final: nil,
               error: "Subagent generation has an invalid status."
             }}
        end
      end
    end
  end

  defp message_answer_text(%ChatMessage{} = message) do
    runtime_step =
      case GenerationSupervisor.get_generation_state(message.id) do
        {:ok, %{step: %{} = step}} -> step
        _other -> nil
      end

    runtime_step_id = trace_value(runtime_step, :id)
    fork_step_sequence = fork_instruction_step_sequence(message)

    persisted_steps =
      message.steps
      |> List.wrap()
      |> Enum.reject(&(is_integer(runtime_step_id) and &1.id == runtime_step_id))

    (persisted_steps ++ List.wrap(runtime_step))
    |> Enum.filter(fn step ->
      sequence = trace_value(step, :sequence)

      not is_integer(fork_step_sequence) or
        (is_integer(sequence) and sequence > fork_step_sequence)
    end)
    |> Enum.sort_by(&(trace_value(&1, :sequence) || 0))
    |> Enum.map(&answer_text_from_trace/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp fork_instruction_step_sequence(%ChatMessage{} = message) do
    message.steps
    |> List.wrap()
    |> Enum.find_value(fn step ->
      if Enum.any?(List.wrap(Map.get(step, :items)), &fork_instruction_result?/1) do
        step.sequence
      end
    end)
  end

  defp fork_instruction_result?(item) do
    History.item_type(item) == :tool_result and
      Enum.any?(History.opaque_payloads(item), fn opaque ->
        case Map.get(opaque, "raw") do
          %{"fork_instruction" => %{"subagent" => true}} -> true
          _other -> match?(%{"subagent" => true}, Map.get(opaque, "fork_instruction"))
        end
      end)
  end

  defp answer_text_from_trace(step) when is_map(step) do
    step
    |> trace_value(:items, [])
    |> List.wrap()
    |> Enum.sort_by(&(trace_value(&1, :sequence) || 0))
    |> Enum.filter(&History.assistant_answer_item?/1)
    |> Enum.map(&History.item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp answer_text_from_trace(_step), do: ""

  defp append_answer(answers, answer) when is_binary(answer) do
    if String.trim(answer) == "", do: answers, else: answers ++ [answer]
  end

  defp join_answers(answers) when is_list(answers), do: Enum.join(answers, "\n\n")

  defp answer_progress(answer, cursor, reference) when is_binary(answer) do
    {offset, mode} = cursor_offset(cursor, answer, reference)
    remaining = binary_part(answer, offset, byte_size(answer) - offset)
    delta = valid_answer_prefix(remaining, @progress_page_max_bytes)
    next_offset = offset + byte_size(delta)
    next_cursor = encode_cursor(answer, next_offset, reference)

    progress =
      if delta == "" do
        []
      else
        [%{type: "answer", text: delta, mode: mode, cursor: next_cursor}]
      end

    {progress, next_cursor}
  end

  defp cursor_offset(nil, _answer, _reference), do: {0, "replace"}
  defp cursor_offset("", _answer, _reference), do: {0, "replace"}

  defp cursor_offset(cursor, answer, reference) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{} = payload} <- Jason.decode(decoded),
         true <- payload["message_id"] == reference.generation_message_id,
         offset when is_integer(offset) and offset >= 0 <- payload["offset"],
         true <- offset <= byte_size(answer),
         prefix = binary_part(answer, 0, offset),
         true <- payload["digest"] == answer_digest(prefix) do
      {offset, "append"}
    else
      _other -> {0, "replace"}
    end
  end

  defp cursor_offset(_cursor, _answer, _reference), do: {0, "replace"}

  defp encode_cursor(answer, offset, reference)
       when is_binary(answer) and is_integer(offset) and offset >= 0 do
    offset = min(offset, byte_size(answer))
    prefix = binary_part(answer, 0, offset)

    %{
      "message_id" => reference.generation_message_id,
      "offset" => offset,
      "digest" => answer_digest(prefix)
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp answer_digest(text) when is_binary(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp valid_answer_prefix(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp valid_answer_prefix(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    prefix = binary_part(text, 0, max(max_bytes, 0))

    if String.valid?(prefix) do
      prefix
    else
      1..4
      |> Enum.reduce_while("", fn trim, _fallback ->
        size = max(max_bytes - trim, 0)
        candidate = binary_part(text, 0, size)

        if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, ""}
      end)
    end
  end

  defp snapshot_result(reference, %{status: :completed, final: final}) when is_map(final) do
    text = final_text(final)

    %{
      text: text,
      raw: %{
        "fork" => %{
          "chat_id" => reference.chat_id,
          "message_id" => reference.message_id,
          "generation_message_id" => reference.generation_message_id,
          "final_chat_id" => final.chat_id,
          "final_message_id" => final.message_id,
          "chain" => final.chain,
          "url" => reference.url
        }
      }
    }
  end

  defp snapshot_result(_reference, _state), do: nil

  defp execution_result_from_snapshot(%{status: :completed, result: result})
       when is_map(result) do
    %ExecutionResult{
      text: to_string(Map.get(result, :text, "")),
      raw: Map.get(result, :raw, %{}),
      media: [],
      artifacts: []
    }
  end

  defp execution_result_from_snapshot(%{status: status, error: error})
       when status in [:failed, :canceled] do
    error_result(error)
  end

  defp sync_execution_result_from_snapshot(%{status: :completed} = snapshot, actor) do
    result = execution_result_from_snapshot(snapshot)
    final_message_id = get_in(result.raw, ["fork", "final_message_id"])

    case final_message_id do
      message_id when is_integer(message_id) and message_id > 0 ->
        message = load_final_message!(message_id, actor)

        text =
          message
          |> History.project_text_for_item_types(History.assistant_answer_item_types())
          |> case do
            value when is_binary(value) and value != "" -> final_text(%{text: value})
            _other -> result.text
          end

        %{result | text: text}

      _other ->
        result
    end
  end

  defp sync_execution_result_from_snapshot(snapshot, _actor) do
    execution_result_from_snapshot(snapshot)
  end

  defp background_execution_result(%{status: :completed} = snapshot) do
    {:completed, execution_result_from_snapshot(snapshot)}
  end

  defp background_execution_result(%{status: :failed, error: error}), do: {:failed, error}

  defp background_execution_result(%{status: :canceled}), do: :canceled

  defp handoff_generation_message_id(%ChatMessage{} = message) do
    message
    |> ordered_items()
    |> Enum.filter(&(&1.type == :tool_result))
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

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp set_background_reference(task_record, reference) when is_map(reference) do
    case apply(IntellectualClub.BackgroundTasks, :set_fork_reference, [task_record, reference]) do
      :ok -> :ok
      {:ok, _task} -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_background_reference_result, other}}
    end
  end

  defp background_reference(task_record) do
    owner_id = task_record_value(task_record, :owner_id)
    chat_id = task_record_value(task_record, :target_chat_id)

    runner_ref = task_record_value(task_record, :runner_ref) || %{}

    stored_message_id =
      Map.get(runner_ref, "fork_message_id") ||
        Map.get(runner_ref, "fork_generation_message_id")

    stored_generation_message_id =
      Map.get(runner_ref, "fork_generation_message_id") || stored_message_id

    stored_url = Map.get(runner_ref, "fork_url")

    cond do
      not is_integer(owner_id) or owner_id <= 0 ->
        {:error, :invalid_owner}

      not is_integer(chat_id) or chat_id <= 0 ->
        {:error, :target_not_ready}

      true ->
        actor = %User{id: owner_id}

        with {:ok, %Chat{} = chat} <- fetch_owned_chat(chat_id, actor),
             message_id = stored_message_id || chat.last_message_id,
             generation_message_id = stored_generation_message_id || message_id,
             true <- is_integer(message_id) and message_id > 0,
             true <- is_integer(generation_message_id) and generation_message_id > 0 do
          reference =
            chat
            |> fork_reference(message_id, generation_message_id)
            |> Map.put(:url, stored_url || "/chats/#{chat.id}")

          {:ok, reference, actor}
        else
          false -> {:error, :target_not_ready}
          {:error, _reason} = error -> error
        end
    end
  end

  defp task_record_value(%BackgroundTask{} = task_record, key) when is_atom(key) do
    case Map.get(task_record, key) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end

  defp task_record_value(_task_record, _key), do: nil

  defp trace_value(value, key, default \\ nil)

  defp trace_value(value, key, default) when is_map(value) and is_atom(key) do
    Map.get(value, key, default)
  end

  defp trace_value(_value, _key, default), do: default

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
    |> Enum.count(&(&1.parent_relation_kind == @relation_kind))
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
    Map.get(config, key, default)
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
