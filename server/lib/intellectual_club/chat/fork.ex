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
  alias IntellectualClub.Chat.Subagent
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
         result = Subagent.sync_execution_result_from_snapshot(snapshot, actor),
         :ok <- persist_parent_tool_result(context, result) do
      {:ok, result}
    else
      {:error, {:fork_result, message}} ->
        result = Subagent.error_result(message)

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
           find_or_create_subagent(tool_instance, source_context, context, actor, opts),
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
    case Subagent.snapshot(reference, actor, cursor) do
      {:error, :invalid_subagent_reference} -> {:error, :invalid_fork_reference}
      other -> other
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
             background_task_authority: task_record,
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
    Subagent.await_background_snapshot(reference, actor, &snapshot/3)
  end

  @doc false
  @impl true
  def snapshot_background(task_record, cursor) do
    case background_reference(task_record) do
      {:ok, reference, actor} ->
        if background_execution_owns_recovery?(task_record, reference) do
          :default
        else
          snapshot(reference, actor, cursor)
        end

      {:error, :target_not_ready} ->
        :default

      {:error, _reason} = error ->
        error
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
    Subagent.ensure_handoff_allowed(tool_instance, context)
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
         {:ok, branch} <- MessageTreeCopy.materialize_loaded_messages(branch, actor),
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
         actor,
         opts
       ) do
    with nil <- fetch_fork_chat_by_tool_call_item_id(context.tool_call_item_id, actor),
         {:legacy, nil} <- {:legacy, claim_legacy_fork_chat(source_context, context, actor)},
         :ok <- ensure_fork_allowed(tool_instance, source_context.source, actor) do
      create_or_recover_subagent_state(source_context, context, actor, opts)
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

  defp create_or_recover_subagent_state(source_context, context, actor, opts) do
    case create_subagent_state(source_context, context, actor, opts) do
      {:ok, fork_state} ->
        {:ok, {:new, fork_state}}

      {:error, error} ->
        recover_created_subagent_race(error, context.tool_call_item_id, actor)
    end
  rescue
    exception ->
      if parent_tool_call_unique_constraint_error?(exception) do
        case fetch_fork_chat_by_tool_call_item_id(context.tool_call_item_id, actor) do
          %Chat{} = chat -> {:ok, {:existing, chat}}
          nil -> reraise exception, __STACKTRACE__
        end
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp recover_created_subagent_race(error, tool_call_item_id, actor) do
    if parent_tool_call_unique_constraint_error?(error) do
      case fetch_fork_chat_by_tool_call_item_id(tool_call_item_id, actor) do
        %Chat{} = chat -> {:ok, {:existing, chat}}
        nil -> {:error, error}
      end
    else
      {:error, error}
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

  defp parent_tool_call_unique_constraint_error?(%{private_vars: vars}) when is_map(vars) do
    Map.get(vars, :constraint) == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(%{postgres: %{constraint: constraint}}) do
    constraint == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(%{constraint: constraint}) do
    constraint == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(%{error: error}) do
    parent_tool_call_unique_constraint_error?(error)
  end

  defp parent_tool_call_unique_constraint_error?(%{reason: reason}) do
    parent_tool_call_unique_constraint_error?(reason)
  end

  defp parent_tool_call_unique_constraint_error?(%RuntimeError{message: message})
       when is_binary(message) do
    String.contains?(message, @parent_tool_call_unique_constraint)
  end

  defp parent_tool_call_unique_constraint_error?(_error), do: false

  defp create_subagent_state(source_context, %ExecutionContext{} = context, actor, opts) do
    Subagent.with_invocation_authority(context, opts, fn ->
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

        _locked_message =
          ChatMessage
          |> Ash.Query.filter(id == ^copied_message_id)
          |> Ash.Query.lock(:for_update)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(actor: actor)

        generation_context =
          IntellectualClub.Generation.Context.build_prepared!(
            chat.id,
            copied_message_id,
            copied_step.id,
            copied_step.raw_request || %{},
            actor: actor,
            available_file_external_ids: context.available_file_external_ids || []
          )

        followup =
          generation_context.adapter_module.build_followup_request(%{
            context: generation_context,
            runtime_step: followup_state.runtime_step,
            results: [result],
            tools:
              generation_context.tools_payload ||
                RequestPayload.tools(copied_step.raw_request || %{})
          })

        :ok = Persistence.mark_step_done!(copied_step.id)

        generation_step_id =
          Persistence.ensure_step_started!(
            copied_message_id,
            copied_step.sequence + 1,
            followup.raw_request || %{},
            started_at: DateTime.utc_now()
          )

        %{
          chat: Ash.get!(Chat, chat.id, actor: actor, load: [:last_message]),
          message_id: copied_message_id,
          generation_step_id: generation_step_id,
          generation_step_raw_request: followup.raw_request || %{}
        }
      end)
      |> unwrap_transaction()
    end)
  end

  defp start_subagent_reference(
         {:new, fork_state},
         %ExecutionContext{} = parent_context,
         actor,
         opts
       ) do
    reference = fork_reference(fork_state.chat, fork_state.message_id, fork_state.message_id)

    Subagent.start_invocation(
      parent_context,
      reference,
      opts,
      &cancel_reference_generation(&1, actor),
      fn ->
        case start_subagent_generation(fork_state, parent_context, actor) do
          {:ok, generation} ->
            {:ok, %{reference | generation_message_id: generation.message_id}}

          {:error, _reason} = error ->
            error
        end
      end
    )
  end

  defp start_subagent_reference(
         {:existing, %Chat{} = chat},
         %ExecutionContext{} = parent_context,
         actor,
         opts
       ) do
    with {:ok, message_id} <- fork_generation_message_id(chat, actor),
         reference = fork_reference(chat, message_id, message_id) do
      Subagent.start_invocation(
        parent_context,
        reference,
        opts,
        &cancel_reference_generation(&1, actor),
        fn ->
          case resume_fork_generation_if_needed(message_id, parent_context, actor) do
            :ok -> {:ok, reference}
            {:error, _reason} = error -> error
          end
        end
      )
    end
  end

  defp cancel_reference_generation(reference, actor) when is_map(reference) do
    Subagent.cancel_reference_generation(reference, actor)
  end

  defp fork_reference(%Chat{} = chat, message_id, generation_message_id) do
    %{
      primitive: :fork,
      chat_id: chat.id,
      message_id: message_id,
      generation_message_id: generation_message_id,
      url: "/chats/#{chat.id}"
    }
  end

  defp start_subagent_generation(fork_state, %ExecutionContext{} = parent_context, actor) do
    case start_prepared_fork_generation(
           fork_state.chat.id,
           fork_state.message_id,
           fork_state.generation_step_id,
           fork_state.generation_step_raw_request,
           parent_context,
           actor
         ) do
      :ok ->
        {:ok, %{message_id: fork_state.message_id, step_id: fork_state.generation_step_id}}

      {:error, _reason} = error ->
        error
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

  defp resume_fork_generation_if_needed(
         message_id,
         %ExecutionContext{} = parent_context,
         actor
       )
       when is_integer(message_id) do
    case Ash.get(ChatMessage, message_id, actor: actor) do
      {:ok, %ChatMessage{chat_id: chat_id, status: :generating}} ->
        case reusable_waiting_provider_step(message_id, actor) do
          %ChatMessageStep{} = step ->
            start_prepared_fork_generation(
              chat_id,
              message_id,
              step.id,
              step.raw_request || %{},
              parent_context,
              actor
            )

          nil ->
            Subagent.resume_generation_if_needed(message_id, actor)
        end

      {:ok, %ChatMessage{}} ->
        :ok

      {:ok, nil} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_prepared_fork_generation(
         chat_id,
         message_id,
         step_id,
         raw_request,
         %ExecutionContext{} = parent_context,
         actor
       ) do
    case GenerationSupervisor.start_prepared_generation(
           chat_id,
           message_id,
           step_id,
           raw_request || %{},
           actor: actor,
           available_file_external_ids: parent_context.available_file_external_ids || []
         ) do
      {:ok, _context} ->
        :ok

      {:error, :already_running} ->
        :ok

      {:error, :invalid_status} = error ->
        if canonical_generation_started_or_terminal?(message_id, actor), do: :ok, else: error

      {:error, _reason} = error ->
        error
    end
  end

  defp canonical_generation_started_or_terminal?(message_id, actor) do
    case Ash.get(ChatMessage, message_id, actor: actor) do
      {:ok, %ChatMessage{status: status}} when status in [:done, :error] ->
        true

      {:ok, %ChatMessage{status: :generating}} ->
        GenerationSupervisor.get_generation_state(message_id) != :not_found

      _other ->
        false
    end
  end

  defp reusable_waiting_provider_step(message_id, actor) when is_integer(message_id) do
    step =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^message_id)
      |> Ash.Query.sort(sequence: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: actor)

    case step do
      %ChatMessageStep{status: :waiting_provider} = step ->
        case Persistence.steering_specs_for_step!(step.id) do
          [] -> step
          _steering -> nil
        end

      _other ->
        nil
    end
  end

  defp persist_parent_tool_result(
         %ExecutionContext{} = parent_context,
         %ExecutionResult{} = result
       ) do
    Subagent.persist_parent_tool_result(parent_context, result)
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

  @doc false
  def await_snapshot(reference, actor) do
    Subagent.await_snapshot(reference, actor, &snapshot/3)
  end

  @doc false
  defdelegate execution_result_from_snapshot(snapshot), to: Subagent

  @doc false
  defdelegate sync_execution_result_from_snapshot(snapshot, actor), to: Subagent

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

    cond do
      not is_integer(owner_id) or owner_id <= 0 ->
        {:error, :invalid_owner}

      true ->
        actor = %User{id: owner_id}

        case stored_background_reference(chat_id, runner_ref, actor) do
          {:ok, reference} -> {:ok, reference, actor}
          {:error, _reason} -> fallback_background_reference(task_record, actor)
        end
    end
  end

  defp stored_background_reference(chat_id, runner_ref, actor)
       when is_integer(chat_id) and chat_id > 0 and is_map(runner_ref) do
    stored_message_id =
      Map.get(runner_ref, "fork_message_id") ||
        Map.get(runner_ref, "fork_generation_message_id")

    stored_generation_message_id =
      Map.get(runner_ref, "fork_generation_message_id") || stored_message_id

    with {:ok, %Chat{} = chat} <- fetch_owned_chat(chat_id, actor),
         message_id = stored_message_id || chat.last_message_id,
         generation_message_id = stored_generation_message_id || message_id,
         true <- is_integer(message_id) and message_id > 0,
         true <- is_integer(generation_message_id) and generation_message_id > 0 do
      {:ok,
       chat
       |> fork_reference(message_id, generation_message_id)
       |> Map.put(:url, Map.get(runner_ref, "fork_url") || "/chats/#{chat.id}")}
    else
      false -> {:error, :target_not_ready}
      {:error, _reason} = error -> error
    end
  end

  defp stored_background_reference(_chat_id, _runner_ref, _actor),
    do: {:error, :target_not_ready}

  defp fallback_background_reference(task_record, actor) do
    source_tool_call_item_id = task_record_value(task_record, :source_tool_call_item_id)

    with tool_call_item_id when is_integer(tool_call_item_id) and tool_call_item_id > 0 <-
           source_tool_call_item_id,
         %Chat{} = chat <- fetch_fork_chat_by_tool_call_item_id(tool_call_item_id, actor),
         {:ok, message_id} <- fork_generation_message_id(chat, actor) do
      {:ok, fork_reference(chat, message_id, message_id), actor}
    else
      _other -> {:error, :target_not_ready}
    end
  end

  defp background_execution_owns_recovery?(task_record, reference)
       when is_map(reference) do
    task_id = task_record_value(task_record, :id)
    generation_message_id = Map.get(reference, :generation_message_id)

    is_binary(task_id) and
      IntellectualClub.BackgroundTasks.worker_active?(task_id) and
      is_integer(generation_message_id) and
      GenerationSupervisor.get_generation_state(generation_message_id) == :not_found
  end

  defp task_record_value(%BackgroundTask{} = task_record, key) when is_atom(key) do
    case Map.get(task_record, key) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end

  defp task_record_value(_task_record, _key), do: nil

  defp ensure_fork_allowed(%ToolInstance{} = tool_instance, %Chat{} = chat, actor) do
    Subagent.ensure_creation_allowed(tool_instance, chat, actor)
  end

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
