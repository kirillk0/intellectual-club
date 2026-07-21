defmodule IntellectualClub.Generation.Worker do
  @moduledoc """
  Per-message generation worker.

  It accumulates a canonical runtime trace in memory, broadcasts lightweight
  update signals via PubSub, persists completed steps to the database, and
  finalizes the message when generation finishes.
  """

  use GenServer

  require Logger

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.Common.Registry, as: ProviderRegistry
  alias IntellectualClub.Notifications.Dispatcher, as: NotificationsDispatcher
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.Registry, as: ToolRegistry

  @default_auto_retry_backoff_ms [500, 1_500, 5_000, 15_000, 30_000, 60_000, 120_000, 300_000]
  @default_auto_retry_jitter_ratio 0.2
  @auto_retry_http_status_codes MapSet.new([429, 502, 503])
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
    :retry_timer_ref,
    :step_attempt,
    :step_sequence,
    :tool_round,
    :refusal_round,
    :provider_session
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

  def steer(pid, text) when is_binary(text) do
    GenServer.call(pid, {:steer, text}, 30_000)
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
      register_generation_key!({:message, context.message_id}, %{chat_id: context.chat_id})
      register_generation_key!({:chat, context.chat_id}, %{message_id: context.message_id})
      register_global_generation_key!(context.message_id)

      state = %__MODULE__{
        context: context,
        lease: lease,
        status: :initializing
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

    provider_session = start_provider_session(adapter, context)

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

    state = %__MODULE__{
      context: context,
      lease: lease,
      adapter: adapter,
      status: :generating,
      step_attempt: initial_step_attempt(context, initial_step_sequence),
      step_sequence: initial_step_sequence,
      tool_round: 0,
      refusal_round: 0,
      runtime_step: runtime_step,
      stream_task: nil,
      stream_ref: nil,
      retry_timer_ref: nil,
      provider_session: provider_session
    }

    {state, continue}
  end

  @impl true
  def handle_continue(:initialize, %{context: context, lease: lease} = state) do
    if is_nil(lease) or Lease.valid?(lease) do
      {state, continue} = initialize_state(context, lease)
      {:noreply, state, {:continue, continue}}
    else
      {:stop, :normal, state}
    end
  end

  def handle_continue(:start_stream, state) do
    state = start_stream_task(state)
    {:noreply, state}
  end

  def handle_continue(:resume_waiting_tools, state) do
    case safe_persist_value(state, :resume_waiting_tools, fn ->
           Persistence.list_missing_tool_calls!(state.runtime_step.id)
         end) do
      {:ok, []} ->
        handle_tool_results(state, [], persist_results?: false)

      {:ok, tool_calls} ->
        {:noreply, start_tool_task(state, tool_calls)}

      {:error, reason} ->
        finalize_error(state, "Failed to resume waiting tools: #{inspect(reason)}", %{})
    end
  end

  def handle_continue(:resume_completed_tool_step, state) do
    handle_tool_results(state, [], persist_results?: false)
  end

  @impl true
  def terminate(_reason, state) do
    _ = stop_provider_session(state)
    if state.lease, do: Lease.release(state.lease)
    :ok
  end

  defp start_stream_task(state) do
    step_id = state.runtime_step.id
    raw_request = state.runtime_step.raw_request || %{}

    case safe_persist_value(state, :request_images, fn ->
           materialize_request_images(raw_request, step_id)
         end) do
      {:ok, {:ok, compact_request}} ->
        state
        |> apply_materialized_request(compact_request)
        |> start_provider_stream_task(compact_request, step_id)

      {:ok, {:error, reason}} ->
        request_image_error_state(state, raw_request, reason)

      {:error, reason} ->
        request_image_error_state(state, raw_request, reason)
    end
  end

  defp request_image_error_state(state, raw_request, reason) do
    stream_ref = make_ref()

    send(
      self(),
      {:provider_event, stream_ref,
       {:response_error,
        %{
          provider: state.context.provider_type,
          retryable: false,
          error_kind: "request_media",
          error_text: "Failed to prepare request images: #{inspect(reason)}",
          raw_request: raw_request,
          raw_response: nil
        }}}
    )

    %{state | stream_task: nil, stream_ref: stream_ref, retry_timer_ref: nil}
  end

  defp start_provider_stream_task(state, compact_request, step_id) do
    me = self()
    stream_ref = make_ref()

    task =
      Task.async(fn ->
        emit = fn event -> send(me, {:provider_event, stream_ref, event}) end

        state.adapter.stream_generate(
          %{
            context: state.context,
            request_payload: compact_request,
            request_step_id: step_id,
            timeout_ms: state.context.timeout_ms || 300_000,
            chunk_delay_ms: state.context.chunk_delay_ms,
            provider_session: state.provider_session
          },
          emit
        )
      end)

    %{state | stream_task: task, stream_ref: stream_ref, retry_timer_ref: nil}
  end

  defp materialize_request_images(raw_request, step_id) do
    RequestImages.materialize_and_persist(raw_request, step_id)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp apply_materialized_request(state, compact_request) when is_map(compact_request) do
    runtime_step =
      RuntimeTrace.apply_event(
        state.runtime_step,
        {:set_step_raw_request, compact_request}
      )

    context =
      state.context
      |> Map.put(:request_payload, compact_request)
      |> Map.put(:step_id, runtime_step.id)

    %{state | runtime_step: runtime_step, context: context}
  end

  @impl true
  def handle_info(
        {:provider_event, stream_ref, {:trace, trace_event}},
        %{stream_ref: stream_ref} = state
      ) do
    trace_event = semantic_trace_event(state, trace_event)
    runtime_step = RuntimeTrace.apply_event(state.runtime_step, trace_event)
    maybe_broadcast_text_delta(state, trace_event)
    {:noreply, %{state | runtime_step: runtime_step}}
  end

  @impl true
  def handle_info(
        {:provider_event, stream_ref, {:response_complete, meta}},
        %{stream_ref: stream_ref} = state
      ) do
    runtime_step =
      state.runtime_step
      |> apply_trace_meta(meta)
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
      case safe_persist_value(state, :provider_completed, fn ->
             Persistence.persist_provider_completed!(state.context.message_id, runtime_step)
           end) do
        {:error, reason} ->
          finalize_error(state, "Failed to persist provider step: #{inspect(reason)}", %{})

        {:ok, %{step: persisted_step, tool_calls: tool_calls}} ->
          runtime_step = %{runtime_step | id: persisted_step.id, status: persisted_step.status}
          state = %{state | runtime_step: runtime_step}

          if tool_calls == [] do
            finalize_done_from_step(state, persisted_step.id)
          else
            handle_persisted_tool_calls(state, tool_calls)
          end
      end
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
    state = start_stream_task(%{state | retry_timer_ref: nil})
    {:noreply, state}
  end

  @impl true
  def handle_info({:retry_current_step, _stale_retry_token}, state), do: {:noreply, state}

  @impl true
  def handle_info(:retry_current_step, state), do: {:noreply, state}

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
    state = %{state | tool_task: nil}
    handle_tool_results(state, results)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_task: %Task{ref: ref}} = state) do
    if reason in [:normal, :shutdown] do
      {:noreply, %{state | stream_task: nil}}
    else
      error_text = Exception.format_exit(reason)
      finalize_error(state, error_text)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tool_task: %Task{ref: ref}} = state) do
    if reason in [:normal, :shutdown] do
      {:noreply, %{state | tool_task: nil}}
    else
      error_text = Exception.format_exit(reason)
      finalize_error(state, error_text)
    end
  end

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
  def handle_cast(:cancel, state) do
    {_result, state} = cancel_and_persist(state)

    broadcast(state, {:canceled, state.context.message_id})
    {:stop, :normal, state}
  end

  def handle_cast(:generation_fence_lost, state) do
    state = cancel_tasks(state)
    state = stop_provider_session(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:cancel_and_wait, _from, state) do
    {result, state} = cancel_and_persist(state)

    broadcast(state, {:canceled, state.context.message_id})
    {:stop, :normal, result, state}
  end

  def handle_call({:steer, text}, _from, state) do
    cond do
      text == "" ->
        {:reply, {:error, :empty_steering}, state}

      Map.get(state.context, :supports_steering) != true ->
        {:reply, {:error, :steering_not_supported}, state}

      state.status != :generating ->
        {:reply, {:error, :generation_not_active}, state}

      state.runtime_step.status == :waiting_provider ->
        steer_waiting_provider(state, text)

      state.runtime_step.status == :waiting_tools ->
        steer_waiting_tools(state, text)

      true ->
        {:reply, {:error, :generation_not_active}, state}
    end
  end

  @impl true
  def handle_call(:get_current_state, _from, state) do
    {:reply,
     %{
       status: state.status,
       step: RuntimeTrace.snapshot(state.runtime_step)
     }, state}
  end

  @impl true
  def handle_call({:poll, _cursor, _opts}, _from, state) do
    {:reply,
     %{
       status: state.status,
       step: RuntimeTrace.snapshot(state.runtime_step)
     }, state}
  end

  defp cancel_and_persist(state) do
    state = cancel_tasks(state)
    state = stop_provider_session(state)

    result =
      safe_cancel_persist(state, fn ->
        if durable_waiting_tools_step?(state.runtime_step) do
          Persistence.persist_canceled_from_step!(
            state.context.message_id,
            state.runtime_step.id
          )
        else
          Persistence.persist_canceled!(state.context.message_id, state.runtime_step)
        end
      end)

    {result, %{state | status: :canceled}}
  end

  defp steer_waiting_provider(state, text) do
    steering_items = [%{text: text, placement: :before_response}]
    retry_pending? = not is_nil(state.retry_timer_ref)

    with {:ok, injected} <-
           inject_steering_request(state, state.runtime_step.raw_request, steering_items),
         {:ok, persisted} <-
           safe_persist_value(state, :steering_before_response, fn ->
             Persistence.persist_steering_before_provider!(
               state.context.message_id,
               state.runtime_step.id,
               text,
               injected.raw_request
             )
           end) do
      state =
        state
        |> cancel_retry_timer()
        |> cancel_stream_task()
        |> stop_provider_session()

      provider_session = start_provider_session(state.adapter, state.context)

      state =
        state
        |> Map.put(:provider_session, provider_session)
        |> Map.put(:runtime_step, persisted.runtime_step)
        |> Map.update!(:step_attempt, fn attempt ->
          if retry_pending?, do: attempt, else: attempt + 1
        end)
        |> start_stream_task()

      broadcast(state, {:steering, state.context.message_id})

      {:reply,
       {:ok,
        %{
          message_id: state.context.message_id,
          step_id: state.runtime_step.id,
          item_id: persisted.item_id
        }}, state}
    else
      {:error, reason} -> {:reply, {:error, normalize_steering_error(reason)}, state}
    end
  end

  defp steer_waiting_tools(state, text) do
    with {:ok, persisted} <-
           safe_persist_value(state, :steering_handoff_check, fn ->
             Persistence.load_step_for_followup!(state.runtime_step.id)
           end),
         false <- Enum.any?(persisted.tool_calls, &handoff_tool_call?(state, &1)),
         {:ok, steering} <-
           safe_persist_value(state, :steering_after_response, fn ->
             Persistence.persist_steering_after_provider!(
               state.context.message_id,
               state.runtime_step.id,
               text
             )
           end) do
      state = %{state | runtime_step: steering.runtime_step}
      broadcast(state, {:steering, state.context.message_id})

      {:reply,
       {:ok,
        %{
          message_id: state.context.message_id,
          step_id: state.runtime_step.id,
          item_id: steering.item_id
        }}, state}
    else
      true -> {:reply, {:error, :terminal_handoff_in_progress}, state}
      {:error, reason} -> {:reply, {:error, normalize_steering_error(reason)}, state}
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

  defp normalize_steering_error(reason)
       when reason in [
              :empty_steering,
              :steering_not_supported,
              :generation_not_active,
              :terminal_handoff_in_progress
            ],
       do: reason

  defp normalize_steering_error(reason), do: {:steering_failed, reason}

  defp finalize_done_from_step(state, step_id) when is_integer(step_id) do
    case safe_persist(state, :done, fn ->
           Persistence.persist_completed_from_step!(state.context.message_id, step_id)
         end) do
      :ok ->
        finalize_completion_effect(state, step_id)

      {:error, reason} ->
        error_text = "Failed to persist final generation state: #{inspect(reason)}"
        NotificationsDispatcher.notify_generation_finished(state.context.message_id, :error)
        broadcast(state, {:error, state.context.message_id, error_text})
        {:stop, :normal, %{state | status: :error}}
    end
  end

  defp finalize_completion_effect(state, step_id) when is_integer(step_id) do
    case safe_persist_value(state, :completion_effect, fn -> run_completion_effect(state) end) do
      {:ok, :ok} ->
        NotificationsDispatcher.notify_generation_finished(state.context.message_id, :done)
        broadcast(state, {:done, state.context.message_id})
        {:stop, :normal, %{state | status: :done}}

      {:ok, {:error, error_text}} ->
        _ =
          safe_persist(state, :completion_effect_error, fn ->
            Persistence.persist_error_from_step!(state.context.message_id, step_id, error_text)
          end)

        NotificationsDispatcher.notify_generation_finished(state.context.message_id, :error)
        broadcast(state, {:error, state.context.message_id, error_text})
        {:stop, :normal, %{state | status: :error}}

      {:error, reason} ->
        Logger.warning(
          "Skipped generation completion effect after losing its fence " <>
            "message_id=#{state.context.message_id} reason=#{inspect(reason)}"
        )

        {:stop, :normal, state}
    end
  end

  defp run_completion_effect(%{context: %{completion_effect: :manual_handoff}} = state) do
    actor = %User{id: state.context.owner_id}

    case Handoff.complete_manual_generation(state.context.message_id, actor) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to complete manual handoff: #{inspect(reason)}"}
    end
  end

  defp run_completion_effect(_state), do: :ok

  defp finalize_error(state, error_text) do
    finalize_error(state, error_text, %{})
  end

  defp finalize_error(state, error_text, meta) do
    runtime_step =
      state.runtime_step
      |> apply_trace_meta(meta)
      |> RuntimeTrace.apply_event({:set_step_response_final, false})
      |> RuntimeTrace.apply_event({:ensure_item, "error", :error, nil})
      |> RuntimeTrace.apply_event({:set_text, "error", :error, 1, to_string(error_text || "")})

    _ =
      safe_persist(state, :error, fn ->
        if durable_waiting_tools_step?(runtime_step) do
          Persistence.persist_error_from_step!(
            state.context.message_id,
            runtime_step.id,
            error_text
          )
        else
          Persistence.persist_error!(
            state.context.message_id,
            runtime_step,
            error_text
          )
        end
      end)

    NotificationsDispatcher.notify_generation_finished(state.context.message_id, :error)
    broadcast(state, {:error, state.context.message_id, error_text})
    {:stop, :normal, %{state | status: :error}}
  end

  defp durable_waiting_tools_step?(%RuntimeTrace.Step{id: step_id, status: status})
       when is_integer(step_id) do
    status == :waiting_tools
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

      case persist_retry_error_and_start_next_step(state, error_text, meta, attempt, delay_ms) do
        {:ok, state} ->
          state = cancel_stream_task(state)
          retry_token = make_ref()

          timer_ref =
            Process.send_after(self(), {:retry_current_step, retry_token}, delay_ms)

          {:retrying,
           %{
             state
             | retry_timer_ref: {timer_ref, retry_token},
               step_attempt: attempt + 1
           }}

        {:error, reason} ->
          Logger.warning(
            "generation step auto-retry persistence failed message_id=#{state.context.message_id} " <>
              "step_sequence=#{state.step_sequence} reason=#{inspect(reason)}"
          )

          :no_retry
      end
    else
      :no_retry
    end
  end

  defp persist_retry_error_and_start_next_step(state, error_text, meta, attempt, delay_ms) do
    raw_request = state.runtime_step.raw_request || %{}

    case safe_persist_value(state, :auto_retry, fn ->
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
             retryable: true
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

        context = %{state.context | step_id: retry_step.step_id}

        {:ok,
         %{
           state
           | context: context,
             runtime_step: runtime_step,
             step_sequence: retry_step.step_sequence
         }}

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

  defp cancel_tool_task(%{tool_task: task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    %{state | tool_task: nil}
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

  defp adopt_generation_lease(nil, _owner), do: :ok
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

  defp safe_persist(%__MODULE__{} = state, status, fun) when is_function(fun, 0) do
    message_id = state.context.message_id

    try do
      case fenced_call(state, fun) do
        {:ok, _result} ->
          :ok

        {:error, reason} = error ->
          if generation_fence_lost?(reason),
            do: exit({:generation_lease_lost, reason}),
            else: error
      end
    rescue
      exception ->
        Logger.warning(
          "Generation persistence failed (message_id=#{message_id}, status=#{status}): #{Exception.message(exception)}"
        )

        {:error, exception}
    catch
      :exit, {:generation_lease_lost, _reason} = reason ->
        exit(reason)

      :exit, reason ->
        Logger.warning(
          "Generation persistence exited (message_id=#{message_id}, status=#{status}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp safe_cancel_persist(%__MODULE__{} = state, fun) when is_function(fun, 0) do
    message_id = state.context.message_id

    try do
      case fenced_call(state, fun) do
        {:ok, _result} -> :ok
        {:error, _reason} = error -> error
      end
    rescue
      exception ->
        Logger.warning(
          "Generation cancellation persistence failed (message_id=#{message_id}): #{Exception.message(exception)}"
        )

        {:error, exception}
    catch
      :exit, reason ->
        Logger.warning(
          "Generation cancellation persistence exited (message_id=#{message_id}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp safe_persist_value(%__MODULE__{} = state, status, fun) when is_function(fun, 0) do
    message_id = state.context.message_id

    try do
      case fenced_call(state, fun) do
        {:error, reason} = error ->
          if generation_fence_lost?(reason),
            do: exit({:generation_lease_lost, reason}),
            else: error

        result ->
          result
      end
    rescue
      exception ->
        Logger.warning(
          "Generation persistence failed (message_id=#{message_id}, status=#{status}): #{Exception.message(exception)}"
        )

        {:error, exception}
    catch
      :exit, {:generation_lease_lost, _reason} = reason ->
        exit(reason)

      :exit, reason ->
        Logger.warning(
          "Generation persistence exited (message_id=#{message_id}, status=#{status}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp fenced_call(%__MODULE__{lease: %Lease{} = lease}, fun) when is_function(fun, 0) do
    Lease.with_fence(lease, fun)
  end

  defp fenced_call(%__MODULE__{lease: nil}, fun) when is_function(fun, 0) do
    {:ok, fun.()}
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
    handoff_available = handoff_tools_payload(state) != []

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
    name =
      case Map.get(payload, "function") do
        %{} = function -> Map.get(function, "name")
        _other -> Map.get(payload, "name")
      end

    handoff_tool_name?(state, name)
  end

  defp handoff_tool_payload?(_state, _payload), do: false

  defp handoff_tool_call?(state, call) do
    call
    |> tool_call_to_map()
    |> Map.get(:name)
    |> then(&handoff_tool_name?(state, &1))
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
      refusal_results = build_refusal_results(refused_calls, refusal)

      if handoff_calls == [] do
        handle_tool_results(state, refusal_results,
          tool_round_delta: 0,
          refusal_round_delta: 1
        )
      else
        state = start_tool_task(state, handoff_calls, refusal_results)
        {:noreply, state}
      end
    else
      results = build_refusal_results(tool_calls, refusal)

      handle_tool_results(state, results,
        tool_round_delta: 0,
        refusal_round_delta: 1
      )
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

  defp start_tool_task(state, tool_calls, prebuilt_results)
       when is_list(tool_calls) and is_list(prebuilt_results) do
    tool_instances_by_alias = state.context.tool_instances_by_alias || %{}
    execution_context = tool_execution_context(state)
    message_id = state.context.message_id
    step_id = state.runtime_step.id
    lease = state.lease

    task =
      Task.async(fn ->
        {:tool_results,
         execute_and_persist_tool_calls(
           message_id,
           step_id,
           tool_calls,
           tool_instances_by_alias,
           execution_context,
           lease
         )
         |> Kernel.++(prebuilt_results)
         |> order_tool_results()}
      end)

    %{state | tool_task: task}
  end

  defp execute_and_persist_tool_calls(
         message_id,
         step_id,
         tool_calls,
         tool_instances_by_alias,
         execution_context,
         lease
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
        execution_context = execution_context_for_tool_call(execution_context, call)

        result =
          Executor.execute_llm_tool(
            tool_instances_by_alias,
            call.name,
            call.args || %{},
            execution_context
          )

        result = decorate_tool_result(call, result)
        persist_tool_result!(lease, message_id, step_id, call, result)
        result
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

  defp persist_tool_result!(%Lease{} = lease, message_id, step_id, call, result) do
    case Lease.with_fence(lease, fn ->
           Persistence.persist_tool_result!(message_id, step_id, call, result)
         end) do
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
    case safe_persist_value(state, :tool_results, fn ->
           maybe_persist_tool_results(state, results, opts)
           Persistence.load_step_for_followup!(state.runtime_step.id)
         end) do
      {:ok, persisted} ->
        case handoff_payload(persisted.results) do
          %{} = payload ->
            finalize_handoff_tool_step(state, payload)

          nil ->
            with {:ok, followup} <- build_followup_with_steering(state, persisted),
                 {:ok, next_step} <-
                   safe_persist_value(state, :step_done, fn ->
                     Persistence.complete_step_and_start_next!(
                       state.context.message_id,
                       state.runtime_step.id,
                       state.step_sequence + 1,
                       followup.raw_request
                     )
                   end) do
              continue_after_tool_step(state, followup, next_step, opts)
            else
              {:error, reason} ->
                finalize_error(
                  state,
                  "Failed to prepare tool follow-up: #{inspect(reason)}",
                  %{}
                )
            end
        end

      {:error, reason} ->
        finalize_error(state, "Failed to persist tool results: #{inspect(reason)}", %{})
    end
  end

  defp maybe_persist_tool_results(state, results, opts) do
    if Keyword.get(opts, :persist_results?, true) == false do
      :ok
    else
      step_id = state.runtime_step.id

      Enum.each(results, fn result ->
        call = tool_call_from_result(result)

        if is_integer(step_id) and not is_nil(call) do
          Persistence.persist_tool_result!(state.context.message_id, step_id, call, result)
        end
      end)
    end
  end

  defp finalize_handoff_tool_step(state, _payload) do
    IntellectualClub.Notifications.suppress_generation_finished(state.context.message_id, :done)
    finalize_done_from_step(state, state.runtime_step.id)
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

      case Map.get(persisted, :steering_items, []) do
        [] ->
          {:ok, followup}

        steering_items ->
          inject_steering_request(state, followup.raw_request, steering_items)
      end
    rescue
      exception -> {:error, exception}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp continue_after_tool_step(next_state, followup, next_step, opts) do
    raw_request = followup.raw_request
    step_id = next_step.step_id
    next_sequence = next_state.step_sequence + 1

    runtime_step =
      RuntimeTrace.new_step(
        id: step_id,
        sequence: next_sequence,
        started_at: DateTime.utc_now(),
        status: :waiting_provider,
        raw_request: raw_request
      )

    state =
      next_state
      |> Map.put(:runtime_step, runtime_step)
      |> Map.put(:step_sequence, next_sequence)
      |> Map.put(:step_attempt, 1)
      |> Map.put(:tool_round, next_state.tool_round + Keyword.get(opts, :tool_round_delta, 1))
      |> Map.put(
        :refusal_round,
        next_state.refusal_round + Keyword.get(opts, :refusal_round_delta, 0)
      )
      |> Map.put(:retry_timer_ref, nil)
      |> Map.put(:stream_task, nil)

    {:noreply, start_stream_task(state)}
  end

  defp tool_execution_context(state) do
    %ExecutionContext{
      owner_id: Map.get(state.context, :owner_id),
      chat_id: Map.get(state.context, :chat_id),
      message_id: Map.get(state.context, :message_id),
      assistant_message_id: Map.get(state.context, :message_id),
      step_id: Map.get(state.runtime_step, :id) || Map.get(state.context, :step_id),
      provider_type: Map.get(state.context, :provider_type),
      available_file_external_ids: Map.get(state.context, :available_file_external_ids, []),
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
    media_contents =
      result.media
      |> Enum.with_index(2)
      |> Enum.flat_map(fn {media, idx} ->
        case normalize_media_content(media, idx) do
          nil -> []
          content -> [content]
        end
      end)

    artifact_contents =
      result.artifacts
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {artifact, idx} ->
        case normalize_media_content(artifact, idx) do
          nil -> []
          content -> [content]
        end
      end)

    call
    |> tool_call_to_map()
    |> Map.merge(%{
      text: result.text,
      result_raw: result.raw,
      media_contents: media_contents,
      artifact_contents: artifact_contents,
      raw: Map.get(tool_call_to_map(call), :raw, %{})
    })
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

  defp normalize_media_content(media, sequence) when is_map(media) and is_integer(sequence) do
    file_id = Map.get(media, :file_id)
    filename = Map.get(media, :filename)
    mime_type = Map.get(media, :mime_type)
    size_bytes = Map.get(media, :size_bytes)
    sha256 = Map.get(media, :sha256)
    file_external_id = Map.get(media, :file_external_id)

    if is_integer(file_id) and is_binary(filename) and is_binary(mime_type) and is_binary(sha256) do
      %{
        external_id: Ash.UUID.generate(),
        sequence: sequence,
        kind: :media,
        file_id: file_id,
        file: %{
          id: file_id,
          external_id: file_external_id,
          filename: filename,
          mime_type: mime_type,
          size_bytes: size_bytes || 0,
          sha256: sha256
        }
      }
    else
      nil
    end
  end

  defp normalize_media_content(_media, _sequence), do: nil

  defp provider_error_value?(nil), do: false
  defp provider_error_value?(false), do: false
  defp provider_error_value?(""), do: false
  defp provider_error_value?(%{}), do: true
  defp provider_error_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp provider_error_value?(_other), do: true

  defp apply_trace_meta(%RuntimeTrace.Step{} = runtime_step, meta) when is_map(meta) do
    runtime_step
    |> maybe_apply_raw_request(meta)
    |> maybe_apply_raw_response(meta)
    |> maybe_apply_usage(meta)
  end

  defp apply_trace_meta(%RuntimeTrace.Step{} = runtime_step, _meta), do: runtime_step

  defp maybe_apply_raw_request(runtime_step, meta) do
    raw_request = Map.get(meta, :raw_request)

    if is_map(raw_request) do
      RuntimeTrace.apply_event(runtime_step, {:set_step_raw_request, raw_request})
    else
      runtime_step
    end
  end

  defp maybe_apply_raw_response(runtime_step, meta) do
    raw_response = Map.get(meta, :raw_response)

    if is_map(raw_response) do
      RuntimeTrace.apply_event(runtime_step, {:set_step_raw_response, raw_response})
    else
      runtime_step
    end
  end

  defp maybe_apply_usage(runtime_step, meta) do
    usage = Map.get(meta, :usage)

    if is_map(usage) do
      RuntimeTrace.apply_event(runtime_step, {:set_step_usage, usage})
    else
      runtime_step
    end
  end
end
