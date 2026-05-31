defmodule IntellectualClub.Generation.Worker do
  @moduledoc """
  Per-message generation worker.

  It accumulates a canonical runtime trace in memory, broadcasts lightweight
  update signals via PubSub, persists completed steps to the database, and
  finalizes the message when generation finishes.
  """

  use GenServer

  require Logger

  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.Common.Registry, as: ProviderRegistry
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult

  @default_auto_retry_backoff_ms [500, 1_500, 5_000, 5_000, 5_000, 5_000, 5_000]
  @default_auto_retry_jitter_ratio 0.2
  @auto_retry_http_status_codes MapSet.new([429, 502, 503])
  @auto_retry_error_kinds MapSet.new(["network", "timeout", "transport"])
  @max_refusal_rounds 3
  @max_parallel_tool_calls 8

  defstruct [
    :context,
    :adapter,
    :status,
    :runtime_step,
    :stream_task,
    :tool_task,
    :retry_timer_ref,
    :step_attempt,
    :step_sequence,
    :tool_round,
    :refusal_round,
    :tools_disabled,
    :tools_limited_to_handoff
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
  def init(%{context: context}) do
    Registry.register(IntellectualClub.Generation.Registry, {:message, context.message_id}, %{
      chat_id: context.chat_id
    })

    Registry.register(IntellectualClub.Generation.Registry, {:chat, context.chat_id}, %{
      message_id: context.message_id
    })

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
      case {Map.get(context, :initial_step_status), context.step_id} do
        {:waiting_tools, step_id} when is_integer(step_id) ->
          followup = Persistence.load_step_for_followup!(step_id)
          {followup.runtime_step, :resume_waiting_tools}

        {"waiting_tools", step_id} when is_integer(step_id) ->
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
      adapter: adapter,
      status: :generating,
      step_attempt: 1,
      step_sequence: initial_step_sequence,
      tool_round: 0,
      refusal_round: 0,
      tools_disabled: false,
      tools_limited_to_handoff: false,
      runtime_step: runtime_step,
      stream_task: nil,
      retry_timer_ref: nil
    }

    {:ok, state, {:continue, continue}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    state = start_stream_task(state)
    {:noreply, state}
  end

  def handle_continue(:resume_waiting_tools, state) do
    case safe_persist_value(state.context.message_id, :resume_waiting_tools, fn ->
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

  defp start_stream_task(state) do
    me = self()

    task =
      Task.async(fn ->
        emit = fn event -> send(me, {:provider_event, event}) end

        state.adapter.stream_generate(
          %{
            context: state.context,
            request_payload: state.runtime_step.raw_request,
            timeout_ms: state.context.timeout_ms || 300_000,
            chunk_delay_ms: state.context.chunk_delay_ms
          },
          emit
        )
      end)

    %{state | stream_task: task, retry_timer_ref: nil}
  end

  @impl true
  def handle_info({:provider_event, {:trace, trace_event}}, state) do
    runtime_step = RuntimeTrace.apply_event(state.runtime_step, trace_event)
    maybe_broadcast_text_delta(state, trace_event)
    {:noreply, %{state | runtime_step: runtime_step}}
  end

  @impl true
  def handle_info({:provider_event, {:response_complete, meta}}, state) do
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
      case safe_persist_value(state.context.message_id, :provider_completed, fn ->
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
  def handle_info({:provider_event, {:response_error, meta}}, state) do
    error_text =
      Map.get(meta, :error_text) || Map.get(meta, "error_text") || "Provider error"

    case maybe_retry_current_step(state, meta) do
      {:retrying, state} ->
        {:noreply, state}

      :no_retry ->
        finalize_error(state, error_text, meta)
    end
  end

  @impl true
  def handle_info(:retry_current_step, state) do
    state = start_stream_task(%{state | retry_timer_ref: nil})
    {:noreply, state}
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

    {context_limit_reached, total_tokens, length, soft_limit} =
      context_soft_limit_reached(state)

    cond do
      can_execute_tools?(state, max_tool_rounds, context_limit_reached) ->
        runtime_step = %{state.runtime_step | status: :waiting_tools}
        state = %{state | runtime_step: runtime_step}

        state = start_tool_task(state, tool_calls)

        {:noreply, state}

      state.refusal_round + 1 > @max_refusal_rounds ->
        finalize_tool_loop_exhausted(state, max_tool_rounds)

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
    state = cancel_tasks(state)

    _ =
      safe_persist(state.context.message_id, :canceled, fn ->
        Persistence.persist_canceled!(state.context.message_id, state.runtime_step)
      end)

    broadcast(state, {:canceled, state.context.message_id})
    {:stop, :normal, %{state | status: :canceled}}
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

  defp finalize_done_from_step(state, step_id) when is_integer(step_id) do
    case safe_persist(state.context.message_id, :done, fn ->
           Persistence.persist_completed_from_step!(state.context.message_id, step_id)
         end) do
      :ok ->
        broadcast(state, {:done, state.context.message_id})
        {:stop, :normal, %{state | status: :done}}

      {:error, reason} ->
        error_text = "Failed to persist final generation state: #{inspect(reason)}"
        broadcast(state, {:error, state.context.message_id, error_text})
        {:stop, :normal, %{state | status: :error}}
    end
  end

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
      safe_persist(state.context.message_id, :error, fn ->
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

    broadcast(state, {:error, state.context.message_id, error_text})
    {:stop, :normal, %{state | status: :error}}
  end

  defp durable_waiting_tools_step?(%RuntimeTrace.Step{id: step_id, status: status})
       when is_integer(step_id) do
    status in [:waiting_tools, "waiting_tools"]
  end

  defp durable_waiting_tools_step?(_runtime_step), do: false

  defp maybe_retry_current_step(state, meta) when is_map(meta) do
    max_retries = auto_retry_max_retries()

    if retryable_provider_error?(meta) and state.step_attempt <= max_retries do
      attempt = state.step_attempt
      delay_ms = backoff_delay_ms(attempt)
      status_code = status_code_from_meta(meta)
      step_id = state.runtime_step.id

      Logger.warning(
        "generation step auto-retry message_id=#{state.context.message_id} " <>
          "step_id=#{inspect(step_id)} attempt=#{attempt} max_retries=#{max_retries} " <>
          "status_code=#{inspect(status_code)} delay_ms=#{delay_ms}"
      )

      case rollback_and_restart_current_step(state) do
        {:ok, state} ->
          timer_ref = Process.send_after(self(), :retry_current_step, delay_ms)

          {:retrying,
           %{state | stream_task: nil, retry_timer_ref: timer_ref, step_attempt: attempt + 1}}

        {:error, reason} ->
          Logger.warning(
            "generation step auto-retry rollback failed message_id=#{state.context.message_id} " <>
              "step_sequence=#{state.step_sequence} reason=#{inspect(reason)}"
          )

          :no_retry
      end
    else
      :no_retry
    end
  end

  defp maybe_retry_current_step(_state, _meta), do: :no_retry

  defp rollback_and_restart_current_step(state) do
    try do
      :ok =
        Persistence.rollback_last_step_for_retry!(state.context.message_id, state.step_sequence)

      started_at = DateTime.utc_now()
      raw_request = state.runtime_step.raw_request || %{}

      step_id =
        Persistence.ensure_step_started!(
          state.context.message_id,
          state.step_sequence,
          raw_request,
          started_at: started_at
        )

      runtime_step =
        RuntimeTrace.new_step(
          id: step_id,
          sequence: state.step_sequence,
          started_at: started_at,
          status: :waiting_provider,
          raw_request: raw_request
        )

      {:ok, %{state | runtime_step: runtime_step}}
    rescue
      exception ->
        {:error, exception}
    catch
      :exit, reason ->
        {:error, reason}
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

  defp retryable_provider_error?(_meta), do: false

  defp auto_retry_max_retries do
    configured = Application.get_env(:intellectual_club, :generation_auto_retry_max_retries)

    cond do
      is_integer(configured) and configured >= 0 ->
        configured

      true ->
        auto_retry_backoff_values() |> length()
    end
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
    value = Map.get(meta, :status_code) || Map.get(meta, "status_code")
    parse_int(value)
  end

  defp status_code_from_meta(_meta), do: nil

  defp bool_value(meta, key) when is_map(meta) and is_atom(key) do
    value = Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
    value in [true, "true", 1]
  end

  defp bool_value(_meta, _key), do: false

  defp string_value(meta, key) when is_map(meta) and is_atom(key) do
    value = Map.get(meta, key) || Map.get(meta, Atom.to_string(key))

    case value do
      nil -> ""
      _ -> value |> to_string() |> String.trim() |> String.downcase()
    end
  end

  defp string_value(_meta, _key), do: ""

  defp provider_error_text(error) when is_map(error) do
    message = trimmed_string(Map.get(error, "message") || Map.get(error, :message))
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
    metadata = Map.get(error, "metadata") || Map.get(error, :metadata)

    case metadata do
      %{} ->
        trimmed_string(Map.get(metadata, "raw") || Map.get(metadata, :raw))

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

  defp cancel_retry_timer(%{retry_timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | retry_timer_ref: nil}
  end

  defp cancel_stream_task(%{stream_task: nil} = state), do: state

  defp cancel_stream_task(%{stream_task: task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    %{state | stream_task: nil}
  end

  defp cancel_tool_task(%{tool_task: nil} = state), do: state

  defp cancel_tool_task(%{tool_task: task} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    %{state | tool_task: nil}
  end

  defp safe_persist(message_id, status, fun)
       when is_integer(message_id) and is_function(fun, 0) do
    try do
      fun.()
      :ok
    rescue
      exception ->
        Logger.warning(
          "Generation persistence failed (message_id=#{message_id}, status=#{status}): #{Exception.message(exception)}"
        )

        {:error, exception}
    catch
      :exit, reason ->
        Logger.warning(
          "Generation persistence exited (message_id=#{message_id}, status=#{status}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp safe_persist_value(message_id, status, fun)
       when is_integer(message_id) and is_function(fun, 0) do
    try do
      {:ok, fun.()}
    rescue
      exception ->
        Logger.warning(
          "Generation persistence failed (message_id=#{message_id}, status=#{status}): #{Exception.message(exception)}"
        )

        {:error, exception}
    catch
      :exit, reason ->
        Logger.warning(
          "Generation persistence exited (message_id=#{message_id}, status=#{status}): #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(IntellectualClub.PubSub, "chat:#{state.context.chat_id}", message)
  end

  defp maybe_broadcast_text_delta(state, {:append_text, _item_key, :answer, _seq, delta}) do
    broadcast(state, {:content_delta, state.context.message_id, delta})
  end

  defp maybe_broadcast_text_delta(state, {:append_text, _item_key, :reasoning, _seq, delta}) do
    broadcast(state, {:reasoning_delta, state.context.message_id, delta})
  end

  defp maybe_broadcast_text_delta(_state, _event), do: :ok

  defp current_tools_payload(state) do
    cond do
      state.tools_disabled ->
        []

      state.tools_limited_to_handoff ->
        handoff_tools_payload(state)

      true ->
        state.context.tools_payload || []
    end
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
    not state.tools_disabled and state.tool_round < max_tool_rounds and not context_limit_reached
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
    %{
      text:
        "[tool error] Context limit reached (#{total_tokens}/#{length} > #{soft_limit}). " <>
          "Please proceed to the final answer using the information already available.",
      raw: %{
        "error" => "context_limit_reached",
        "context_length" => length,
        "context_soft_limit" => soft_limit,
        "context_soft_limit_percent" => state.context.context_soft_limit_percent,
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
    refusal_text = Map.get(refusal, :text) || Map.get(refusal, "text") || ""
    refusal_raw = Map.get(refusal, :raw) || Map.get(refusal, "raw") || %{}

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
      case map_get(payload, "function") do
        %{} = function -> map_get(function, "name")
        _other -> map_get(payload, "name")
      end

    handoff_tool_name?(state, name)
  end

  defp handoff_tool_payload?(_state, _payload), do: false

  defp handoff_tool_call?(state, call) do
    call
    |> tool_call_to_map()
    |> map_get("name")
    |> then(&handoff_tool_name?(state, &1))
  end

  defp handoff_tool_name?(state, name) when is_binary(name) do
    with {alias_value, "handoff"} <- split_tool_name(name),
         %{} = tool_instance <- Map.get(state.context.tool_instances_by_alias || %{}, alias_value),
         "native-agent-management" <- tool_instance_type(tool_instance) do
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

  defp tool_instance_type(tool_instance) when is_map(tool_instance) do
    tool_instance
    |> map_get("type")
    |> to_string()
    |> String.trim()
  end

  defp tool_instance_type(_tool_instance), do: ""

  defp soft_refuse_tool_calls(state, tool_calls, refusal, opts)
       when is_list(tool_calls) and is_map(refusal) and is_list(opts) do
    if Keyword.get(opts, :allow_handoff?, false) do
      {handoff_calls, refused_calls} = Enum.split_with(tool_calls, &handoff_tool_call?(state, &1))
      refusal_results = build_refusal_results(refused_calls, refusal)

      if handoff_calls == [] do
        handle_tool_results(state, refusal_results,
          tool_round_delta: 0,
          refusal_round_delta: 1,
          handoff_only_tools?: true
        )
      else
        state = start_tool_task(state, handoff_calls, refusal_results)
        {:noreply, state}
      end
    else
      results = build_refusal_results(tool_calls, refusal)

      handle_tool_results(state, results,
        tool_round_delta: 0,
        refusal_round_delta: 1,
        disable_tools: true
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

    task =
      Task.async(fn ->
        {:tool_results,
         execute_and_persist_tool_calls(
           message_id,
           step_id,
           tool_calls,
           tool_instances_by_alias,
           execution_context
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
         execution_context
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
        result =
          Executor.execute_llm_tool(
            tool_instances_by_alias,
            call.name,
            call.args || %{},
            execution_context
          )

        result = decorate_tool_result(call, result)
        Persistence.persist_tool_result!(message_id, step_id, call, result)
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

  defp order_tool_results(results) when is_list(results) do
    Enum.sort_by(results, fn result ->
      map = tool_call_to_map(result)
      sequence = map_get(map, "sequence")
      name = map_get(map, "name") || ""
      {if(is_integer(sequence), do: sequence, else: 0), to_string(name)}
    end)
  end

  defp handle_tool_results(state, results) when is_list(results) do
    handle_tool_results(state, results, [])
  end

  defp handle_tool_results(state, results, opts) when is_list(results) and is_list(opts) do
    tools_disabled = state.tools_disabled or Keyword.get(opts, :disable_tools, false)

    tools_limited_to_handoff =
      not tools_disabled and
        (state.tools_limited_to_handoff or Keyword.get(opts, :handoff_only_tools?, false))

    next_state = %{
      state
      | tools_disabled: tools_disabled,
        tools_limited_to_handoff: tools_limited_to_handoff
    }

    case safe_persist_value(state.context.message_id, :tool_results, fn ->
           maybe_persist_tool_results(state, results, opts)
           Persistence.load_step_for_followup!(state.runtime_step.id)
         end) do
      {:ok, persisted} ->
        case handoff_payload(persisted.results) do
          %{} = payload ->
            finalize_handoff_tool_step(next_state, payload)

          nil ->
            followup =
              state.adapter.build_followup_request(%{
                context: next_state.context,
                runtime_step: persisted.runtime_step,
                results: persisted.results,
                tools: current_tools_payload(next_state)
              })

            case safe_persist(state.context.message_id, :step_done, fn ->
                   Persistence.mark_step_done!(state.runtime_step.id)
                 end) do
              :ok ->
                continue_after_tool_step(next_state, followup, opts)

              {:error, reason} ->
                finalize_error(state, "Failed to mark tool step done: #{inspect(reason)}", %{})
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

  defp finalize_handoff_tool_step(state, payload) when is_map(payload) do
    case safe_persist(state.context.message_id, :handoff_done, fn ->
           Persistence.mark_step_done!(state.runtime_step.id)

           runtime_step =
             state
             |> synthetic_handoff_runtime_step(payload)
             |> RuntimeTrace.apply_event({:set_step_response_final, true})

           Persistence.persist_completed!(state.context.message_id, runtime_step)
         end) do
      :ok ->
        broadcast(state, {:done, state.context.message_id})
        {:stop, :normal, %{state | status: :done}}

      {:error, reason} ->
        finalize_error(state, "Failed to finalize handoff: #{inspect(reason)}", %{})
    end
  end

  defp synthetic_handoff_runtime_step(state, payload) when is_map(payload) do
    chat_id = map_get(payload, "chat_id")
    url = map_get(payload, "url") || if(is_integer(chat_id), do: "/chats/#{chat_id}", else: nil)
    label = if(is_integer(chat_id), do: "chat ##{chat_id}", else: "a new chat")

    text =
      if is_binary(url) and url != "" do
        "Generation continued in [#{label}](#{url})."
      else
        "Generation continued in #{label}."
      end

    RuntimeTrace.new_step(
      sequence: state.step_sequence + 1,
      started_at: DateTime.utc_now(),
      status: :done,
      raw_request: %{"synthetic" => "handoff", "handoff" => payload},
      raw_response: %{"synthetic" => "handoff", "handoff" => payload},
      response_final: true
    )
    |> RuntimeTrace.apply_event({:ensure_item, "handoff", :answer, 1})
    |> RuntimeTrace.apply_event({:set_text, "handoff", :answer, 1, text})
  end

  defp handoff_payload(results) when is_list(results) do
    Enum.find_value(results, fn result ->
      raw =
        result
        |> tool_call_to_map()
        |> Map.get(:result_raw, Map.get(result, "result_raw", %{}))

      handoff_payload_from_raw(raw)
    end)
  end

  defp handoff_payload(_results), do: nil

  defp handoff_payload_from_raw(%{"handoff" => %{} = payload}), do: payload
  defp handoff_payload_from_raw(%{handoff: %{} = payload}), do: payload
  defp handoff_payload_from_raw(_raw), do: nil

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp map_get(_map, _key), do: nil

  defp continue_after_tool_step(next_state, followup, opts) do
    {raw_request, step_id} = start_next_step_metadata(next_state, followup.raw_request)
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

  defp start_next_step_metadata(state, raw_request)
       when is_map(state) and is_map(raw_request) do
    next_sequence = state.step_sequence + 1
    now = DateTime.utc_now()

    step_id =
      Persistence.ensure_step_started!(state.context.message_id, next_sequence, raw_request,
        started_at: now
      )

    {raw_request, step_id}
  end

  defp tool_execution_context(state) do
    %ExecutionContext{
      owner_id: Map.get(state.context, :owner_id),
      chat_id: Map.get(state.context, :chat_id),
      message_id: Map.get(state.context, :message_id),
      assistant_message_id: Map.get(state.context, :message_id),
      provider_type: Map.get(state.context, :provider_type),
      available_file_external_ids: Map.get(state.context, :available_file_external_ids, [])
    }
  end

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
    file_id = Map.get(media, :file_id, Map.get(media, "file_id"))
    filename = Map.get(media, :filename, Map.get(media, "filename"))
    mime_type = Map.get(media, :mime_type, Map.get(media, "mime_type"))
    size_bytes = Map.get(media, :size_bytes, Map.get(media, "size_bytes"))
    sha256 = Map.get(media, :sha256, Map.get(media, "sha256"))
    file_external_id = Map.get(media, :file_external_id, Map.get(media, "file_external_id"))

    if is_integer(file_id) and is_binary(filename) and is_binary(mime_type) and is_binary(sha256) do
      %{
        external_id: Ash.UUID.generate(),
        sequence: sequence,
        kind: :media,
        file_id: file_id,
        file: %{
          "id" => file_id,
          "external_id" => file_external_id,
          "filename" => filename,
          "mime_type" => mime_type,
          "size_bytes" => size_bytes || 0,
          "sha256" => sha256
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
    raw_request = Map.get(meta, :raw_request) || Map.get(meta, "raw_request")

    if is_map(raw_request) do
      RuntimeTrace.apply_event(runtime_step, {:set_step_raw_request, raw_request})
    else
      runtime_step
    end
  end

  defp maybe_apply_raw_response(runtime_step, meta) do
    raw_response = Map.get(meta, :raw_response) || Map.get(meta, "raw_response")

    if is_map(raw_response) do
      RuntimeTrace.apply_event(runtime_step, {:set_step_raw_response, raw_response})
    else
      runtime_step
    end
  end

  defp maybe_apply_usage(runtime_step, meta) do
    usage = Map.get(meta, :usage) || Map.get(meta, "usage")

    if is_map(usage) do
      RuntimeTrace.apply_event(runtime_step, {:set_step_usage, usage})
    else
      runtime_step
    end
  end
end
