defmodule IntellectualClub.Chat.Subagent do
  @moduledoc """
  Shared policy and lifecycle helpers for linked subagent chats.

  Fork and spawn use different preparation strategies, but they share nesting,
  handoff, synchronous waiting, and durable reference callback semantics.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.ToolCall
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @creation_relation_kinds [:fork, :spawn]
  @max_parent_hops 64
  @max_wait_retry_ms 5_000
  @progress_page_max_bytes 48_000
  @parent_tool_result_unique_constraint "chat_message_items_unique_step_sequence_index"
  @parent_tool_result_race_retries 1

  @doc false
  @spec with_parent_generation_fence(ExecutionContext.t(), (-> result)) ::
          result | {:error, term()}
        when result: term()
  def with_parent_generation_fence(
        %ExecutionContext{generation_fence_token: fence_token} = context,
        fun
      )
      when is_binary(fence_token) and is_function(fun, 0) do
    message_id = context.message_id || context.assistant_message_id

    fence_result =
      if is_integer(context.chat_id) do
        Lease.with_token_chat_fence(message_id, context.chat_id, fence_token, fun,
          allowed_statuses: [:generating],
          required_role: :assistant
        )
      else
        Lease.with_token_fence(message_id, fence_token, fun,
          allowed_statuses: [:generating],
          required_role: :assistant
        )
      end

    case fence_result do
      {:ok, result} ->
        result

      {:error, reason} when reason in [:lease_lost, :invalid_status, :invalid_role, :not_found] ->
        {:error, :parent_generation_stale}

      {:error, _reason} = error ->
        error
    end
  end

  def with_parent_generation_fence(
        %ExecutionContext{generation_fence_token: nil},
        fun
      )
      when is_function(fun, 0),
      do: fun.()

  def with_parent_generation_fence(%ExecutionContext{}, _fun),
    do: {:error, :invalid_parent_generation_fence}

  @doc false
  @spec with_invocation_authority(ExecutionContext.t(), keyword(), (-> result)) ::
          result | {:error, term()}
        when result: term()
  def with_invocation_authority(%ExecutionContext{} = context, opts, fun)
      when is_list(opts) and is_function(fun, 0) do
    case Keyword.fetch(opts, :background_task_authority) do
      {:ok, %BackgroundTask{} = task} ->
        BackgroundTasks.with_active_task_authority(task, context, fun)

      {:ok, _invalid_authority} ->
        {:error, :invalid_background_task_authority}

      :error ->
        with_parent_generation_fence(context, fun)
    end
  end

  def with_invocation_authority(_context, _opts, _fun),
    do: {:error, :invalid_invocation_authority}

  @doc """
  Commits invocation authority and the durable reference before provider work starts.

  Returned reference or provider-start failures cancel the prepared child generation.
  Process exits and throws are intentionally allowed to escape so durable preparation can
  be recovered after a crash.
  """
  @spec start_invocation(
          ExecutionContext.t(),
          map(),
          keyword(),
          (map() -> any()),
          (-> {:ok, map()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def start_invocation(
        %ExecutionContext{} = context,
        reference,
        opts,
        cancel_fun,
        provider_start_fun
      )
      when is_map(reference) and is_list(opts) and is_function(cancel_fun, 1) and
             is_function(provider_start_fun, 0) do
    with :ok <-
           with_invocation_authority(context, opts, fn ->
             commit_reference(reference, opts)
           end),
         {:ok, %{} = started_reference} <- provider_start_fun.() do
      {:ok, started_reference}
    else
      {:error, _reason} = error ->
        cancel_fun.(reference)
        error

      other ->
        cancel_fun.(reference)
        {:error, {:invalid_provider_start_result, other}}
    end
  end

  def start_invocation(_context, _reference, _opts, _cancel_fun, _provider_start_fun),
    do: {:error, :invalid_subagent_invocation}

  @spec ensure_creation_allowed(ToolInstance.t(), Chat.t(), map()) ::
          :ok | {:error, String.t()}
  def ensure_creation_allowed(%ToolInstance{} = tool_instance, %Chat{} = chat, actor) do
    limit = nested_subchats_limit(tool_instance)

    case creation_depth_up_to(chat, actor, limit) do
      {:ok, depth} when depth <= limit ->
        :ok

      _exceeded_or_invalid_chain ->
        {:error,
         "Nested subchat creation is unavailable for this subagent. " <>
           "Continue working on the task yourself without creating another subchat."}
    end
  end

  @doc false
  @spec preflight_creation_allowed(ToolInstance.t(), ExecutionContext.t()) ::
          :ok | {:error, String.t()}
  def preflight_creation_allowed(
        %ToolInstance{} = tool_instance,
        %ExecutionContext{} = context
      ) do
    actor = actor_from_context(context)

    case {actor, context.chat_id} do
      {%User{} = actor, chat_id} when is_integer(chat_id) ->
        case fetch_owned_chat(chat_id, actor) do
          {:ok, %Chat{} = chat} -> ensure_creation_allowed(tool_instance, chat, actor)
          _other -> :ok
        end

      _other ->
        :ok
    end
  end

  def preflight_creation_allowed(_tool_instance, _context), do: :ok

  @spec ensure_handoff_allowed(ToolInstance.t(), ExecutionContext.t()) ::
          :ok | {:error, String.t()}
  def ensure_handoff_allowed(%ToolInstance{} = tool_instance, %ExecutionContext{} = context) do
    actor = actor_from_context(context)

    cond do
      is_nil(actor) or not is_integer(context.chat_id) ->
        :ok

      allow_handoff_in_subchats?(tool_instance) ->
        :ok

      true ->
        case fetch_owned_chat(context.chat_id, actor) do
          {:ok, %Chat{subagent: true}} ->
            {:error, "Handoff is disabled inside subagent chats."}

          _other ->
            :ok
        end
    end
  end

  def ensure_handoff_allowed(_tool_instance, _context), do: :ok

  @spec await_snapshot(map(), map(), (map(), map(), nil -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def await_snapshot(reference, actor, snapshot_fun)
      when is_map(reference) and is_function(snapshot_fun, 3) do
    with {:ok, normalized_reference} <- normalize_reference(reference, actor) do
      do_await_snapshot(reference, normalized_reference, actor, snapshot_fun, 0)
    end
  end

  @doc false
  @spec await_snapshot(map(), User.t()) :: {:ok, map()} | {:error, term()}
  def await_snapshot(reference, %User{} = actor) when is_map(reference) do
    await_snapshot(reference, actor, &snapshot/3)
  end

  @doc false
  @spec reconcile_background_wait(map(), User.t(), (map(), User.t(), nil -> term())) ::
          {:waiting, %{generation_message_id: pos_integer(), pid: pid()}}
          | {:retry, term()}
          | {:completed, ExecutionResult.t()}
          | {:failed, term()}
          | :canceled
          | {:error, term()}
  def reconcile_background_wait(reference, actor, snapshot_fun \\ &snapshot/3)

  def reconcile_background_wait(reference, %User{} = actor, snapshot_fun)
      when is_map(reference) and is_function(snapshot_fun, 3) do
    do_reconcile_background_wait(reference, actor, snapshot_fun, resume?: true)
  end

  @doc false
  @spec reconcile_background_wait_read_only(
          map(),
          User.t(),
          (map(), User.t(), nil -> term())
        ) ::
          {:waiting, %{generation_message_id: pos_integer(), pid: pid()}}
          | {:retry, term()}
          | {:completed, ExecutionResult.t()}
          | {:failed, term()}
          | :canceled
          | {:error, term()}
  def reconcile_background_wait_read_only(reference, actor, snapshot_fun \\ &snapshot/3)

  def reconcile_background_wait_read_only(reference, %User{} = actor, snapshot_fun)
      when is_map(reference) and is_function(snapshot_fun, 3) do
    do_reconcile_background_wait(reference, actor, snapshot_fun, resume?: false)
  end

  defp do_reconcile_background_wait(reference, actor, snapshot_fun, opts) do
    with {:ok, normalized_reference} <- normalize_reference(reference, actor),
         {:ok, state} <-
           resolve_wait_chain(normalized_reference.generation_message_id, actor, opts) do
      case state do
        %{status: :running, generation_message_id: message_id, pid: pid}
        when is_integer(message_id) and is_pid(pid) ->
          {:waiting, %{generation_message_id: message_id, pid: pid}}

        %{status: :retry, generation_message_id: message_id} ->
          {:retry, {:generation_worker_not_ready, message_id}}

        %{status: status} when status in [:completed, :failed, :canceled] ->
          case snapshot_fun.(reference, actor, nil) do
            {:ok, terminal} -> background_execution_result(terminal)
            {:error, _reason} = error -> error
          end
      end
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  @spec await_background_snapshot(map(), User.t(), (map(), User.t(), nil -> term())) ::
          {:completed, ExecutionResult.t()} | {:failed, term()} | :canceled | {:error, term()}
  def await_background_snapshot(reference, actor, snapshot_fun \\ &snapshot/3)

  def await_background_snapshot(reference, %User{} = actor, snapshot_fun)
      when is_map(reference) and is_function(snapshot_fun, 3) do
    case await_snapshot(reference, actor, snapshot_fun) do
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

  @doc """
  Returns a non-blocking, answer-only snapshot for any subagent reference.

  Handoff targets are followed without changing creation depth. The cursor is
  opaque and falls back to a full replacement when the observed answer changes.
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

  def snapshot(_reference, _actor, _cursor), do: {:error, :invalid_subagent_reference}

  @doc """
  Resolves the effective generation lifecycle for fork and spawn subchats.

  Persisted handoff tool results are followed in batches without resuming orphaned
  generation workers. The returned map is keyed by the original subchat id.
  """
  @spec lifecycle_states([Chat.t()], User.t()) :: %{optional(pos_integer()) => map()}
  def lifecycle_states(chats, %User{} = actor) when is_list(chats) do
    pending =
      chats
      |> Enum.reduce([], fn
        %Chat{
          id: chat_id,
          subagent: true,
          parent_relation_kind: relation_kind,
          last_message: %ChatMessage{id: message_id}
        },
        acc
        when is_integer(chat_id) and relation_kind in @creation_relation_kinds and
               is_integer(message_id) ->
          [
            %{
              root_chat_id: chat_id,
              message_id: message_id,
              depth: 0,
              visited: MapSet.new()
            }
            | acc
          ]

        _chat, acc ->
          acc
      end)
      |> Enum.reverse()

    resolve_lifecycle_states(pending, actor, %{})
  end

  def lifecycle_states(_chats, _actor), do: %{}

  @doc false
  @spec resume_generation_if_needed(pos_integer(), User.t()) :: :ok | {:error, term()}
  def resume_generation_if_needed(message_id, %User{} = actor) when is_integer(message_id) do
    message = Ash.get!(ChatMessage, message_id, actor: actor)

    resume_loaded_generation_if_needed(message, actor)
  end

  defp resume_loaded_generation_if_needed(%ChatMessage{} = message, actor) do
    if message.status == :generating and
         is_nil(GenerationSupervisor.generation_worker_pid(message.id)) do
      case GenerationSupervisor.resume_orphaned_message(message.id, actor: actor) do
        {:ok, _context} ->
          :ok

        {:error, reason} when reason in [:already_running, :invalid_status] ->
          :ok

        {:error, :no_steps_to_retry} ->
          case QueueCoordinator.cancel_generation(message.id,
                 error_detail: "Orphaned generation (worker not found)"
               ) do
            result when result in [:canceled, :not_generating, :not_found] -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, "Failed to resume subagent: #{inspect(reason)}"}
      end
    else
      :ok
    end
  end

  @doc false
  @spec cancel_reference_generation(map(), User.t()) :: :ok
  def cancel_reference_generation(reference, %User{} = actor) when is_map(reference) do
    message_id = Map.get(reference, :generation_message_id)

    case GenerationSupervisor.cancel_generation(message_id,
           include_background_tasks?: true,
           cancel_orphaned?: true
         ) do
      :not_found ->
        case Ash.get(ChatMessage, message_id, actor: actor) do
          {:ok, %ChatMessage{status: :generating}} ->
            _ =
              QueueCoordinator.cancel_generation(message_id,
                error_detail: "Orphaned generation (worker not found)"
              )

          _other ->
            :ok
        end

      _other ->
        :ok
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  @spec execution_result_from_snapshot(map()) :: ExecutionResult.t()
  def execution_result_from_snapshot(%{status: :completed, result: result})
      when is_map(result) do
    %ExecutionResult{
      text: to_string(Map.get(result, :text, "")),
      raw: Map.get(result, :raw, %{}),
      media: [],
      artifacts: []
    }
  end

  def execution_result_from_snapshot(%{status: status, error: error})
      when status in [:failed, :canceled] do
    error_result(error)
  end

  @doc false
  @spec sync_execution_result_from_snapshot(map(), User.t()) :: ExecutionResult.t()
  def sync_execution_result_from_snapshot(%{status: :completed} = snapshot, actor) do
    result = execution_result_from_snapshot(snapshot)

    final_message_id =
      result.raw
      |> Map.values()
      |> Enum.find_value(fn
        %{"final_message_id" => message_id} when is_integer(message_id) -> message_id
        _other -> nil
      end)

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

  def sync_execution_result_from_snapshot(snapshot, _actor) do
    execution_result_from_snapshot(snapshot)
  end

  @doc false
  @spec error_result(term()) :: ExecutionResult.t()
  def error_result(reason) do
    text = to_string(reason || "Subagent generation failed.")

    %ExecutionResult{
      text: text,
      raw: %{"isError" => true, "error" => text},
      media: [],
      artifacts: []
    }
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
         primitive: normalize_primitive(Map.get(reference, :primitive)),
         chat_id: chat.id,
         message_id: if(is_integer(message_id), do: message_id, else: generation_message_id),
         generation_message_id: generation_message_id,
         prompt_message_id: normalize_optional_id(Map.get(reference, :prompt_message_id)),
         url: Map.get(reference, :url) || "/chats/#{chat.id}"
       }}
    else
      false -> {:error, :invalid_subagent_reference}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_subagent_reference}
    end
  end

  defp do_await_snapshot(reference, normalized_reference, actor, snapshot_fun, retry_attempt) do
    case resolve_wait_chain(normalized_reference.generation_message_id, actor) do
      {:ok, %{status: :running, pid: pid} = state} when is_pid(pid) ->
        await_generation_process(
          reference,
          normalized_reference,
          actor,
          snapshot_fun,
          state,
          retry_attempt
        )

      {:ok, %{status: :retry}} ->
        receive do
        after
          wait_retry_delay(retry_attempt) ->
            do_await_snapshot(
              reference,
              normalized_reference,
              actor,
              snapshot_fun,
              retry_attempt + 1
            )
        end

      {:ok, %{status: status}} when status in [:completed, :failed, :canceled] ->
        case snapshot_fun.(reference, actor, nil) do
          {:ok, %{status: :running}} ->
            do_await_snapshot(reference, normalized_reference, actor, snapshot_fun, 0)

          {:ok, %{status: terminal_status} = snapshot}
          when terminal_status in [:completed, :failed, :canceled] ->
            {:ok, snapshot}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp await_generation_process(
         reference,
         normalized_reference,
         actor,
         snapshot_fun,
         %{generation_message_id: message_id, pid: pid},
         retry_attempt
       ) do
    monitor_ref = Process.monitor(pid)

    case resolve_wait_chain(normalized_reference.generation_message_id, actor) do
      {:ok, %{status: :running, generation_message_id: ^message_id, pid: ^pid}} ->
        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
            do_await_snapshot(reference, normalized_reference, actor, snapshot_fun, 0)
        end

      other ->
        Process.demonitor(monitor_ref, [:flush])

        continue_await_after_observation(
          other,
          reference,
          normalized_reference,
          actor,
          snapshot_fun,
          retry_attempt
        )
    end
  end

  defp continue_await_after_observation(
         {:ok, %{status: status}},
         reference,
         normalized_reference,
         actor,
         snapshot_fun,
         retry_attempt
       )
       when status in [:running, :retry, :completed, :failed, :canceled] do
    do_await_snapshot(
      reference,
      normalized_reference,
      actor,
      snapshot_fun,
      retry_attempt
    )
  end

  defp continue_await_after_observation(
         {:error, _reason} = error,
         _reference,
         _normalized_reference,
         _actor,
         _snapshot_fun,
         _retry_attempt
       ),
       do: error

  defp wait_retry_delay(attempt) when is_integer(attempt) and attempt >= 0 do
    min(@max_wait_retry_ms, trunc(:math.pow(2, min(attempt, 8))) * 25)
  end

  defp resolve_wait_chain(message_id, actor, opts \\ []) when is_integer(message_id) do
    do_resolve_wait_chain(message_id, actor, MapSet.new(), 0, opts)
  end

  defp do_resolve_wait_chain(_message_id, _actor, _visited, depth, _opts)
       when depth >= @max_parent_hops do
    {:ok, %{status: :failed, error: "Subagent handoff chain exceeded the supported depth."}}
  end

  defp do_resolve_wait_chain(message_id, actor, visited, depth, opts)
       when is_integer(message_id) do
    if MapSet.member?(visited, message_id) do
      {:ok, %{status: :failed, error: "Subagent handoff chain contains a cycle."}}
    else
      case load_wait_message(message_id, actor) do
        {:ok, %ChatMessage{} = message} ->
          resolve_wait_message(message, actor, visited, depth, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp resolve_wait_message(
         %ChatMessage{status: :generating} = message,
         actor,
         visited,
         depth,
         opts
       ) do
    case GenerationSupervisor.generation_worker_pid(message.id) do
      pid when is_pid(pid) ->
        {:ok, %{status: :running, generation_message_id: message.id, pid: pid}}

      nil ->
        if Keyword.get(opts, :resume?, true) do
          with :ok <- resume_loaded_generation_if_needed(message, actor) do
            case GenerationSupervisor.generation_worker_pid(message.id) do
              pid when is_pid(pid) ->
                {:ok, %{status: :running, generation_message_id: message.id, pid: pid}}

              nil ->
                case load_wait_message(message.id, actor) do
                  {:ok, %ChatMessage{status: :generating}} ->
                    {:ok, %{status: :retry, generation_message_id: message.id}}

                  {:ok, %ChatMessage{} = refreshed} ->
                    resolve_wait_message(refreshed, actor, visited, depth, opts)

                  {:error, _reason} = error ->
                    error
                end
            end
          end
        else
          {:ok, %{status: :retry, generation_message_id: message.id}}
        end
    end
  end

  defp resolve_wait_message(%ChatMessage{status: :done} = message, actor, visited, depth, opts) do
    case Ash.load(message, lifecycle_message_load(), actor: actor, strict?: true) do
      {:ok, %ChatMessage{} = loaded} ->
        case handoff_generation_message_id(loaded) do
          id when is_integer(id) and id > 0 ->
            do_resolve_wait_chain(id, actor, MapSet.put(visited, loaded.id), depth + 1, opts)

          _other ->
            {:ok, %{status: :completed, generation_message_id: loaded.id}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_wait_message(
         %ChatMessage{status: :error} = message,
         _actor,
         _visited,
         _depth,
         _opts
       ) do
    {:ok,
     %{
       status: :failed,
       generation_message_id: message.id,
       error: message.error_detail || "Subagent generation failed."
     }}
  end

  defp resolve_wait_message(
         %ChatMessage{status: :canceled} = message,
         _actor,
         _visited,
         _depth,
         _opts
       ) do
    {:ok, %{status: :canceled, generation_message_id: message.id}}
  end

  defp resolve_wait_message(%ChatMessage{} = message, _actor, _visited, _depth, _opts) do
    {:ok,
     %{
       status: :failed,
       generation_message_id: message.id,
       error: "Subagent generation has an invalid status."
     }}
  end

  defp load_wait_message(message_id, actor) when is_integer(message_id) do
    Ash.get(ChatMessage, message_id, actor: actor)
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
      with :ok <- resume_generation_if_needed(message_id, actor) do
        message = load_final_message!(message_id, actor)
        message_answer = message_answer_text(message)
        answers = append_answer(answers, message_answer)

        case lifecycle_transition(message) do
          {:terminal, :generating} ->
            {:ok,
             %{
               status: :running,
               answer: join_answers(answers),
               final: nil,
               error: nil
             }}

          {:continue, id} ->
            chain = chain ++ [chain_entry(message)]

            do_resolve_snapshot_chain(
              id,
              actor,
              MapSet.put(visited, message_id),
              chain,
              answers
            )

          {:terminal, :done} ->
            chain = chain ++ [chain_entry(message)]

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

          {:terminal, :error} ->
            {:ok,
             %{
               status: :failed,
               answer: join_answers(answers),
               final: nil,
               error: message.error_detail || "Subagent generation failed."
             }}

          {:terminal, :canceled} ->
            {:ok,
             %{
               status: :canceled,
               answer: join_answers(answers),
               final: nil,
               error: "Subagent generation was canceled."
             }}

          {:terminal, :invalid} ->
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

  defp resolve_lifecycle_states([], _actor, states), do: states

  defp resolve_lifecycle_states(pending, actor, states) when is_list(pending) do
    messages_by_id = load_lifecycle_messages(pending, actor)

    {next_pending, states} =
      Enum.reduce(pending, {[], states}, fn entry, {pending_acc, states_acc} ->
        message = Map.get(messages_by_id, entry.message_id)

        cond do
          entry.depth >= @max_parent_hops ->
            {pending_acc, put_invalid_lifecycle_state(states_acc, entry)}

          MapSet.member?(entry.visited, entry.message_id) ->
            {pending_acc, put_invalid_lifecycle_state(states_acc, entry)}

          not match?(%ChatMessage{}, message) ->
            {pending_acc, put_invalid_lifecycle_state(states_acc, entry)}

          true ->
            case lifecycle_transition(message) do
              {:continue, next_message_id} ->
                next_entry = %{
                  entry
                  | message_id: next_message_id,
                    depth: entry.depth + 1,
                    visited: MapSet.put(entry.visited, message.id)
                }

                {[next_entry | pending_acc], states_acc}

              {:terminal, status} ->
                {pending_acc,
                 Map.put(
                   states_acc,
                   entry.root_chat_id,
                   lifecycle_state(message, status)
                 )}
            end
        end
      end)

    resolve_lifecycle_states(Enum.reverse(next_pending), actor, states)
  end

  defp load_lifecycle_messages(pending, actor) do
    message_ids = pending |> Enum.map(& &1.message_id) |> Enum.uniq()

    ChatMessage
    |> Ash.Query.filter(id in ^message_ids)
    |> Ash.Query.load(lifecycle_message_load(), strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, messages} -> Map.new(messages, &{&1.id, &1})
      {:error, _error} -> %{}
    end
  end

  defp lifecycle_message_load do
    [
      steps: [
        :sequence,
        items: [
          :sequence,
          :type,
          contents: [:sequence, :kind, :content_json]
        ]
      ]
    ]
  end

  defp lifecycle_transition(%ChatMessage{status: :done} = message) do
    case handoff_generation_message_id(message) do
      id when is_integer(id) and id > 0 -> {:continue, id}
      _other -> {:terminal, :done}
    end
  end

  defp lifecycle_transition(%ChatMessage{status: status})
       when status in [:generating, :error, :canceled],
       do: {:terminal, status}

  defp lifecycle_transition(%ChatMessage{}), do: {:terminal, :invalid}

  defp lifecycle_state(%ChatMessage{} = message, status) do
    normalized_status = if status == :invalid, do: :error, else: status

    %{
      message_id: message.id,
      chat_id: message.chat_id,
      active_generation_message_id:
        if(normalized_status == :generating, do: message.id, else: nil),
      last_message_status: normalized_status,
      updated_at: message.updated_at
    }
  end

  defp put_invalid_lifecycle_state(states, entry) do
    Map.put(states, entry.root_chat_id, %{
      message_id: entry.message_id,
      chat_id: nil,
      active_generation_message_id: nil,
      last_message_status: :error,
      updated_at: nil
    })
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
    primitive = normalize_primitive(Map.get(reference, :primitive))
    primitive_key = Atom.to_string(primitive)

    payload = %{
      "chat_id" => reference.chat_id,
      "message_id" => reference.message_id,
      "generation_message_id" => reference.generation_message_id,
      "final_chat_id" => final.chat_id,
      "final_message_id" => final.message_id,
      "chain" => final.chain,
      "url" => reference.url
    }

    payload =
      if primitive == :spawn do
        Map.put(payload, "prompt_message_id", Map.get(reference, :prompt_message_id))
      else
        payload
      end

    %{
      text: text,
      raw: %{
        primitive_key => payload
      }
    }
  end

  defp snapshot_result(_reference, _state), do: nil

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

  defp trace_value(value, key, default \\ nil)

  defp trace_value(value, key, default) when is_map(value) and is_atom(key) do
    Map.get(value, key, default)
  end

  defp trace_value(_value, _key, default), do: default

  defp normalize_primitive(:spawn), do: :spawn
  defp normalize_primitive("spawn"), do: :spawn
  defp normalize_primitive(_other), do: :fork

  defp normalize_optional_id(value) when is_integer(value) and value > 0, do: value
  defp normalize_optional_id(_value), do: nil

  defp commit_reference(reference, opts) when is_map(reference) and is_list(opts) do
    result =
      case Keyword.get(opts, :on_reference) do
        callback when is_function(callback, 1) -> callback.(reference)
        _other -> :ok
      end

    case result do
      :ok ->
        :ok

      {:ok, _value} ->
        :ok

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_reference_callback_result, other}}
    end
  end

  @spec persist_parent_tool_result(ExecutionContext.t(), ExecutionResult.t()) ::
          :ok | {:error, term()}
  def persist_parent_tool_result(
        %ExecutionContext{} = parent_context,
        %ExecutionResult{} = result
      ) do
    payload = %{
      text: result.text,
      result_raw: result.raw || %{},
      media_contents: [],
      artifact_contents: []
    }

    do_persist_parent_tool_result(parent_context, payload, 0)
  end

  defp do_persist_parent_tool_result(parent_context, payload, retry_count) do
    try do
      with_parent_generation_fence(parent_context, fn ->
        parent_message_id = parent_context.message_id || parent_context.assistant_message_id
        followup_state = Persistence.load_step_for_followup!(parent_context.step_id)

        case Enum.find(
               followup_state.tool_calls,
               &match?(
                 %ToolCall{item_id: item_id} when item_id == parent_context.tool_call_item_id,
                 &1
               )
             ) do
          %ToolCall{} = source_call ->
            _ =
              Persistence.persist_tool_result!(
                parent_message_id,
                parent_context.step_id,
                source_call,
                payload
              )

            :ok

          _other ->
            {:error, :tool_call_not_found}
        end
      end)
    rescue
      exception ->
        if retry_count < @parent_tool_result_race_retries and
             parent_tool_result_unique_constraint_error?(exception) do
          do_persist_parent_tool_result(parent_context, payload, retry_count + 1)
        else
          {:error, Exception.message(exception)}
        end
    catch
      :exit, reason -> {:error, Exception.format_exit(reason)}
    end
  end

  defp parent_tool_result_unique_constraint_error?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &parent_tool_result_unique_constraint_error?/1)
  end

  defp parent_tool_result_unique_constraint_error?(%{private_vars: vars}) when is_list(vars) do
    Keyword.get(vars, :constraint) == @parent_tool_result_unique_constraint
  end

  defp parent_tool_result_unique_constraint_error?(%{private_vars: vars}) when is_map(vars) do
    Map.get(vars, :constraint) == @parent_tool_result_unique_constraint
  end

  defp parent_tool_result_unique_constraint_error?(%{postgres: %{constraint: constraint}}) do
    constraint == @parent_tool_result_unique_constraint
  end

  defp parent_tool_result_unique_constraint_error?(%{constraint: constraint}) do
    constraint == @parent_tool_result_unique_constraint
  end

  defp parent_tool_result_unique_constraint_error?(%{error: error}) do
    parent_tool_result_unique_constraint_error?(error)
  end

  defp parent_tool_result_unique_constraint_error?(%{reason: reason}) do
    parent_tool_result_unique_constraint_error?(reason)
  end

  defp parent_tool_result_unique_constraint_error?(%RuntimeError{message: message})
       when is_binary(message) do
    String.contains?(message, @parent_tool_result_unique_constraint)
  end

  defp parent_tool_result_unique_constraint_error?(_error), do: false

  @spec nested_subchats_limit(ToolInstance.t()) :: non_neg_integer()
  def nested_subchats_limit(%ToolInstance{} = tool_instance) do
    value =
      tool_instance
      |> Map.get(:config, %{})
      |> config_get("nested_subchats_limit", 0)

    case value do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_non_negative_integer(value)
      _other -> 0
    end
  end

  @spec allow_handoff_in_subchats?(ToolInstance.t()) :: boolean()
  def allow_handoff_in_subchats?(%ToolInstance{} = tool_instance) do
    tool_instance
    |> Map.get(:config, %{})
    |> config_get("allow_handoff_in_subchats", false)
    |> truthy?()
  end

  defp creation_depth_up_to(%Chat{} = chat, actor, limit) do
    do_creation_depth_up_to(chat, actor, limit, 0, MapSet.new())
  end

  defp do_creation_depth_up_to(%Chat{} = chat, actor, limit, depth, visited) do
    if MapSet.member?(visited, chat.id) do
      {:error, :parent_cycle}
    else
      visited = MapSet.put(visited, chat.id)

      depth =
        if chat.parent_relation_kind in @creation_relation_kinds do
          depth + 1
        else
          depth
        end

      cond do
        depth > limit ->
          {:exceeded, depth}

        not is_integer(chat.parent_chat_id) ->
          {:ok, depth}

        true ->
          case fetch_owned_chat(chat.parent_chat_id, actor) do
            {:ok, parent} -> do_creation_depth_up_to(parent, actor, limit, depth, visited)
            _other -> {:ok, depth}
          end
      end
    end
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
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> {:ok, chat}
      {:ok, []} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_owned_chat(_chat_id, _actor), do: {:error, :invalid_chat_id}

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
end
