defmodule IntellectualClub.Generation.Worker do
  @moduledoc """
  Per-message generation worker.

  It accumulates a canonical runtime trace, serves client-owned polling cursors,
  and broadcasts lifecycle signals via PubSub. Supervised persistence operations
  serialize completed steps and round transitions without blocking command
  reception. External work resumes only after an acknowledged commit.
  """

  use GenServer

  require Logger

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.PersistenceOperation
  alias IntellectualClub.Generation.PersistenceFailure
  alias IntellectualClub.Generation.RecoveryGate
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Generation.QueueDispatcher
  alias IntellectualClub.Generation.RuntimePoll
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.ToolResult
  alias IntellectualClub.Generation.ToolExecution
  alias IntellectualClub.Generation.UsageCost
  alias IntellectualClub.Llm.Providers.Common.Registry, as: ProviderRegistry
  alias IntellectualClub.Notifications
  alias IntellectualClub.Notifications.Dispatcher, as: NotificationsDispatcher
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.Registry, as: ToolRegistry
  alias IntellectualClubWeb.Bff.Serializer

  defmodule CompletionEffectFailure do
    @moduledoc false
    defexception [:message]
  end

  @default_auto_retry_backoff_ms [500, 1_500, 5_000, 15_000, 30_000, 60_000, 120_000, 300_000]
  @default_auto_retry_jitter_ratio 0.2
  @auto_retry_http_status_codes MapSet.new([429, 502, 503, 520])
  @auto_retry_error_kinds MapSet.new(["network", "timeout", "transport"])
  @max_refusal_rounds 3
  @max_parallel_tool_calls 8

  defstruct [
    :context,
    :lease,
    :adapter,
    :status,
    :runtime_step,
    :stream_task,
    :stream_ref,
    :tool_task,
    :tool_result_opts,
    :retry_timer_ref,
    :queued_steering_retry_attempt,
    :step_attempt,
    :step_sequence,
    :tool_round,
    :refusal_round,
    :provider_session,
    :request_images,
    :runtime_epoch,
    :persistence_op,
    :persistence_action,
    :failure_plan,
    :failure_retry_timer,
    :steering_attempt,
    :steering_retry_timer,
    :deferred_provider_event,
    :deferred_tool_outcome,
    image_cache: %{},
    phase: :initializing,
    continuation: :idle,
    cancel_requested?: false,
    lease_lost?: false,
    cancel_waiters: [],
    tool_executions: %{},
    tool_cancel_requested?: false,
    queue_dirty?: false
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def get_current_state(pid) do
    GenServer.call(pid, :get_current_state)
  end

  def poll(pid, cursor, opts \\ []) when is_map(cursor) and is_list(opts) do
    GenServer.call(pid, {:poll, cursor, opts})
  end

  def cancel(pid) do
    GenServer.cast(pid, :cancel)
  end

  def cancel_and_wait(pid, timeout \\ 5_000) when is_integer(timeout) and timeout > 0 do
    GenServer.call(pid, :cancel_and_wait, timeout)
  end

  @doc false
  def global_name(message_id) when is_integer(message_id) do
    {__MODULE__, :message, message_id}
  end

  def queue_changed(pid) when is_pid(pid) do
    GenServer.cast(pid, :queue_changed)
  end

  @doc false
  @spec execute_tool_calls(list(map()), map(), ExecutionContext.t() | nil) :: list(map())
  def execute_tool_calls(tool_calls, tool_instances_by_alias, execution_context)
      when is_list(tool_calls) and is_map(tool_instances_by_alias) do
    max_concurrency =
      tool_calls
      |> length()
      |> min(@max_parallel_tool_calls)
      |> max(1)

    tool_calls
    |> Task.async_stream(
      fn call ->
        execution_context = execution_context_for_tool_call(execution_context, call)

        result =
          Executor.execute_llm_tool(
            tool_instances_by_alias,
            call.name,
            call.args || %{},
            execution_context
          )

        decorate_tool_result(call, result)
      end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
    end)
  end

  @impl true
  def init(%{context: context} = opts) do
    Process.flag(:trap_exit, true)

    lease = Map.get(opts, :lease)
    lease_owner = Map.get(opts, :lease_owner)

    with :ok <- adopt_generation_lease(lease, lease_owner) do
      generation_identity = %{
        chat_id: context.chat_id,
        message_id: context.message_id,
        owner_id: context.owner_id
      }

      register_generation_key!({:message, context.message_id}, generation_identity)
      register_generation_key!({:chat, context.chat_id}, generation_identity)
      register_global_generation_key!(context.message_id)

      state = %__MODULE__{
        context: context,
        lease: lease,
        status: :initializing,
        runtime_epoch: Ash.UUID.generate()
      }

      {:ok, state, {:continue, :initialize}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initialize_state(context, lease) do
    started_at = DateTime.utc_now()

    adapter =
      Map.get(context, :adapter_module) ||
        ProviderRegistry.fetch_or_missing(Map.get(context, :provider_type))

    initial_step_sequence =
      case Map.get(context, :initial_step_sequence) do
        value when is_integer(value) and value > 0 -> value
        _other -> 1
      end

    {runtime_step, continue} =
      case {Map.get(context, :initial_resume_mode), Map.get(context, :initial_step_status),
            context.step_id} do
        {:steered_waiting_provider, _status, step_id} when is_integer(step_id) ->
          restart = Persistence.load_step_for_provider_restart!(step_id)
          {restart.runtime_step, :start_stream}

        {:completed_tool_step, _status, step_id} when is_integer(step_id) ->
          followup = Persistence.load_step_for_followup!(step_id)
          {followup.runtime_step, :resume_completed_tool_step}

        {:finalize_completed_step, _status, step_id} when is_integer(step_id) ->
          completed = Persistence.load_step_for_followup!(step_id)
          {completed.runtime_step, :finalize_completed_step}

        {:waiting_tools, _status, step_id} when is_integer(step_id) ->
          followup = Persistence.load_step_for_followup!(step_id)
          {followup.runtime_step, :resume_waiting_tools}

        {_mode, :waiting_tools, step_id} when is_integer(step_id) ->
          followup = Persistence.load_step_for_followup!(step_id)
          {followup.runtime_step, :resume_waiting_tools}

        _other ->
          {
            RuntimeTrace.new_step(
              id: context.step_id,
              sequence: initial_step_sequence,
              started_at: started_at,
              status: :waiting_provider,
              raw_request: context.request_payload || %{}
            ),
            :start_stream
          }
      end

    request_images = Map.get(context, :request_images)

    request_images =
      if match?(
           %{step_id: id, request: request}
           when id == runtime_step.id and request === runtime_step.raw_request,
           request_images
         ),
         do: request_images

    context =
      context
      |> Map.put(:request_images, nil)
      |> Map.put(:step_id, runtime_step.id)
      |> Map.put(:request_payload, runtime_step.raw_request)

    state = %{
      context: context,
      lease: lease,
      adapter: adapter,
      status: :generating,
      step_attempt: initial_step_attempt(context, initial_step_sequence),
      step_sequence: runtime_step.sequence,
      tool_round: 0,
      refusal_round: 0,
      runtime_step: runtime_step,
      stream_task: nil,
      stream_ref: nil,
      retry_timer_ref: nil,
      queued_steering_retry_attempt: 0,
      provider_session: nil,
      request_images: if(request_images, do: Map.delete(request_images, :cache)),
      image_cache: if(request_images, do: request_images.cache, else: %{})
    }

    {state, continue}
  end

  @impl true
  def handle_continue(:initialize, %{context: context, lease: lease} = state) do
    {:noreply,
     begin_persistence(state, :initialize, fn ->
       if is_nil(lease) or Lease.valid?(lease) do
         {:ok, initialize_state(context, lease)}
       else
         exit({:generation_lease_lost, :lease_lost})
       end
     end)}
  end

  def handle_continue(:start_stream, state),
    do: begin_queued_steers(state, {:start_stream, :queue_checked})

  def handle_continue(:resume_waiting_tools, state) do
    {:noreply,
     begin_persistence(state, :resume_waiting_tools, fn ->
       safe_persist_value(state, :resume_waiting_tools, fn ->
         Persistence.list_missing_tool_calls!(state.runtime_step.id)
       end)
     end)}
  end

  def handle_continue(:resume_completed_tool_step, state) do
    handle_tool_results(state, [])
  end

  def handle_continue(:finalize_completed_step, state) do
    finalize_done_from_step(state, state.runtime_step.id)
  end

  @impl true
  def terminate(_reason, state) do
    _ = cancel_tasks(state)
    if state.tool_task, do: Task.shutdown(state.tool_task, :brutal_kill)
    PersistenceOperation.shutdown(state.persistence_op)
    _ = stop_provider_session(state)

    if state.lease, do: Lease.release(state.lease)
    :ok
  end

  defp start_stream_task(state) do
    ensure_dispatch_allowed!(state)
    state = ensure_provider_session(state)
    start_provider_stream_task(state, state.runtime_step.raw_request, state.runtime_step.id)
  end

  defp start_provider_stream_task(state, compact_request, step_id) do
    me = self()
    stream_ref = make_ref()

    adapter = state.adapter
    context = state.context
    provider_session = state.provider_session
    image_cache = state.image_cache

    task =
      Task.async(fn ->
        emit = fn event -> send(me, {:provider_event, stream_ref, event}) end

        cache_update = fn entries ->
          send(me, {:image_cache_update, stream_ref, step_id, entries})
        end

        adapter.stream_generate(
          %{
            context: context,
            request_payload: compact_request,
            request_step_id: step_id,
            timeout_ms: context.timeout_ms || 300_000,
            chunk_delay_ms: context.chunk_delay_ms,
            provider_session: provider_session,
            image_cache: image_cache,
            image_cache_update: cache_update
          },
          emit
        )
      end)

    %{
      state
      | stream_task: task,
        stream_ref: stream_ref,
        retry_timer_ref: nil,
        phase: :provider
    }
  end

  @impl true
  def handle_info(
        {:image_cache_update, ref, step_id, entries},
        %{stream_ref: ref, runtime_step: %{id: step_id}, lease_lost?: false} = state
      )
      when is_map(entries) do
    {:noreply, %{state | image_cache: Map.merge(state.image_cache, entries)}}
  end

  def handle_info({:image_cache_update, _ref, _step_id, _entries}, state), do: {:noreply, state}

  def handle_info(
        {:provider_event, stream_ref, {:trace, _event}},
        %{stream_ref: stream_ref, deferred_provider_event: event} = state
      )
      when not is_nil(event), do: {:noreply, state}

  def handle_info(
        {:provider_event, stream_ref, {:trace, trace_event}},
        %{stream_ref: stream_ref} = state
      ) do
    trace_event = semantic_trace_event(state, trace_event)
    runtime_step = apply_trace_event(state.runtime_step, trace_event, state.context)
    maybe_broadcast_text_delta(state, trace_event)
    {:noreply, %{state | runtime_step: runtime_step}}
  end

  def handle_info(
        {:provider_event, stream_ref, {kind, _meta}} = event,
        %{stream_ref: stream_ref, persistence_op: %PersistenceOperation{}} = state
      )
      when kind in [:response_complete, :response_error] do
    {:noreply, %{state | deferred_provider_event: state.deferred_provider_event || event}}
  end

  def handle_info(
        {:provider_event, stream_ref, {kind, _meta}} = event,
        %{stream_ref: stream_ref, steering_attempt: %{resolving?: true}} = state
      )
      when kind in [:response_complete, :response_error] do
    {:noreply, %{state | deferred_provider_event: state.deferred_provider_event || event}}
  end

  @impl true
  def handle_info(
        {:provider_event, stream_ref, {:response_complete, meta}},
        %{stream_ref: stream_ref} = state
      ) do
    runtime_step =
      state.runtime_step
      |> apply_trace_meta(meta, state.context)
      |> RuntimeTrace.apply_event({:set_step_response_final, true})

    state = %{state | runtime_step: runtime_step}

    raw_response = runtime_step.raw_response || %{}

    if is_map(raw_response) and provider_error_value?(Map.get(raw_response, "error")) do
      error = Map.get(raw_response, "error")
      status_code = parse_int(is_map(error) && Map.get(error, "code"))

      error_text = provider_error_text(error)

      error_meta = %{
        provider: state.context.provider_type,
        status_code: status_code,
        retryable:
          is_integer(status_code) and MapSet.member?(@auto_retry_http_status_codes, status_code),
        error_kind: "provider",
        error_text: error_text,
        raw_request: runtime_step.raw_request || %{},
        raw_response: raw_response
      }

      case maybe_retry_current_step(state, error_meta) do
        {:retrying, state} ->
          {:noreply, state}

        :no_retry ->
          finalize_error(state, error_text, error_meta)
      end
    else
      state = cancel_stream_task(state)

      {:noreply,
       begin_persistence(state, :provider_completed, fn ->
         safe_persist_value(state, :provider_completed, fn ->
           Persistence.persist_provider_completed!(state.context.message_id, runtime_step)
         end)
       end)}
    end
  end

  @impl true
  def handle_info(
        {:provider_event, stream_ref, {:response_error, meta}},
        %{stream_ref: stream_ref} = state
      ) do
    error_text = Map.get(meta, :error_text) || "Provider error"

    case maybe_retry_current_step(state, meta) do
      {:retrying, state} ->
        {:noreply, state}

      :no_retry ->
        finalize_error(state, error_text, meta)
    end
  end

  @impl true
  def handle_info(
        {:retry_current_step, retry_token},
        %{retry_timer_ref: {_timer_ref, retry_token}} = state
      ) do
    advance(%{state | retry_timer_ref: nil}, :start_stream)
  end

  @impl true
  def handle_info({:retry_current_step, _stale_retry_token}, state), do: {:noreply, state}

  @impl true
  def handle_info(:retry_current_step, state), do: {:noreply, state}

  @impl true
  def handle_info(:consume_queued_steers, state) do
    consume_queued_steers_signal(state)
  end

  @impl true
  def handle_info({:provider_event, _stale_stream_ref, _event}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:EXIT, manager, _reason},
        %{lease: %Lease{manager: manager}} = state
      ) do
    state = cancel_tasks(state)
    state = stop_provider_session(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{stream_task: %Task{pid: pid}} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, %{tool_task: %Task{pid: pid}} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    state = cancel_tasks(state)
    state = stop_provider_session(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({ref, :ok}, %{stream_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | stream_task: nil}}
  end

  @impl true
  def handle_info({ref, {:tool_results, results}}, %{tool_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    opts = state.tool_result_opts || []
    state = %{state | tool_task: nil, tool_result_opts: nil}

    if not is_nil(state.persistence_op) or steering_resolving?(state) do
      {:noreply, %{state | deferred_tool_outcome: {:results, results, opts}}}
    else
      advance(state, {:tool_results, results, opts})
    end
  end

  def handle_info({:tool_batch_failed, pid}, %{tool_task: %Task{pid: pid}} = state) do
    {:noreply, cancel_tool_task(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_task: %Task{ref: ref}} = state) do
    if reason in [:normal, :shutdown] do
      {:noreply, %{state | stream_task: nil}}
    else
      error_text = Exception.format_exit(reason)
      event = {:provider_event, state.stream_ref, {:response_error, %{error_text: error_text}}}
      state = %{state | stream_task: nil}

      if not is_nil(state.persistence_op) or steering_resolving?(state) do
        {:noreply, %{state | deferred_provider_event: state.deferred_provider_event || event}}
      else
        finalize_error(state, error_text)
      end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tool_task: %Task{ref: ref}} = state) do
    if state.cancel_requested? or state.lease_lost? or reason in [:normal, :shutdown] do
      advance(%{state | tool_task: nil, tool_result_opts: nil}, :idle)
    else
      error_text = Exception.format_exit(reason)
      state = %{state | tool_task: nil, tool_result_opts: nil}

      if not is_nil(state.persistence_op) or steering_resolving?(state) do
        {:noreply, %{state | deferred_tool_outcome: {:error, error_text}}}
      else
        finalize_error(state, error_text)
      end
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state)
      when is_map_key(state.tool_executions, pid) do
    case state.tool_executions[pid] do
      {^ref, _phase} ->
        {:noreply, %{state | tool_executions: Map.delete(state.tool_executions, pid)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({ref, {:persistence_result, identity, result}}, state) do
    if PersistenceOperation.matches?(
         state.persistence_op,
         ref,
         identity,
         state.context.message_id,
         operation_step_id(state),
         state.lease
       ) do
      PersistenceOperation.acknowledge(state.persistence_op)
      action = state.persistence_action
      state = %{state | persistence_op: nil, persistence_action: nil}

      if state.lease_lost? and not terminal_acknowledgement?(action, result) do
        advance(state, :idle)
      else
        persistence_finished(state, action, result)
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{persistence_op: %PersistenceOperation{task: %Task{ref: ref}}} = state
      ) do
    # A DOWN without the acknowledged result has an unknown commit outcome.
    # Never rewrite a stale runtime snapshot or replay external work here.
    action = state.persistence_action
    state = %{state | persistence_op: nil, persistence_action: nil}

    if state.lease_lost? do
      stop_obsolete_owner(state)
    else
      operation_failed(state, action, PersistenceFailure.task_down(reason, action_kind(action)))
    end
  end

  def handle_info(
        {:retry_failure_resolution, token},
        %{failure_retry_timer: {_timer, token}} = state
      ) do
    state = %{state | failure_retry_timer: nil}
    resolve_failure(state, failure_plan_for_cancel(state, state.failure_plan))
  end

  def handle_info({:retry_failure_resolution, _stale_token}, state), do: {:noreply, state}

  def handle_info(
        {:retry_steering_reconciliation, token},
        %{
          steering_retry_timer: {_timer, token},
          steering_attempt: %{retry_followup_opts: opts}
        } = state
      ) do
    state = %{state | steering_retry_timer: nil, steering_attempt: nil}
    advance(state, {:tool_results, [], opts})
  end

  def handle_info(
        {:retry_steering_reconciliation, token},
        %{steering_retry_timer: {_timer, token}} = state
      ) do
    state = %{state | steering_retry_timer: nil}

    if Map.get(state.steering_attempt, :rejecting?, false),
      do: reject_queued_steering(state),
      else: reconcile_steering(state)
  end

  def handle_info({:retry_steering_reconciliation, _stale_token}, state), do: {:noreply, state}

  @impl true
  def handle_info({ref, :ok}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {:tool_results, _results}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp handle_persisted_tool_calls(state, tool_calls) when is_list(tool_calls) do
    max_tool_rounds = max_tool_rounds(state)
    manual_handoff? = manual_handoff_generation?(state)

    {context_limit_reached, total_tokens, length, soft_limit} =
      context_soft_limit_reached(state)

    cond do
      not manual_handoff? and
        can_execute_tools?(state, max_tool_rounds, context_limit_reached) and
          mixed_handoff_tool_calls?(state, tool_calls) ->
        soft_refuse_tool_calls(state, tool_calls, mixed_handoff_refusal_payload(),
          allow_handoff?: true
        )

      not manual_handoff? and
          can_execute_tools?(state, max_tool_rounds, context_limit_reached) ->
        runtime_step = %{state.runtime_step | status: :waiting_tools}
        state = %{state | runtime_step: runtime_step}

        state = start_tool_task(state, tool_calls)

        {:noreply, state}

      state.refusal_round + 1 > @max_refusal_rounds ->
        finalize_tool_loop_exhausted(state, max_tool_rounds)

      manual_handoff? ->
        soft_refuse_tool_calls(state, tool_calls, manual_handoff_refusal_payload(),
          allow_handoff?: false
        )

      true ->
        refusal =
          refusal_result_payload(
            state,
            max_tool_rounds,
            context_limit_reached,
            total_tokens,
            length,
            soft_limit
          )

        soft_refuse_tool_calls(state, tool_calls, refusal, allow_handoff?: context_limit_reached)
    end
  end

  @impl true
  def handle_cast(:cancel, state), do: request_cancel(state, nil)

  def handle_cast(:generation_fence_lost, state) do
    state = state |> cancel_tasks() |> stop_provider_session()

    if state.persistence_op || state.tool_task do
      # Terminal commit clears the fence before the writer's aftermath/ACK.
      # Drain writers and protected tool phases before stopping. No new
      # work may start; the Lease manager's existing force-stop grace remains.
      {:noreply,
       %{
         state
         | lease_lost?: true,
           phase: :recovering,
           deferred_provider_event: nil,
           deferred_tool_outcome: nil
       }}
    else
      stop_obsolete_owner(state)
    end
  end

  def handle_cast(:queue_changed, state) do
    Process.send_after(self(), :consume_queued_steers, 10)
    {:noreply, state}
  end

  @impl true
  def handle_call(:cancel_and_wait, from, state), do: request_cancel(state, from)

  def handle_call({:tool_execution_phase, pid, phase}, {pid, _ref}, state)
      when phase in [:protected, :interruptible] do
    if state.tool_cancel_requested? or state.cancel_requested? or state.lease_lost? do
      {:reply, :canceled, state}
    else
      {monitor, _previous} =
        Map.get_lazy(state.tool_executions, pid, fn -> {Process.monitor(pid), phase} end)

      executions = Map.put(state.tool_executions, pid, {monitor, phase})
      {:reply, :ok, %{state | tool_executions: executions}}
    end
  end

  @impl true
  def handle_call(:get_current_state, _from, state) do
    {:reply, public_snapshot(state), state}
  end

  @impl true
  def handle_call({:poll, cursor, [protocol: :cursor]}, _from, state) do
    reply = RuntimePoll.poll(state.runtime_step, state.runtime_epoch, cursor)
    status = if state.status == :initializing, do: :generating, else: state.status
    {:reply, Map.merge(reply, %{status: status, phase: state.phase}), state}
  end

  def handle_call({:poll, _cursor, _opts}, _from, state) do
    {:reply, public_snapshot(state), state}
  end

  defp persist_cancellation(state) do
    with {:ok, :recorded} <-
           RecoveryGate.record_failure(
             state.context.message_id,
             state.lease,
             %User{id: state.context.owner_id},
             operation: :cancel,
             error: "Generation canceled",
             terminal_status: :canceled
           ) do
      safe_chat_persist_value(state, :canceled, fn ->
        if durable_waiting_tools_step?(state.runtime_step) do
          Persistence.persist_canceled_from_step!(state.context.message_id, state.runtime_step.id)
        else
          Persistence.persist_canceled!(state.context.message_id, state.runtime_step)
        end

        _ = settle_terminal_queue!(state, :canceled)
        _ = BackgroundTasks.request_cancel_for_lifecycle_message!(state.context.message_id)
        record_terminal_event!(state, :canceled, false)
        :ok
      end)
    end
  end

  defp consume_queued_steers_signal(state) do
    cond do
      state.status != :generating or state.lease_lost? or not is_nil(state.failure_plan) ->
        {:noreply, state}

      not is_nil(state.persistence_op) or steering_resolving?(state) ->
        {:noreply, %{state | queue_dirty?: true}}

      state.runtime_step.status != :waiting_provider ->
        {:noreply, state}

      true ->
        continuation =
          if is_nil(state.stream_ref) and is_nil(state.retry_timer_ref),
            do: :start_stream,
            else: :idle

        begin_queued_steers(state, continuation)
    end
  end

  defp begin_queued_steers(state, continuation) do
    retry_pending? =
      not is_nil(state.retry_timer_ref) or match?({:backoff, _delay}, continuation) or
        match?({:backoff, _delay}, state.continuation)

    provider_started? = retry_pending? or not is_nil(state.stream_ref)
    action = {:queued_steers, continuation, retry_pending?, provider_started?}
    state = %{state | queue_dirty?: false, continuation: continuation}

    {:noreply,
     begin_step_transition(state, action, :before_response, fn ->
       consume_queued_steers_waiting_provider(state)
     end)}
  end

  defp consume_queued_steers_waiting_provider(state) do
    case read_pending_steers(state) do
      {:ok, queued_messages} ->
        specs = queued_steering_specs(queued_messages)

        if specs == [] do
          {:ok, nil}
        else
          steering_result(
            fn ->
              with {:ok, injected} <-
                     inject_steering_request(
                       state,
                       state.runtime_step.raw_request,
                       Enum.map(specs, &%{text: &1.text, placement: :before_response})
                     ) do
                safe_request_persist_value(state, :queued_steering_before_response, fn ->
                  Persistence.persist_queued_steering_before_provider!(
                    state.context.message_id,
                    state.runtime_step.id,
                    specs,
                    injected.raw_request,
                    request_step_options(state)
                  )
                end)
              end
            end,
            specs
          )
        end

      {:error, reason} ->
        {:error, {:steering_rejected, reason, nil}}
    end
  end

  defp read_pending_steers(state) do
    # Keep read-side driver errors typed and inside the optional command scope,
    # so Ash wrapping cannot turn a queue outage into a failed base followup.
    PersistenceFailure.capture(
      fn ->
        QueuedMessages.list_pending_steers(state.context.message_id, %User{
          id: state.context.owner_id
        })
      end,
      :queued_steering_read
    )
  end

  defp queued_steering_retry_state(state, reason) do
    attempt = max((state.queued_steering_retry_attempt || 0) + 1, 1)

    Logger.warning(
      "Failed to consume queued steering; provider start deferred " <>
        "message_id=#{state.context.message_id} attempt=#{attempt} reason=#{inspect(reason)}"
    )

    %{state | queued_steering_retry_attempt: attempt}
  end

  defp schedule_queued_steering_retry(state) do
    delays = [50, 100, 250, 500, 1_000, 2_000, 5_000]
    attempt = max(state.queued_steering_retry_attempt || 1, 1)
    delay_ms = Enum.at(delays, attempt - 1, List.last(delays))
    Process.send_after(self(), :consume_queued_steers, delay_ms)
    :ok
  end

  defp queued_steering_specs(queued_messages) when is_list(queued_messages) do
    queued_messages
    |> Enum.map(fn queued_message ->
      text =
        queued_message
        |> QueuedMessages.content_specs()
        |> Enum.filter(&(&1.kind == :text))
        |> Enum.map_join("", &to_string(&1.content_text || ""))

      %{id: queued_message.id, text: text, updated_at: queued_message.updated_at}
    end)
    |> Enum.reject(&(&1.text == ""))
    |> Enum.sort_by(& &1.id)
  end

  defp begin_step_transition(state, action, placement, fun) when is_function(fun, 0) do
    state = %{
      state
      | steering_attempt: %{
          step_id: state.runtime_step.id,
          placement: placement,
          action: action,
          resolving?: false
        }
    }

    begin_persistence(state, action, fun)
  end

  defp steering_result(fun, specs) do
    case PersistenceFailure.capture(fun, :steering) do
      {:error, reason} -> {:error, {:steering_rejected, reason, specs}}
      {:ok, {:error, reason}} -> {:error, {:steering_rejected, reason, specs}}
      result -> result
    end
  end

  defp steering_resolving?(%{steering_attempt: %{resolving?: true}}), do: true
  defp steering_resolving?(_state), do: false

  defp reconcile_steering(%{steering_attempt: attempt} = state) do
    {:noreply,
     begin_persistence(state, :steering_reconciliation, fn ->
       safe_request_persist_value(state, :steering_reconciliation, fn ->
         Persistence.reconcile_step_transition!(
           state.context.message_id,
           attempt.step_id,
           attempt.placement,
           lease: state.lease
         )
       end)
     end)}
  end

  defp reject_queued_steering(%{steering_attempt: attempt} = state) do
    # This idempotent queue-only write is deliberately separate from canonical
    # reconciliation. Its failure must not become a failure of the generation.
    state = %{state | steering_attempt: Map.put(attempt, :rejecting?, true)}

    {:noreply,
     begin_persistence(state, :steering_rejection, fn ->
       safe_chat_persist_value(state, :steering_rejection, fn ->
         case QueuedMessages.reject_steers(
                state.context.message_id,
                attempt.specs,
                %User{id: state.context.owner_id}
              ) do
           {:ok, _ids} -> :ok
           {:error, reason} -> raise PersistenceFailure.new(reason, operation: :reject_steers)
         end
       end)
     end)}
  end

  defp rejected_queue_batch?(attempt) do
    is_list(attempt.specs) and attempt.specs != [] and
      attempt.failure.kind in [:permanent, :retry_exhausted] and
      attempt.failure.reason != :queued_steering_changed
  end

  defp reject_steering_command(%{steering_attempt: attempt} = state) do
    state = %{state | steering_attempt: nil}

    case attempt.action do
      {:queued_steers, _continuation, _retry?, _started?} ->
        # A rejected batch is durable and will not be silently re-applied. Read
        # failures or unknown outcomes proven rolled back only retry the queue.
        state = queued_steering_retry_state(state, attempt.failure.kind)
        schedule_queued_steering_retry(state)
        broadcast(state, {:steering, state.context.message_id})

        continuation =
          case state.continuation do
            {:backoff, _delay} = backoff -> backoff
            _other -> :idle
          end

        advance(state, continuation)

      {:tool_followup, opts} ->
        state = queued_steering_retry_state(state, attempt.failure.kind)
        delay = min(50 * state.queued_steering_retry_attempt, 5_000)
        token = make_ref()
        timer = Process.send_after(self(), {:retry_steering_reconciliation, token}, delay)

        {:noreply,
         %{
           state
           | steering_attempt: %{resolving?: true, retry_followup_opts: opts},
             steering_retry_timer: {timer, token},
             phase: :persisting
         }}

      _direct_command ->
        advance(state, state.continuation)
    end
  end

  defp retry_steering_reconciliation(%{steering_attempt: attempt} = state, failure) do
    cond do
      failure.kind == :lease_lost ->
        stop_obsolete_owner(state)

      failure.kind in [:permanent, :retry_exhausted] and attempt.retries >= 2 and
          not Map.get(attempt, :rejecting?, false) ->
        # Corrupt canonical state is not a rejected command. Fail closed rather
        # than trusting an old snapshot or replaying the publication.
        operation_failed(%{state | steering_attempt: nil}, :steering_canonical_state, failure)

      true ->
        delay = Enum.at([250, 1_000, 5_000], min(attempt.retries, 2))
        token = make_ref()
        timer = Process.send_after(self(), {:retry_steering_reconciliation, token}, delay)
        PersistenceFailure.log(failure, state.context.message_id, attempt.step_id)

        {:noreply,
         %{
           state
           | steering_attempt: %{attempt | retries: attempt.retries + 1},
             steering_retry_timer: {timer, token},
             phase: :recovering
         }}
    end
  end

  defp inject_steering_request(state, raw_request, steering_items)
       when is_map(raw_request) and is_list(steering_items) do
    try do
      case state.adapter.inject_steering(raw_request, steering_items, state.context) do
        %{raw_request: %{} = raw_request} = injected ->
          {:ok, %{injected | raw_request: raw_request}}

        {:ok, %{raw_request: %{} = raw_request} = injected} ->
          {:ok, %{injected | raw_request: raw_request}}

        other ->
          {:error, {:invalid_steering_request, other}}
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp finalize_done_from_step(state, step_id, opts \\ [])
       when is_integer(step_id) and is_list(opts) do
    state = cancel_tasks(state)

    {:noreply,
     begin_persistence(state, {:done, step_id}, fn ->
       safe_chat_persist_value(state, :done, fn ->
         effect = durable_completion_effect!(state, step_id, opts)
         Persistence.persist_completed_from_step!(state.context.message_id, step_id)
         _ = settle_background_task_lifecycle!(state, effect)
         result = if effect == :ok, do: {:queue_boundary, settle_done_queue!(state)}, else: effect
         record_terminal_event!(state, :done, completion_suppressed?(result))
         result
       end)
     end)}
  end

  defp durable_completion_effect!(state, step_id, opts) do
    result =
      case Map.get(state.context, :completion_effect) do
        :manual_handoff ->
          run_completion_effect(state)

        _other ->
          case terminal_handoff_payload(step_id, opts) do
            %{} = payload -> transfer_terminal_handoff(state, step_id, payload)
            nil -> :ok
          end
      end

    case result do
      {:error, error_text} -> raise CompletionEffectFailure, message: error_text
      result -> result
    end
  end

  defp run_completion_effect(%{context: %{completion_effect: :manual_handoff}} = state) do
    actor = %User{id: state.context.owner_id}

    case Handoff.complete_manual_generation(state.context.message_id, actor) do
      {:ok, result} ->
        case QueueCoordinator.transfer_to_handoff(
               state.context.message_id,
               result.chat.id,
               nil
             ) do
          {:ok, payload} ->
            {:handoff, Map.put(result, :queue_transfer, payload)}

          {:error, reason} ->
            {:error, "Failed to transfer manual handoff queue: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to complete manual handoff: #{inspect(reason)}"}
    end
  end

  defp run_completion_effect(_state), do: :ok

  defp settle_done_queue!(state) do
    case QueueCoordinator.settle_generation(state.context.message_id, :done) do
      {:ok, %{chat_id: chat_id}} ->
        case QueueCoordinator.prepare_next(
               chat_id,
               boundary_message_id: state.context.message_id
             ) do
          {:error, reason} ->
            raise CompletionEffectFailure,
              message: "Failed to prepare queued generation: #{inspect(reason)}"

          result ->
            result
        end

      {:error, reason} ->
        raise CompletionEffectFailure,
          message: "Failed to settle completed generation queue: #{inspect(reason)}"
    end
  end

  defp settle_terminal_queue!(state, status) when status in [:error, :canceled] do
    case QueueCoordinator.settle_generation(state.context.message_id, status) do
      {:ok, payload} ->
        payload

      {:error, reason} ->
        raise CompletionEffectFailure,
          message: "Failed to settle terminal generation queue: #{inspect(reason)}"
    end
  end

  defp completion_suppressed?({:queue_boundary, {:ok, _context}}), do: true

  defp completion_suppressed?({:handoff, %{queue_transfer: %{transferred_count: count}}})
       when is_integer(count) and count > 0,
       do: true

  defp completion_suppressed?({:terminal_handoff, _payload, _transfer}), do: true
  defp completion_suppressed?(_result), do: false

  defp settle_background_task_lifecycle!(
         state,
         {:terminal_handoff, payload, _transfer}
       ) do
    child_message_id =
      parse_int(
        Map.get(payload, "generation_message_id") ||
          Map.get(payload, :generation_message_id)
      )

    if is_integer(child_message_id) do
      task_ids =
        BackgroundTasks.transfer_active_for_handoff!(
          state.context.message_id,
          child_message_id
        )

      Logger.info(
        "Transferred background task lifecycle through handoff " <>
          "count=#{length(task_ids)} source_message_id=#{state.context.message_id} " <>
          "child_message_id=#{child_message_id}"
      )

      task_ids
    else
      raise CompletionEffectFailure, message: "Invalid terminal handoff generation"
    end
  end

  defp settle_background_task_lifecycle!(state, _effect) do
    BackgroundTasks.request_cancel_for_lifecycle_message!(state.context.message_id)
  end

  defp record_terminal_event!(state, status, suppressed?) do
    case Notifications.record_generation_finished(state.context.message_id, status,
           suppressed?: suppressed?
         ) do
      {:ok, _event} ->
        :ok

      {:duplicate, _event} ->
        :ok

      {:error, reason} ->
        raise CompletionEffectFailure,
          message: "Failed to record terminal generation event: #{inspect(reason)}"
    end
  end

  defp terminal_handoff_payload(step_id, opts) do
    case Keyword.get(opts, :terminal_handoff) do
      %{} = payload ->
        payload

      _other ->
        step_id
        |> Persistence.load_step_for_followup!()
        |> Map.get(:results, [])
        |> handoff_payload()
    end
  end

  defp transfer_terminal_handoff(state, step_id, payload) do
    child_chat_id = parse_int(Map.get(payload, "chat_id") || Map.get(payload, :chat_id))

    if is_integer(child_chat_id) do
      case QueueCoordinator.prepare_terminal_handoff(
             state.context.message_id,
             child_chat_id
           ) do
        {:ok, transfer} ->
          generation_message_id = transfer.child_generation_message_id
          queue_anchor_message_id = transfer.child_queue_anchor_message_id

          canonical_payload =
            payload
            |> Map.put("generation_message_id", generation_message_id)
            |> Map.put("queue_anchor_message_id", queue_anchor_message_id)

          _ =
            Persistence.enrich_handoff_tool_results!(
              step_id,
              child_chat_id,
              canonical_payload
            )

          runtime_payload =
            Map.put(canonical_payload, :prepared_context, transfer.prepared_context)

          {:terminal_handoff, runtime_payload, transfer}

        {:error, reason} ->
          {:error, "Failed to transfer handoff queue: #{inspect(reason)}"}
      end
    else
      {:error, "Invalid terminal handoff destination"}
    end
  end

  defp finish_done_queue(state, {:ok, context}) do
    QueueDispatcher.start_prepared(context)
    NotificationsDispatcher.suppress_generation_finished(state.context.message_id, :done)
  end

  defp finish_done_queue(state, _queue_result) do
    NotificationsDispatcher.notify_generation_finished(state.context.message_id, :done)
  end

  defp finish_terminal_handoff_queue(state, payload) do
    child_chat_id = parse_int(Map.get(payload, "chat_id") || Map.get(payload, :chat_id))

    case Map.get(payload, :prepared_context) do
      %{} = context ->
        QueueDispatcher.start_prepared(context)

      _other ->
        resume_terminal_handoff_generation(state, payload)
    end

    if is_integer(child_chat_id), do: QueueDispatcher.kick(child_chat_id)

    NotificationsDispatcher.suppress_generation_finished(
      state.context.message_id,
      :done
    )
  end

  defp resume_terminal_handoff_generation(state, payload) do
    generation_message_id =
      parse_int(
        Map.get(payload, "generation_message_id") ||
          Map.get(payload, :generation_message_id)
      )

    if is_integer(generation_message_id) do
      actor = %User{id: state.context.owner_id}

      case Subagent.resume_generation_if_needed(generation_message_id, actor) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Durable handoff generation start deferred " <>
              "message_id=#{generation_message_id} reason=#{inspect(reason)}"
          )
      end
    end

    :ok
  end

  defp finish_manual_handoff_queue(
         state,
         %{chat: %{id: child_chat_id}, queue_transfer: %{transferred_count: count}}
       )
       when is_integer(child_chat_id) and count > 0 do
    QueueDispatcher.kick(child_chat_id)

    NotificationsDispatcher.suppress_generation_finished(
      state.context.message_id,
      :done
    )
  end

  defp finish_manual_handoff_queue(state, %{queue_transfer: %{transferred_count: 0}}) do
    NotificationsDispatcher.notify_generation_finished(state.context.message_id, :done)
  end

  defp finish_manual_handoff_queue(state, %{chat: %{id: child_chat_id}})
       when is_integer(child_chat_id) do
    case QueueDispatcher.handoff(state.context.message_id, child_chat_id, nil) do
      {:transferred, _payload} ->
        NotificationsDispatcher.suppress_generation_finished(
          state.context.message_id,
          :done
        )

      _other ->
        NotificationsDispatcher.notify_generation_finished(state.context.message_id, :done)
    end
  end

  defp finish_manual_handoff_queue(state, _result) do
    NotificationsDispatcher.notify_generation_finished(state.context.message_id, :done)
  end

  defp finish_error_queue(state) do
    BackgroundTasks.cancel_for_lifecycle_message_async(state.context.message_id)
    NotificationsDispatcher.notify_generation_finished(state.context.message_id, :error)
  end

  defp maybe_finish_canceled_queue(state, :ok) do
    NotificationsDispatcher.notify_generation_finished(state.context.message_id, :canceled)
  end

  defp finalize_error(state, error_text) do
    finalize_error(state, error_text, %{})
  end

  defp finalize_error(state, error_text, meta) do
    runtime_step =
      state.runtime_step
      |> apply_trace_meta(meta, state.context)
      |> RuntimeTrace.apply_event({:set_step_response_final, false})
      |> RuntimeTrace.apply_event({:ensure_item, "error", :error, nil})
      |> RuntimeTrace.apply_event({:set_text, "error", :error, 1, to_string(error_text || "")})

    state = %{cancel_tasks(state) | runtime_step: runtime_step}

    {:noreply,
     begin_persistence(state, {:error, error_text}, fn ->
       with {:ok, :recorded} <-
              RecoveryGate.record_failure(
                state.context.message_id,
                state.lease,
                %User{id: state.context.owner_id},
                operation: :error,
                error: to_string(error_text || "Provider error"),
                terminal_status: :error
              ) do
         safe_chat_persist_value(state, :error, fn ->
           if durable_waiting_tools_step?(runtime_step) do
             Persistence.persist_error_from_step!(
               state.context.message_id,
               runtime_step.id,
               error_text
             )
           else
             Persistence.persist_error!(state.context.message_id, runtime_step, error_text)
           end

           _ = settle_terminal_queue!(state, :error)
           _ = BackgroundTasks.request_cancel_for_lifecycle_message!(state.context.message_id)
           record_terminal_event!(state, :error, false)
           :ok
         end)
       end
     end)}
  end

  defp durable_waiting_tools_step?(%RuntimeTrace.Step{id: step_id, status: status})
       when is_integer(step_id) do
    status in [:waiting_tools, :done]
  end

  defp durable_waiting_tools_step?(_runtime_step), do: false

  defp maybe_retry_current_step(state, meta) when is_map(meta) do
    if retryable_provider_error?(meta) do
      attempt = state.step_attempt
      delay_ms = backoff_delay_ms(attempt)
      status_code = status_code_from_meta(meta)
      step_id = state.runtime_step.id
      error_text = error_text_from_meta(meta)

      Logger.warning(
        "generation step auto-retry message_id=#{state.context.message_id} " <>
          "step_id=#{inspect(step_id)} attempt=#{attempt} " <>
          "status_code=#{inspect(status_code)} delay_ms=#{delay_ms}"
      )

      state = cancel_stream_task(state)

      state =
        begin_persistence(state, {:auto_retry, attempt, delay_ms}, fn ->
          persist_retry_error_and_start_next_step(state, error_text, meta, attempt, delay_ms)
        end)

      {:retrying, state}
    else
      :no_retry
    end
  end

  defp persist_retry_error_and_start_next_step(state, error_text, meta, attempt, delay_ms) do
    raw_request = state.runtime_step.raw_request || %{}

    case safe_request_persist_value(state, :auto_retry, fn ->
           Persistence.persist_retry_error_and_start_next_step!(
             state.context.message_id,
             state.runtime_step.id,
             raw_request,
             error_text,
             attempt: attempt,
             retry_delay_ms: delay_ms,
             status_code: status_code_from_meta(meta),
             error_kind: string_value(meta, :error_kind),
             raw_response: Map.get(meta, :raw_response),
             retryable: true,
             request_context: Map.put(state.context, :adapter_module, state.adapter),
             source_step_id: state.runtime_step.id,
             previous_request: state.runtime_step.raw_request,
             source_image_state: state.request_images,
             image_cache: state.image_cache,
             lease: state.lease
           )
         end) do
      {:ok, retry_step} ->
        runtime_step =
          RuntimeTrace.new_step(
            id: retry_step.step_id,
            sequence: retry_step.step_sequence,
            started_at: retry_step.started_at,
            status: :waiting_provider,
            raw_request: retry_step.raw_request || raw_request
          )

        {:ok, %{runtime_step: runtime_step, request_images: Map.get(retry_step, :request_images)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp error_text_from_meta(meta) when is_map(meta) do
    case Map.get(meta, :error_text) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> "Provider error"
          trimmed -> trimmed
        end

      _other ->
        "Provider error"
    end
  end

  defp retryable_provider_error?(meta) when is_map(meta) do
    retryable_hint = bool_value(meta, :retryable)
    status_code = status_code_from_meta(meta)
    error_kind = string_value(meta, :error_kind)

    retryable_hint == true or
      (is_integer(status_code) and MapSet.member?(@auto_retry_http_status_codes, status_code)) or
      MapSet.member?(@auto_retry_error_kinds, error_kind)
  end

  defp auto_retry_backoff_values do
    configured = Application.get_env(:intellectual_club, :generation_auto_retry_backoff_ms)

    if is_list(configured) do
      configured
      |> Enum.map(&parse_int/1)
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    else
      @default_auto_retry_backoff_ms
    end
  end

  defp backoff_delay_ms(attempt) when is_integer(attempt) and attempt > 0 do
    case auto_retry_backoff_values() do
      [] ->
        0

      values ->
        idx = min(attempt - 1, length(values) - 1)

        values
        |> Enum.at(idx, 0)
        |> add_retry_jitter()
    end
  end

  defp backoff_delay_ms(_attempt), do: 0

  defp initial_step_attempt(context, initial_step_sequence)
       when is_map(context) and is_integer(initial_step_sequence) and initial_step_sequence > 1 do
    case Persistence.retry_attempt_before_step!(context.message_id, initial_step_sequence) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _other -> 1
    end
  end

  defp initial_step_attempt(_context, _initial_step_sequence), do: 1

  defp add_retry_jitter(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    jitter_limit = round(delay_ms * auto_retry_jitter_ratio())

    if jitter_limit > 0 do
      delay_ms + :rand.uniform(jitter_limit)
    else
      delay_ms
    end
  end

  defp add_retry_jitter(delay_ms), do: delay_ms

  defp auto_retry_jitter_ratio do
    case Application.get_env(:intellectual_club, :generation_auto_retry_jitter_ratio) do
      value when is_number(value) and value >= 0 -> value
      _other -> @default_auto_retry_jitter_ratio
    end
  end

  defp status_code_from_meta(meta) when is_map(meta) do
    case Map.get(meta, :status_code) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp status_code_from_meta(_meta), do: nil

  defp bool_value(meta, key) when is_map(meta) and is_atom(key) do
    Map.get(meta, key) == true
  end

  defp bool_value(_meta, _key), do: false

  defp string_value(meta, key) when is_map(meta) and is_atom(key) do
    case Map.get(meta, key) do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _other -> ""
    end
  end

  defp string_value(_meta, _key), do: ""

  defp provider_error_text(error) when is_map(error) do
    message = trimmed_string(Map.get(error, "message"))
    raw = provider_error_raw_message(error)

    cond do
      raw != "" and generic_provider_error_message?(message) ->
        raw

      message != "" ->
        message

      raw != "" ->
        raw

      true ->
        "Provider returned error"
    end
  end

  defp provider_error_text(_error), do: "Provider returned error"

  defp provider_error_raw_message(error) when is_map(error) do
    metadata = Map.get(error, "metadata")

    case metadata do
      %{} ->
        trimmed_string(Map.get(metadata, "raw"))

      _other ->
        ""
    end
  end

  defp generic_provider_error_message?(message) when is_binary(message) do
    message
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["", "error", "provider error", "provider returned error"]))
  end

  defp generic_provider_error_message?(_message), do: true

  defp trimmed_string(value) when is_binary(value), do: String.trim(value)
  defp trimmed_string(nil), do: ""
  defp trimmed_string(value), do: value |> to_string() |> String.trim()

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp cancel_tasks(state) do
    state
    |> cancel_retry_timer()
    |> cancel_stream_task()
    |> cancel_tool_task()
  end

  defp cancel_retry_timer(%{retry_timer_ref: nil} = state), do: state

  defp cancel_retry_timer(%{retry_timer_ref: {timer_ref, retry_token}} = state) do
    _ = Process.cancel_timer(timer_ref)

    receive do
      {:retry_current_step, ^retry_token} -> :ok
    after
      0 -> :ok
    end

    %{state | retry_timer_ref: nil}
  end

  defp cancel_retry_timer(%{retry_timer_ref: timer_ref} = state) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    %{state | retry_timer_ref: nil}
  end

  defp cancel_stream_task(%{stream_task: nil} = state), do: %{state | stream_ref: nil}

  defp cancel_stream_task(%{stream_task: task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    %{state | stream_task: nil, stream_ref: nil}
  end

  defp cancel_tool_task(%{tool_task: nil} = state), do: state

  defp cancel_tool_task(state) do
    # Keep the batch alive until protected SQL borrowers have returned their
    # connections. Killing its async_stream owner would kill every child too.
    Enum.each(state.tool_executions, fn
      {pid, {_monitor, :interruptible}} -> Process.exit(pid, :kill)
      {_pid, {_monitor, :protected}} -> :ok
    end)

    %{state | tool_cancel_requested?: true}
  end

  defp start_provider_session(adapter, context) do
    if function_exported?(adapter, :start_session, 1) do
      case adapter.start_session(context) do
        {:ok, session} ->
          own_provider_session(session)

        :ignore ->
          nil

        {:error, reason} ->
          Logger.warning(
            "Provider session start failed provider=#{inspect(Map.get(context, :provider_type))} " <>
              "reason=#{inspect(reason)}"
          )

          nil
      end
    else
      nil
    end
  rescue
    exception ->
      Logger.warning(
        "Provider session start failed provider=#{inspect(Map.get(context, :provider_type))} " <>
          "error=#{Exception.message(exception)}"
      )

      nil
  catch
    :exit, reason ->
      Logger.warning(
        "Provider session start exited provider=#{inspect(Map.get(context, :provider_type))} " <>
          "reason=#{inspect(reason)}"
      )

      nil
  end

  defp register_generation_key!(key, value) do
    case Registry.register(IntellectualClub.Generation.Registry, key, value) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, pid}} -> exit({:already_running, pid})
    end
  end

  defp register_global_generation_key!(message_id) do
    case :global.register_name(global_name(message_id), self()) do
      :yes -> :ok
      :no -> exit(:already_running)
    end
  end

  defp adopt_generation_lease(%Lease{} = lease, owner) when is_pid(owner) do
    Lease.adopt(lease, owner)
  end

  defp adopt_generation_lease(_lease, _owner), do: {:error, :invalid_generation_lease_owner}

  defp stop_provider_session(%{provider_session: nil} = state), do: state

  defp stop_provider_session(%{adapter: adapter, provider_session: session} = state) do
    stop_owned_provider_session(adapter, session)

    %{state | provider_session: nil}
  rescue
    exception ->
      Logger.warning("Provider session stop failed error=#{Exception.message(exception)}")
      %{state | provider_session: nil}
  catch
    :exit, reason ->
      Logger.warning("Provider session stop exited reason=#{inspect(reason)}")
      %{state | provider_session: nil}
  end

  defp own_provider_session(session) when is_pid(session) do
    Process.link(session)
    session
  end

  defp own_provider_session(session), do: session

  defp stop_owned_provider_session(adapter, session) do
    try do
      if function_exported?(adapter, :stop_session, 1) do
        adapter.stop_session(session)
      end
    after
      if is_pid(session), do: Process.unlink(session)
    end
  end

  defp safe_persist_value(%__MODULE__{} = state, status, fun) when is_function(fun, 0) do
    safe_persist_value(state, status, fun, &fenced_call/2)
  end

  # Request preparation happens before Persistence acquires the publication fence.
  defp safe_request_persist_value(%__MODULE__{} = state, status, fun) when is_function(fun, 0) do
    safe_persist_value(state, status, fun, fn state, fun ->
      if is_nil(state.lease) or Lease.valid?(state.lease) do
        {:ok, fun.()}
      else
        {:error, :lease_lost}
      end
    end)
  end

  defp safe_chat_persist_value(%__MODULE__{} = state, status, fun)
       when is_function(fun, 0) do
    safe_persist_value(state, status, fun, &chat_fenced_call/2)
  end

  defp safe_persist_value(%__MODULE__{} = state, status, fun, fence_fun)
       when is_function(fun, 0) and is_function(fence_fun, 2) do
    PersistenceFailure.capture(
      fn ->
        case fence_fun.(state, fun) do
          {:error, reason} = error ->
            if generation_fence_lost?(reason),
              do: exit({:generation_lease_lost, reason}),
              else: error

          result ->
            result
        end
      end,
      status
    )
  end

  defp fenced_call(%__MODULE__{lease: %Lease{} = lease}, fun) when is_function(fun, 0) do
    Lease.with_fence(lease, fun)
  end

  defp chat_fenced_call(%__MODULE__{lease: %Lease{} = lease} = state, fun)
       when is_function(fun, 0) do
    Lease.with_chat_fence(lease, state.context.chat_id, fun,
      allowed_statuses: [:generating],
      required_role: :assistant
    )
  end

  defp generation_fence_lost?(reason), do: reason in [:lease_lost, :lease_not_fenced]

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(IntellectualClub.PubSub, "chat:#{state.context.chat_id}", message)
  end

  defp maybe_broadcast_text_delta(state, {:append_text, _item_key, :answer, _seq, delta}) do
    broadcast(state, {:content_delta, state.context.message_id, delta})
  end

  defp maybe_broadcast_text_delta(
         state,
         {:append_text, _item_key, :handoff_summary, _seq, delta}
       ) do
    broadcast(state, {:content_delta, state.context.message_id, delta})
  end

  defp maybe_broadcast_text_delta(state, {:append_text, _item_key, :reasoning, _seq, delta}) do
    broadcast(state, {:reasoning_delta, state.context.message_id, delta})
  end

  defp maybe_broadcast_text_delta(_state, _event), do: :ok

  defp semantic_trace_event(state, {:ensure_item, key, :answer, sequence}) do
    {:ensure_item, key, semantic_answer_item_type(state), sequence}
  end

  defp semantic_trace_event(state, {:append_text, key, :answer, sequence, text}) do
    {:append_text, key, semantic_answer_item_type(state), sequence, text}
  end

  defp semantic_trace_event(state, {:set_text, key, :answer, sequence, text}) do
    {:set_text, key, semantic_answer_item_type(state), sequence, text}
  end

  defp semantic_trace_event(state, {:set_opaque, key, :answer, sequence, payload}) do
    {:set_opaque, key, semantic_answer_item_type(state), sequence, payload}
  end

  defp semantic_trace_event(state, {:set_media, key, :answer, sequence, media}) do
    {:set_media, key, semantic_answer_item_type(state), sequence, media}
  end

  defp semantic_trace_event(_state, event), do: event

  defp semantic_answer_item_type(state) do
    if manual_handoff_generation?(state), do: :handoff_summary, else: :answer
  end

  defp current_tools_payload(state) do
    state.context.tools_payload || []
  end

  defp handoff_tools_payload(state) do
    state.context.tools_payload
    |> List.wrap()
    |> Enum.filter(&handoff_tool_payload?(state, &1))
  end

  defp max_tool_rounds(state) do
    case state.context.max_tool_rounds do
      value when is_integer(value) and value >= 0 -> value
      _other -> 20
    end
  end

  defp context_soft_limit_reached(state) do
    with context_length when is_integer(context_length) and context_length > 0 <-
           Map.get(state.context, :context_length),
         percent when is_integer(percent) and percent > 0 <-
           Map.get(state.context, :context_soft_limit_percent),
         input_tokens when is_integer(input_tokens) and input_tokens >= 0 <-
           state.runtime_step.input_tokens,
         output_tokens when is_integer(output_tokens) and output_tokens >= 0 <-
           state.runtime_step.output_tokens do
      total_tokens = input_tokens + output_tokens
      soft_limit = max(1, trunc(context_length * (percent / 100.0)))
      {total_tokens > soft_limit, total_tokens, context_length, soft_limit}
    else
      _other -> {false, nil, nil, nil}
    end
  end

  defp can_execute_tools?(state, max_tool_rounds, context_limit_reached)
       when is_integer(max_tool_rounds) and is_boolean(context_limit_reached) do
    state.tool_round < max_tool_rounds and not context_limit_reached
  end

  defp manual_handoff_generation?(%{context: %{completion_effect: :manual_handoff}}), do: true

  defp manual_handoff_generation?(_state), do: false

  defp manual_handoff_refusal_payload do
    %{
      text:
        "[tool error] Tool call refused while preparing a handoff summary. " <>
          "Create the handoff summary using the information already available.",
      raw: %{"error" => "manual_handoff_tool_call_refused"}
    }
  end

  defp mixed_handoff_refusal_payload do
    %{
      text:
        "[tool error] Tool call refused because handoff must be called by itself. " <>
          "Only the first handoff call in this response is executed.",
      raw: %{"error" => "handoff_must_be_called_alone"}
    }
  end

  defp context_limit_refusal_instruction(true) do
    "Non-handoff tool calls will be refused. " <>
      "If more work is needed, call the available handoff tool with a continuation summary; " <>
      "otherwise provide the final answer using the information already available."
  end

  defp context_limit_refusal_instruction(_handoff_available) do
    "Please proceed to the final answer using the information already available."
  end

  defp refusal_result_payload(
         state,
         max_tool_rounds,
         true,
         total_tokens,
         length,
         soft_limit
       )
       when is_integer(max_tool_rounds) do
    handoff_available = handoff_available?(state)

    %{
      text:
        "[tool error] Context limit reached (#{total_tokens}/#{length} > #{soft_limit}). " <>
          context_limit_refusal_instruction(handoff_available),
      raw: %{
        "error" => "context_limit_reached",
        "context_length" => length,
        "context_soft_limit" => soft_limit,
        "context_soft_limit_percent" => state.context.context_soft_limit_percent,
        "handoff_available" => handoff_available,
        "total_tokens" => total_tokens
      }
    }
  end

  defp refusal_result_payload(
         _state,
         max_tool_rounds,
         false,
         _total_tokens,
         _length,
         _soft_limit
       )
       when is_integer(max_tool_rounds) do
    %{
      text:
        "[tool error] Tool call limit reached (max_tool_rounds=#{max_tool_rounds}). " <>
          "Please proceed to the final answer using the information already available.",
      raw: %{
        "error" => "tool_call_limit_reached",
        "max_tool_rounds" => max_tool_rounds
      }
    }
  end

  defp build_refusal_results(tool_calls, refusal) when is_list(tool_calls) and is_map(refusal) do
    refusal_text = Map.get(refusal, :text, "")
    refusal_raw = Map.get(refusal, :raw, %{})

    Enum.map(tool_calls, fn call ->
      call
      |> tool_call_to_map()
      |> Map.merge(%{
        text: refusal_text,
        result_raw: refusal_raw,
        media_contents: [],
        artifact_contents: []
      })
    end)
  end

  defp handoff_tool_payload?(state, payload) when is_map(payload) do
    handoff_tool_name?(state, tool_payload_name(payload))
  end

  defp handoff_tool_payload?(_state, _payload), do: false

  # Linked forks keep the parent's tool list, including a handoff tool that subchat
  # policy may reject, so availability also checks that policy.
  defp handoff_available?(state) do
    state
    |> handoff_tools_payload()
    |> Enum.any?(&handoff_tool_allowed?(state, &1))
  end

  defp handoff_tool_allowed?(state, payload) do
    # Only payloads accepted by handoff_tool_payload?/2 reach this check.
    {alias_value, "handoff"} = payload |> tool_payload_name() |> split_tool_name()
    tool_instance = Map.fetch!(state.context.tool_instances_by_alias, alias_value)

    context = %ExecutionContext{
      owner_id: state.context.owner_id,
      chat_id: state.context.chat_id
    }

    Subagent.ensure_handoff_allowed(tool_instance, context) == :ok
  end

  defp tool_payload_name(payload) do
    case Map.get(payload, "function") do
      %{} = function -> Map.get(function, "name")
      _other -> Map.get(payload, "name")
    end
  end

  defp handoff_tool_call?(state, call) do
    call
    |> tool_call_to_map()
    |> Map.get(:name)
    |> then(&handoff_tool_name?(state, &1))
  end

  defp mixed_handoff_tool_calls?(state, tool_calls) when is_list(tool_calls) do
    length(tool_calls) > 1 and Enum.any?(tool_calls, &handoff_tool_call?(state, &1))
  end

  defp handoff_tool_name?(state, name) when is_binary(name) do
    with {alias_value, "handoff"} <- split_tool_name(name),
         %{} = tool_instance <- Map.get(state.context.tool_instances_by_alias || %{}, alias_value),
         true <- ToolRegistry.supports_handoff?(tool_instance) do
      true
    else
      _other -> false
    end
  end

  defp handoff_tool_name?(_state, _name), do: false

  defp split_tool_name(name) when is_binary(name) do
    case String.split(name, "__", parts: 2) do
      [alias_value, function_name] when alias_value != "" and function_name != "" ->
        {alias_value, function_name}

      _other ->
        nil
    end
  end

  defp soft_refuse_tool_calls(state, tool_calls, refusal, opts)
       when is_list(tool_calls) and is_map(refusal) and is_list(opts) do
    if Keyword.get(opts, :allow_handoff?, false) do
      {handoff_calls, refused_calls} = Enum.split_with(tool_calls, &handoff_tool_call?(state, &1))

      case handoff_calls do
        [] ->
          refusal_results = build_refusal_results(refused_calls, refusal)

          {:noreply,
           start_tool_task(state, [], refusal_results,
             tool_round_delta: 0,
             refusal_round_delta: 1
           )}

        [handoff_call | duplicate_handoff_calls] ->
          refusal_results =
            build_refusal_results(refused_calls ++ duplicate_handoff_calls, refusal)

          state = start_tool_task(state, [handoff_call], refusal_results)
          {:noreply, state}
      end
    else
      results = build_refusal_results(tool_calls, refusal)

      {:noreply, start_tool_task(state, [], results, tool_round_delta: 0, refusal_round_delta: 1)}
    end
  end

  defp finalize_tool_loop_exhausted(state, max_tool_rounds) when is_integer(max_tool_rounds) do
    error_text =
      "Tool calling did not converge to a final answer. " <>
        "Executed tool rounds: #{state.tool_round}/#{max_tool_rounds}. " <>
        "Refused tool rounds: #{state.refusal_round}/#{@max_refusal_rounds}."

    finalize_error(state, error_text, %{})
  end

  defp start_tool_task(state, tool_calls) when is_list(tool_calls) do
    start_tool_task(state, tool_calls, [])
  end

  defp start_tool_task(state, tool_calls, prebuilt_results, opts \\ [])
       when is_list(tool_calls) and is_list(prebuilt_results) and is_list(opts) do
    ensure_dispatch_allowed!(state)
    tool_instances_by_alias = state.context.tool_instances_by_alias || %{}
    execution_context = tool_execution_context(state)
    message_id = state.context.message_id
    step_id = state.runtime_step.id
    lease = state.lease
    owner = self()

    task =
      Task.async(fn ->
        Process.flag(:trap_exit, true)

        Enum.each(prebuilt_results, fn result ->
          call =
            tool_call_from_result(result) ||
              raise ArgumentError, "Tool result has no persisted call"

          ToolExecution.run(owner, fn ->
            persist_tool_result!(lease, message_id, step_id, call, result)
          end)
        end)

        {:tool_results,
         execute_and_persist_tool_calls(
           message_id,
           step_id,
           tool_calls,
           tool_instances_by_alias,
           execution_context,
           lease,
           owner
         )
         |> Kernel.++(prebuilt_results)
         |> order_tool_results()}
      end)

    %{
      state
      | tool_task: task,
        tool_result_opts: opts,
        tool_cancel_requested?: false,
        phase: :tools
    }
  end

  defp execute_and_persist_tool_calls(
         message_id,
         step_id,
         tool_calls,
         tool_instances_by_alias,
         execution_context,
         lease,
         owner
       )
       when is_integer(message_id) and is_integer(step_id) and is_list(tool_calls) do
    max_concurrency =
      tool_calls
      |> length()
      |> min(@max_parallel_tool_calls)
      |> max(1)

    tool_calls
    |> Task.async_stream(
      fn call ->
        ToolExecution.run(owner, fn ->
          execution_context = execution_context_for_tool_call(execution_context, call)

          result =
            Executor.execute_llm_tool(
              tool_instances_by_alias,
              call.name,
              call.args || %{},
              execution_context
            )

          result = decorate_tool_result(call, result)
          ToolExecution.checkpoint()
          persist_tool_result!(lease, message_id, step_id, call, result)
          result
        end)
      end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce({[], nil}, fn
      {:ok, {:completed, result}}, {results, error} ->
        {[result | results], error}

      {:ok, :canceled}, acc ->
        acc

      {:exit, reason}, {results, error} ->
        send(owner, {:tool_batch_failed, self()})
        {results, error || reason}
    end)
    |> then(fn
      {results, nil} -> results
      {_results, reason} -> exit(reason)
    end)
  end

  defp persist_tool_result!(%Lease{} = lease, message_id, step_id, call, result) do
    case Lease.with_fence(
           lease,
           fn -> Persistence.persist_tool_result!(message_id, step_id, call, result) end,
           require_generating?: true
         ) do
      {:ok, persisted} -> persisted
      {:error, reason} -> exit({:generation_lease_lost, reason})
    end
  end

  defp persist_tool_result!(nil, message_id, step_id, call, result) do
    Persistence.persist_tool_result!(message_id, step_id, call, result)
  end

  defp order_tool_results(results) when is_list(results) do
    Enum.sort_by(results, fn result ->
      map = tool_call_to_map(result)
      sequence = Map.get(map, :sequence)
      name = Map.get(map, :name, "")
      {if(is_integer(sequence), do: sequence, else: 0), to_string(name)}
    end)
  end

  defp handle_tool_results(state, results) when is_list(results) do
    handle_tool_results(state, results, [])
  end

  defp handle_tool_results(state, results, opts) when is_list(results) and is_list(opts) do
    {:noreply,
     begin_step_transition(state, {:tool_followup, opts}, :followup, fn ->
       with {:ok, persisted} <-
              safe_persist_value(state, :tool_results, fn ->
                Persistence.load_step_for_followup!(state.runtime_step.id,
                  raw_request: state.runtime_step.raw_request
                )
              end) do
         case handoff_payload(persisted.results) do
           %{} = payload ->
             {:ok, {:handoff, payload}}

           nil ->
             case prepare_tool_followup(state, persisted) do
               {:ok, _followup, next_step} -> {:ok, {:next_step, next_step}}
               {:error, reason} -> {:error, reason}
             end
         end
       end
     end)}
  end

  defp handoff_payload(results) when is_list(results) do
    Enum.find_value(results, fn result ->
      raw =
        result
        |> tool_call_to_map()
        |> Map.get(:result_raw, %{})

      handoff_payload_from_raw(raw)
    end)
  end

  defp handoff_payload(_results), do: nil

  defp handoff_payload_from_raw(%{"handoff" => %{} = payload}), do: payload
  defp handoff_payload_from_raw(_raw), do: nil

  defp build_followup_with_steering(state, persisted) do
    try do
      followup =
        state.adapter.build_followup_request(%{
          context: state.context,
          runtime_step: persisted.runtime_step,
          results: persisted.results,
          tools: current_tools_payload(state)
        })

      with {:ok, followup} <-
             maybe_inject_steering(state, followup, Map.get(persisted, :steering_items, [])) do
        case read_pending_steers(state) do
          {:ok, queued_messages} ->
            specs = queued_steering_specs(queued_messages)

            case maybe_inject_steering(
                   state,
                   followup,
                   Enum.map(specs, &%{text: &1.text, placement: :before_response})
                 ) do
              {:ok, injected} -> {:ok, injected, specs}
              {:error, reason} -> {:error, {:steering_rejected, reason, specs}}
            end

          {:error, reason} ->
            {:error, {:steering_rejected, reason, nil}}
        end
      end
    rescue
      exception ->
        {:error,
         PersistenceFailure.new(exception, operation: :tool_followup, stacktrace: __STACKTRACE__)}
    catch
      :exit, reason -> {:error, PersistenceFailure.task_down(reason, :tool_followup)}
      kind, reason -> {:error, PersistenceFailure.new({kind, reason}, operation: :tool_followup)}
    end
  end

  defp maybe_inject_steering(_state, followup, []), do: {:ok, followup}

  defp maybe_inject_steering(state, followup, steering_items) do
    inject_steering_request(state, followup.raw_request, steering_items)
  end

  defp prepare_tool_followup(state, persisted, attempt \\ 0) do
    with {:ok, followup, queued_specs} <- build_followup_with_steering(state, persisted) do
      result =
        safe_request_persist_value(state, :step_done, fn ->
          if queued_specs == [] do
            Persistence.complete_step_and_start_next!(
              state.context.message_id,
              state.runtime_step.id,
              state.step_sequence + 1,
              followup.raw_request,
              request_step_options(state)
            )
          else
            Persistence.complete_step_and_start_next_with_queued_steering!(
              state.context.message_id,
              state.runtime_step.id,
              state.step_sequence + 1,
              followup.raw_request,
              queued_specs,
              request_step_options(state)
            )
          end
        end)

      case result do
        {:ok, next_step} when is_map(next_step) ->
          {:ok, followup, next_step}

        {:ok, {:error, :queued_steering_changed}} when attempt < 8 ->
          prepare_tool_followup(state, persisted, attempt + 1)

        {:error, :queued_steering_changed} when attempt < 8 ->
          prepare_tool_followup(state, persisted, attempt + 1)

        {:ok, {:error, reason}} ->
          {:error, {:steering_rejected, reason, queued_specs}}

        {:error, reason} when queued_specs != [] ->
          {:error, {:steering_rejected, reason, queued_specs}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp continue_after_tool_step(next_state, next_step, opts) do
    raw_request = next_step.raw_request
    step_id = next_step.step_id
    next_sequence = next_state.step_sequence + 1

    runtime_step =
      Map.get(next_step, :runtime_step) ||
        RuntimeTrace.new_step(
          id: step_id,
          sequence: next_sequence,
          started_at: DateTime.utc_now(),
          status: :waiting_provider,
          raw_request: raw_request
        )

    state =
      %{next_state | steering_attempt: nil}
      |> install_runtime_step(runtime_step)
      |> install_request_images(next_step)
      |> Map.put(:step_attempt, 1)
      |> Map.put(:tool_round, next_state.tool_round + Keyword.get(opts, :tool_round_delta, 1))
      |> Map.put(
        :refusal_round,
        next_state.refusal_round + Keyword.get(opts, :refusal_round_delta, 0)
      )
      |> Map.put(:retry_timer_ref, nil)
      |> Map.put(:stream_task, nil)

    advance(state, :start_stream)
  end

  # Only this coordinator may launch a persistence operation. In-flight writes
  # are never fire-and-forget, and command handling never starts a second write.
  defp begin_persistence(%{persistence_op: nil} = state, action, fun) do
    state = %{state | phase: :persisting}
    kind = if is_tuple(action), do: elem(action, 0), else: action

    operation =
      PersistenceOperation.start(
        kind,
        state.context.message_id,
        operation_step_id(state),
        state.lease,
        fun
      )

    %{state | persistence_op: operation, persistence_action: action}
  end

  defp operation_step_id(%{runtime_step: %{id: id}}), do: id
  defp operation_step_id(state), do: Map.get(state.context, :step_id)

  defp persistence_finished(state, :initialize, {:ok, {initialized, continue}}) do
    state = struct(state, initialized)
    advance(state, {:continue, continue})
  end

  defp persistence_finished(
         state,
         :provider_completed,
         {:ok, %{step: step, tool_calls: tool_calls}}
       ) do
    runtime_step = %{state.runtime_step | id: step.id, status: step.status}
    state = install_runtime_step(state, runtime_step)
    continuation = if tool_calls == [], do: {:done, step.id, []}, else: {:tool_calls, tool_calls}
    advance(state, continuation)
  end

  defp persistence_finished(state, :resume_waiting_tools, {:ok, []}) do
    advance(state, {:tool_results, [], []})
  end

  defp persistence_finished(state, :resume_waiting_tools, {:ok, calls}) when is_list(calls) do
    advance(state, {:resume_tools, calls})
  end

  defp persistence_finished(
         state,
         {:auto_retry, attempt, delay},
         {:ok, %{runtime_step: runtime_step} = result}
       ) do
    state =
      state
      |> install_runtime_step(runtime_step)
      |> install_request_images(result)
      |> Map.put(:step_attempt, attempt + 1)

    advance(state, {:backoff, delay})
  end

  defp persistence_finished(state, {:tool_followup, opts}, {:ok, {:next_step, next_step}}) do
    continue_after_tool_step(state, next_step, opts)
  end

  defp persistence_finished(state, {:tool_followup, _opts}, {:ok, {:handoff, payload}}) do
    advance(
      %{state | steering_attempt: nil},
      {:done, state.runtime_step.id, [terminal_handoff: payload]}
    )
  end

  defp persistence_finished(state, {:queued_steers, continuation, _retry?, _started?}, {:ok, nil}) do
    continuation = if state.continuation == :idle, do: continuation, else: state.continuation
    state = %{state | queued_steering_retry_attempt: 0, steering_attempt: nil}
    advance(state, continuation)
  end

  defp persistence_finished(
         state,
         {:queued_steers, _continuation, _retry?, _started?} = action,
         {:ok, persisted}
       )
       when is_map(persisted) do
    install_provider_steering(state, action, persisted)
  end

  defp persistence_finished(
         state,
         {:queued_steers, _continuation, _retry?, _started?},
         {:ok, {:error, :queued_steering_changed}}
       ) do
    retry_queued_steering(state)
  end

  defp persistence_finished(
         state,
         {:queued_steers, _continuation, _retry?, _started?},
         {:error, :queued_steering_changed}
       ) do
    retry_queued_steering(state)
  end

  defp persistence_finished(state, {:interrupted_provider, action, persisted}, {:ok, :ok}) do
    finish_provider_steering(state, action, persisted)
  end

  defp persistence_finished(state, {:done, _step_id}, {:ok, effect}) do
    BackgroundTasks.cancel_for_lifecycle_message_async(state.context.message_id)

    case effect do
      {:queue_boundary, queue_result} -> finish_done_queue(state, queue_result)
      {:handoff, result} -> finish_manual_handoff_queue(state, result)
      {:terminal_handoff, payload, _transfer} -> finish_terminal_handoff_queue(state, payload)
    end

    broadcast(state, {:done, state.context.message_id})
    finish_terminal(state, :done)
  end

  defp persistence_finished(state, {:error, error_text}, {:ok, :ok}) do
    finish_error_queue(state)
    broadcast(state, {:error, state.context.message_id, error_text})
    finish_terminal(state, :error)
  end

  defp persistence_finished(state, action, {:ok, :ok})
       when action in [:cancel, :cancel_recovery] do
    BackgroundTasks.cancel_for_lifecycle_message_async(state.context.message_id)
    maybe_finish_canceled_queue(state, :ok)
    broadcast(state, {:canceled, state.context.message_id})
    finish_terminal(state, :canceled)
  end

  defp persistence_finished(state, action, {:ok, {:finished, status}})
       when action in [:cancel, :cancel_recovery] do
    finish_terminal(state, status)
  end

  defp persistence_finished(state, {:error, _text}, {:ok, {:finished, status}}) do
    finish_terminal(state, status)
  end

  defp persistence_finished(state, {:failure_resolution, plan}, {:ok, :recorded}) do
    if state.cancel_requested? and is_nil(plan.terminal_status) do
      resolve_failure(state, %{plan | terminal_status: :canceled})
    else
      stop_for_recovery(state, plan.error)
    end
  end

  defp persistence_finished(state, {:failure_resolution, _plan}, {:ok, {:finished, status}}) do
    finish_terminal(state, status)
  end

  defp persistence_finished(state, {:failure_resolution, plan}, {:ok, status})
       when status in [:error, :canceled, :done] do
    event =
      if status == :error,
        do: {:error, state.context.message_id, plan.error},
        else: {status, state.context.message_id}

    broadcast(state, event)
    finish_terminal(state, status)
  end

  defp persistence_finished(state, {:failure_resolution, plan}, result) do
    retry_failure_resolution(state, plan, failure_from_result(result, :failure_resolution))
  end

  defp persistence_finished(state, :steering_reconciliation, {:ok, {:applied, persisted}}) do
    action = state.steering_attempt.action

    result =
      if match?({:tool_followup, _opts}, action), do: {:next_step, persisted}, else: persisted

    persistence_finished(%{state | steering_attempt: nil}, action, {:ok, result})
  end

  defp persistence_finished(state, :steering_reconciliation, {:ok, :not_applied}) do
    if rejected_queue_batch?(state.steering_attempt),
      do: reject_queued_steering(state),
      else: reject_steering_command(state)
  end

  defp persistence_finished(state, :steering_rejection, {:ok, :ok}) do
    reject_steering_command(state)
  end

  defp persistence_finished(state, :steering_rejection, result) do
    retry_steering_reconciliation(state, failure_from_result(result, :steering_rejection))
  end

  defp persistence_finished(state, :steering_reconciliation, result) do
    retry_steering_reconciliation(state, failure_from_result(result, :steering_reconciliation))
  end

  defp persistence_finished(state, action, result) do
    operation_failed(state, action, failure_from_result(result, action_kind(action)))
  end

  defp failure_from_result({:error, reason}, operation),
    do: PersistenceFailure.new(reason, operation: operation)

  defp failure_from_result(result, operation),
    do: PersistenceFailure.new({:unexpected_result, result}, operation: operation)

  defp install_provider_steering(state, action, persisted) do
    state = %{state | steering_attempt: nil}
    # Until provider completion is durably acknowledged, steering still replaces
    # the request. Account for an already received response on its source step,
    # but never persist its interrupted answer/tool items or dispatch its tools.
    source_step = absorb_deferred_provider_meta(state).runtime_step

    {:queued_steers, _continuation, retry?, started?} = action
    attempt_delta = if started? and not retry?, do: 1, else: 0
    queued_steering_retry_attempt = 0

    state =
      state
      |> cancel_retry_timer()
      |> cancel_stream_task()
      |> stop_provider_session()
      |> install_runtime_step(persisted.runtime_step)
      |> install_request_images(persisted)

    state = %{
      state
      | deferred_provider_event: nil,
        queued_steering_retry_attempt: queued_steering_retry_attempt,
        step_attempt: state.step_attempt + attempt_delta
    }

    if source_step.response_final or not is_nil(source_step.usage) or
         not is_nil(source_step.raw_response) do
      {:noreply,
       begin_persistence(state, {:interrupted_provider, action, persisted}, fn ->
         safe_persist_value(state, :interrupted_provider, fn ->
           Persistence.persist_interrupted_provider_response!(
             state.context.message_id,
             source_step,
             persisted.step_id
           )
         end)
       end)}
    else
      finish_provider_steering(state, action, persisted)
    end
  end

  defp finish_provider_steering(state, {:queued_steers, _, _, _}, _persisted) do
    broadcast(state, {:steering, state.context.message_id})
    advance(state, {:start_stream, :queue_checked})
  end

  defp steering_operation_failed(state, attempt, action, failure) do
    {reason, specs} =
      case failure.reason do
        {:steering_rejected, reason, specs} -> {reason, specs}
        _reason -> {failure, nil}
      end

    failure = PersistenceFailure.new(reason, operation: action_kind(action))
    PersistenceFailure.log(failure, state.context.message_id, attempt.step_id)

    if failure.kind == :lease_lost do
      stop_obsolete_owner(state)
    else
      attempt =
        Map.merge(attempt, %{failure: failure, specs: specs, resolving?: true, retries: 0})

      reconcile_steering(%{state | steering_attempt: attempt})
    end
  end

  defp operation_failed(state, operation, failure)
       when operation in [:steering_reconciliation, :steering_rejection] do
    retry_steering_reconciliation(state, failure)
  end

  defp operation_failed(
         %{steering_attempt: %{} = attempt} = state,
         {:tool_followup, _opts} = action,
         %PersistenceFailure{reason: {:steering_rejected, _reason, _specs}} = failure
       ) do
    steering_operation_failed(state, attempt, action, failure)
  end

  defp operation_failed(
         %{steering_attempt: %{} = attempt} = state,
         {:tool_followup, _opts} = action,
         %PersistenceFailure{kind: :unknown} = failure
       ) do
    steering_operation_failed(state, attempt, action, failure)
  end

  defp operation_failed(
         %{steering_attempt: %{} = _attempt} = state,
         {:tool_followup, _opts} = action,
         failure
       ) do
    operation_failed(%{state | steering_attempt: nil}, action, failure)
  end

  defp operation_failed(%{steering_attempt: %{} = attempt} = state, action, failure)
       when is_tuple(action) and elem(action, 0) == :queued_steers do
    steering_operation_failed(state, attempt, action, failure)
  end

  defp operation_failed(state, {:failure_resolution, plan}, failure) do
    retry_failure_resolution(state, plan, failure)
  end

  defp operation_failed(state, action, %PersistenceFailure{} = failure) do
    failure = %{failure | operation: action_kind(action)}
    PersistenceFailure.log(failure, state.context.message_id, operation_step_id(state))

    if failure.kind == :lease_lost do
      # An obsolete owner may neither terminalize nor mark the successor.
      stop_obsolete_owner(state)
    else
      terminal_status =
        cond do
          state.cancel_requested? or action_kind(action) in [:cancel, :cancel_recovery] ->
            :canceled

          action_kind(action) in [:error, :terminal_error] ->
            :error

          failure.kind in [:permanent, :retry_exhausted] ->
            :error

          true ->
            nil
        end

      error =
        case action do
          {:error, original} -> to_string(original)
          {:terminal_error, original} -> to_string(original)
          _ -> PersistenceFailure.summary(failure)
        end

      resolve_failure(state, %{
        operation: action_kind(action),
        error: error,
        terminal_status: terminal_status,
        attempt: 0
      })
    end
  end

  defp resolve_failure(state, plan) do
    state = state |> cancel_tasks() |> stop_provider_session()
    plan = failure_plan_for_cancel(state, plan)

    state = %{
      state
      | failure_plan: plan,
        deferred_provider_event: nil,
        deferred_tool_outcome: nil
    }

    actor = %User{id: state.context.owner_id}

    {:noreply,
     begin_persistence(state, {:failure_resolution, plan}, fn ->
       PersistenceFailure.capture(
         fn ->
           case RecoveryGate.record_failure(state.context.message_id, state.lease, actor,
                  operation: plan.operation,
                  error: plan.error,
                  terminal_status: plan.terminal_status
                ) do
             {:ok, :recorded} when not is_nil(plan.terminal_status) ->
               RecoveryGate.finish(state.context.message_id, state.lease, actor)

             other ->
               other
           end
         end,
         :failure_resolution
       )
     end)}
  end

  defp failure_plan_for_cancel(%{cancel_requested?: true}, %{terminal_status: nil} = plan),
    do: %{plan | terminal_status: :canceled}

  defp failure_plan_for_cancel(_state, plan), do: plan

  defp retry_failure_resolution(state, plan, failure) do
    cond do
      failure.kind == :lease_lost ->
        operation_failed(state, :failure_resolution, failure)

      failure.kind in [:permanent, :retry_exhausted] and plan.attempt >= 2 ->
        # A broken finalizer is not a database outage. Stop this owner after a
        # bounded attempt; the durable terminal intent makes later recovery
        # terminal-only. If intent registration itself failed, admission still
        # bounds restarts instead of resetting the budget with a new Worker.
        PersistenceFailure.log(failure, state.context.message_id, operation_step_id(state))

        Logger.error(
          "Generation failure reconciliation exhausted message_id=#{state.context.message_id}"
        )

        stop_for_recovery(state, plan.error)

      true ->
        # Retry ONLY the intent/terminal reconciliation, never the failed provider,
        # tool or snapshot. Once recorded, the intent also survives owner death.
        attempt = plan.attempt + 1
        delay = Enum.at([250, 1_000, 5_000], min(attempt - 1, 2))
        token = make_ref()
        timer = Process.send_after(self(), {:retry_failure_resolution, token}, delay)
        PersistenceFailure.log(failure, state.context.message_id, operation_step_id(state))

        Logger.warning(
          "Generation error finalization pending message_id=#{state.context.message_id} " <>
            "attempt=#{attempt} delay_ms=#{delay}"
        )

        {:noreply,
         %{
           state
           | failure_plan: %{plan | attempt: attempt},
             failure_retry_timer: {timer, token},
             phase: :recovering
         }}
    end
  end

  defp action_kind(action) when is_tuple(action), do: elem(action, 0)
  defp action_kind(action), do: action

  defp retry_queued_steering(state) do
    state =
      queued_steering_retry_state(%{state | steering_attempt: nil}, :queued_steering_changed)

    schedule_queued_steering_retry(state)
    advance(state, :idle)
  end

  defp request_cancel(state, from) do
    waiters = if is_nil(from), do: state.cancel_waiters, else: [from | state.cancel_waiters]
    state = state |> absorb_deferred_provider_meta() |> cancel_tasks()

    state = %{
      state
      | cancel_requested?: true,
        cancel_waiters: waiters,
        deferred_provider_event: nil,
        deferred_tool_outcome: nil
    }

    advance(state, :idle)
  end

  defp absorb_deferred_provider_meta(
         %{
           stream_ref: ref,
           deferred_provider_event: {:provider_event, ref, {kind, meta}}
         } = state
       )
       when kind in [:response_complete, :response_error] do
    # A terminal event can arrive while a queued-steering read is in flight.
    # Cancellation and steering must retain its already-received usage. A
    # committed steering successor accounts for this source separately, never
    # copying the response or usage into the receiving step.
    step =
      state.runtime_step
      |> apply_trace_meta(meta, state.context)
      |> RuntimeTrace.apply_event({:set_step_response_final, kind == :response_complete})

    %{state | runtime_step: step}
  end

  defp absorb_deferred_provider_meta(state), do: state

  # Install every successful commit first, then honor cancel/steer, then resume.
  # Steering before a provider-completion commit interrupts the source; its
  # deferred response is accounted separately before the receiving step runs.
  # In particular, a canceled follow-up cancels its NEW step, never the old raw.
  defp advance(%{lease_lost?: true, persistence_op: nil, tool_task: nil} = state, _continuation),
    do: stop_obsolete_owner(state)

  defp advance(%{lease_lost?: true} = state, _continuation), do: {:noreply, state}

  defp advance(%{persistence_op: %PersistenceOperation{}} = state, continuation) do
    {:noreply, %{state | continuation: continuation}}
  end

  defp advance(%{steering_attempt: %{resolving?: true}} = state, continuation),
    do: {:noreply, %{state | continuation: continuation}}

  defp advance(%{failure_plan: plan} = state, _continuation) when not is_nil(plan),
    do: {:noreply, state}

  defp advance(%{cancel_requested?: true, tool_task: %Task{}} = state, _continuation),
    do: {:noreply, %{cancel_tool_task(state) | continuation: :idle}}

  defp advance(%{cancel_requested?: true} = state, _continuation) do
    state = %{cancel_tasks(state) | continuation: :idle}
    {:noreply, begin_persistence(state, :cancel, fn -> persist_cancellation(state) end)}
  end

  defp advance(%{deferred_provider_event: event} = state, _continuation) when not is_nil(event) do
    handle_info(event, %{state | deferred_provider_event: nil, continuation: :idle})
  end

  defp advance(%{deferred_tool_outcome: outcome} = state, _continuation)
       when not is_nil(outcome) do
    state = %{state | deferred_tool_outcome: nil, continuation: :idle}

    case outcome do
      {:results, results, opts} -> handle_tool_results(state, results, opts)
      {:error, error_text} -> finalize_error(state, error_text)
    end
  end

  defp advance(
         %{queue_dirty?: true, runtime_step: %{status: :waiting_provider}} = state,
         continuation
       ) do
    begin_queued_steers(state, continuation)
  end

  defp advance(state, continuation) do
    dispatch_continuation(%{state | continuation: :idle}, continuation)
  end

  defp dispatch_continuation(state, {:continue, continue}), do: handle_continue(continue, state)

  defp dispatch_continuation(state, :start_stream),
    do: begin_queued_steers(state, {:start_stream, :queue_checked})

  defp dispatch_continuation(state, {:start_stream, :queue_checked}),
    do: {:noreply, start_stream_task(state)}

  defp dispatch_continuation(state, {:tool_calls, calls}),
    do: handle_persisted_tool_calls(state, calls)

  defp dispatch_continuation(state, {:resume_tools, calls}),
    do: {:noreply, start_tool_task(state, calls)}

  defp dispatch_continuation(state, {:tool_results, results, opts}),
    do: handle_tool_results(state, results, opts)

  defp dispatch_continuation(state, {:done, step_id, opts}),
    do: finalize_done_from_step(state, step_id, opts)

  defp dispatch_continuation(state, {:backoff, delay}) do
    token = make_ref()
    timer = Process.send_after(self(), {:retry_current_step, token}, delay)
    {:noreply, %{state | retry_timer_ref: {timer, token}, phase: :backoff}}
  end

  defp dispatch_continuation(state, :idle) do
    phase =
      cond do
        state.retry_timer_ref -> :backoff
        state.tool_task -> :tools
        state.stream_ref -> :provider
        true -> :initializing
      end

    {:noreply, %{state | phase: phase}}
  end

  defp finish_terminal(state, status) do
    cancel_result = if status == :canceled, do: :ok, else: {:error, :generation_not_active}
    reply_pending_commands(state, cancel_result)

    runtime_step =
      case state.runtime_step do
        %RuntimeTrace.Step{} = step ->
          %{step | status: status}

        nil ->
          nil
      end

    state =
      %{
        state
        | runtime_step: runtime_step,
          status: status,
          phase: status,
          cancel_waiters: []
      }

    {:stop, :normal, state}
  end

  # A confirmed terminal commit may resolve pending cancel callers even after
  # validation observes its cleared fence. All intermediate results are discarded.
  defp terminal_acknowledgement?({:done, _step_id}, {:ok, effect}) do
    match?({:queue_boundary, _}, effect) or match?({:handoff, _}, effect) or
      match?({:terminal_handoff, _, _}, effect)
  end

  defp terminal_acknowledgement?({:error, _text}, {:ok, :ok}), do: true

  defp terminal_acknowledgement?(action, {:ok, :ok})
       when action in [:cancel, :cancel_recovery], do: true

  defp terminal_acknowledgement?(action, {:ok, {:finished, status}})
       when status in [:done, :error, :canceled],
       do: action_kind(action) in [:error, :cancel, :cancel_recovery, :failure_resolution]

  defp terminal_acknowledgement?({:failure_resolution, _plan}, {:ok, status})
       when status in [:done, :error, :canceled], do: true

  defp terminal_acknowledgement?(_action, _result), do: false

  defp stop_obsolete_owner(state) do
    reply_pending_commands(state, {:error, :generation_not_active})
    {:stop, :normal, state |> cancel_tasks() |> stop_provider_session()}
  end

  defp stop_for_recovery(state, reason) do
    Logger.warning(
      "Generation persistence requires recovery " <>
        "message_id=#{state.context.message_id} reason=#{inspect(reason)}"
    )

    reply_pending_commands(state, {:error, :persistence_outcome_unknown})

    state =
      %{state | phase: :recovering, cancel_waiters: []}

    {:stop, :normal, state}
  end

  defp reply_pending_commands(state, cancel_result) do
    Enum.each(state.cancel_waiters, &GenServer.reply(&1, cancel_result))
  end

  defp ensure_dispatch_allowed!(state) do
    if state.persistence_op || state.failure_plan || state.steering_attempt || state.lease_lost? ||
         state.cancel_requested? ||
         not Lease.dispatch_allowed?(state.lease) do
      exit({:generation_lease_lost, :dispatch_not_allowed})
    end

    :ok
  end

  defp ensure_provider_session(%{provider_session: nil} = state) do
    %{state | provider_session: start_provider_session(state.adapter, state.context)}
  end

  defp ensure_provider_session(state), do: state

  defp runtime_snapshot(%{runtime_step: nil}), do: nil

  defp runtime_snapshot(state) do
    state.runtime_step
    |> RuntimeTrace.snapshot()
    |> Map.drop([:raw_request, :raw_response])
    |> Serializer.normalize_runtime_step_for_client()
  end

  defp public_snapshot(state) do
    # Initialization is an active generation; phase carries its progress while
    # the public message status keeps polling and generation controls active.
    status = if state.status == :initializing, do: :generating, else: state.status
    %{status: status, phase: state.phase, step: runtime_snapshot(state)}
  end

  defp request_step_options(state) do
    [
      request_context: Map.put(state.context, :adapter_module, state.adapter),
      source_step_id: state.runtime_step.id,
      previous_request: state.runtime_step.raw_request,
      source_image_state: state.request_images,
      image_cache: state.image_cache,
      lease: state.lease
    ]
  end

  defp install_runtime_step(state, runtime_step) do
    context =
      state.context
      |> Map.put(:step_id, runtime_step.id)
      |> Map.put(:request_payload, runtime_step.raw_request)

    state =
      if state.runtime_step && state.runtime_step.id == runtime_step.id do
        state
      else
        %{state | request_images: nil, image_cache: %{}}
      end

    %{state | context: context, runtime_step: runtime_step, step_sequence: runtime_step.sequence}
  end

  defp install_request_images(state, %{request_images: %{step_id: id, request: request} = images})
       when id == state.runtime_step.id and request === state.runtime_step.raw_request do
    %{state | request_images: Map.delete(images, :cache), image_cache: images.cache}
  end

  defp install_request_images(state, _result), do: state

  defp tool_execution_context(state) do
    %ExecutionContext{
      owner_id: Map.get(state.context, :owner_id),
      chat_id: Map.get(state.context, :chat_id),
      root_chat_id: Map.get(state.context, :conversation_affinity_id),
      message_id: Map.get(state.context, :message_id),
      assistant_message_id: Map.get(state.context, :message_id),
      step_id: Map.get(state.runtime_step, :id) || Map.get(state.context, :step_id),
      provider_type: Map.get(state.context, :provider_type),
      available_file_external_ids: Map.get(state.context, :available_file_external_ids, []),
      available_secret_binding_external_ids:
        Map.get(state.context, :available_secret_binding_external_ids, []),
      generation_fence_token:
        case state.lease do
          %Lease{fence_token: fence_token} -> fence_token
          _other -> nil
        end
    }
  end

  defp execution_context_for_tool_call(%ExecutionContext{} = context, call) do
    call = tool_call_to_map(call)

    %{
      context
      | tool_call_item_id: Map.get(call, :item_id),
        tool_call_created_at: Map.get(call, :created_at)
    }
  end

  defp execution_context_for_tool_call(context, _call), do: context

  defp decorate_tool_result(call, %ExecutionResult{} = result) do
    call
    |> tool_call_to_map()
    |> Map.put_new(:raw, %{})
    |> Map.merge(ToolResult.execution_payload(result))
  end

  defp tool_call_from_result(result) when is_map(result) do
    call = tool_call_to_map(result)

    if is_integer(Map.get(call, :item_id)) do
      %IntellectualClub.Generation.ToolCall{
        item_id: Map.get(call, :item_id),
        step_id: Map.get(call, :step_id),
        sequence: Map.get(call, :sequence),
        created_at: Map.get(call, :created_at),
        call_id: to_string(Map.get(call, :call_id) || ""),
        name: to_string(Map.get(call, :name) || ""),
        args: Map.get(call, :args) || %{},
        raw: Map.get(call, :raw) || %{}
      }
    else
      nil
    end
  end

  defp tool_call_to_map(%_struct{} = call), do: Map.from_struct(call)
  defp tool_call_to_map(%{} = call), do: Map.new(call)
  defp tool_call_to_map(_call), do: %{}

  defp provider_error_value?(nil), do: false
  defp provider_error_value?(false), do: false
  defp provider_error_value?(""), do: false
  defp provider_error_value?(%{}), do: true
  defp provider_error_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp provider_error_value?(_other), do: true

  defp apply_trace_meta(%RuntimeTrace.Step{} = runtime_step, meta, context) when is_map(meta) do
    runtime_step
    |> maybe_apply_raw_response(meta)
    |> maybe_apply_usage(meta, context)
  end

  defp apply_trace_meta(%RuntimeTrace.Step{} = runtime_step, _meta, _context), do: runtime_step

  defp maybe_apply_raw_response(runtime_step, meta) do
    raw_response = Map.get(meta, :raw_response)

    if is_map(raw_response) do
      RuntimeTrace.apply_event(runtime_step, {:set_step_raw_response, raw_response})
    else
      runtime_step
    end
  end

  defp maybe_apply_usage(runtime_step, meta, context) do
    usage = Map.get(meta, :usage)

    if is_map(usage) do
      apply_trace_event(runtime_step, {:set_step_usage, usage}, context)
    else
      runtime_step
    end
  end

  defp apply_trace_event(
         %RuntimeTrace.Step{} = runtime_step,
         {:set_step_usage, usage} = trace_event,
         context
       )
       when is_map(usage) and is_map(context) do
    runtime_step = RuntimeTrace.apply_event(runtime_step, trace_event)
    %{runtime_step | cost: UsageCost.resolve(usage, context)}
  end

  defp apply_trace_event(%RuntimeTrace.Step{} = runtime_step, trace_event, _context) do
    RuntimeTrace.apply_event(runtime_step, trace_event)
  end
end
