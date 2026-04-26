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
  alias IntellectualClub.Generation.ProviderAdapterResolver
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult

  @default_auto_retry_backoff_ms [500, 1_500, 5_000, 5_000, 5_000, 5_000, 5_000]
  @default_auto_retry_jitter_ratio 0.2
  @auto_retry_http_status_codes MapSet.new([429, 502])
  @auto_retry_error_kinds MapSet.new(["network", "timeout", "transport"])
  @max_refusal_rounds 3

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
    :tools_disabled
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
        ProviderAdapterResolver.for_provider_type(Map.get(context, :provider_type))

    initial_step_sequence =
      case Map.get(context, :initial_step_sequence) do
        value when is_integer(value) and value > 0 -> value
        _other -> 1
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
      runtime_step:
        RuntimeTrace.new_step(
          id: context.step_id,
          sequence: initial_step_sequence,
          started_at: started_at,
          status: :waiting_provider,
          raw_request: context.request_payload || %{}
        ),
      stream_task: nil,
      retry_timer_ref: nil
    }

    {:ok, state, {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    state = start_stream_task(state)
    {:noreply, state}
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
      tool_calls = tool_calls_from_runtime_step(runtime_step)

      if tool_calls == [] do
        finalize_done(state)
      else
        max_tool_rounds = max_tool_rounds(state)

        {context_limit_reached, total_tokens, length, soft_limit} =
          context_soft_limit_reached(state)

        cond do
          can_execute_tools?(state, max_tool_rounds, context_limit_reached) ->
            runtime_step = %{state.runtime_step | status: :waiting_tools}
            state = %{state | runtime_step: runtime_step}

            _ =
              safe_persist(state.context.message_id, :waiting_tools, fn ->
                Persistence.persist_step_waiting_tools!(state.context.message_id, runtime_step)
              end)

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

            soft_refuse_tool_calls(state, tool_calls, refusal)
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

  defp finalize_done(state) do
    runtime_step = state.runtime_step

    case safe_persist(state.context.message_id, :done, fn ->
           Persistence.persist_completed!(state.context.message_id, runtime_step)
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
        Persistence.persist_error!(
          state.context.message_id,
          runtime_step,
          error_text
        )
      end)

    broadcast(state, {:error, state.context.message_id, error_text})
    {:stop, :normal, %{state | status: :error}}
  end

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
    if state.tools_disabled do
      []
    else
      state.context.tools_payload || []
    end
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
      %{
        call_id: call.call_id,
        name: call.name,
        raw: call.raw,
        text: refusal_text,
        result_raw: refusal_raw,
        media_contents: [],
        artifact_contents: []
      }
    end)
  end

  defp soft_refuse_tool_calls(state, tool_calls, refusal)
       when is_list(tool_calls) and is_map(refusal) do
    results = build_refusal_results(tool_calls, refusal)

    handle_tool_results(state, results,
      tool_round_delta: 0,
      refusal_round_delta: 1,
      disable_tools: true
    )
  end

  defp finalize_tool_loop_exhausted(state, max_tool_rounds) when is_integer(max_tool_rounds) do
    error_text =
      "Tool calling did not converge to a final answer. " <>
        "Executed tool rounds: #{state.tool_round}/#{max_tool_rounds}. " <>
        "Refused tool rounds: #{state.refusal_round}/#{@max_refusal_rounds}."

    finalize_error(state, error_text, %{})
  end

  defp tool_calls_from_runtime_step(%RuntimeTrace.Step{} = runtime_step) do
    runtime_step.items_by_key
    |> Map.values()
    |> Enum.filter(&match?(%RuntimeTrace.Item{type: :tool_call}, &1))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(&tool_call_from_runtime_item/1)
  end

  defp tool_calls_from_runtime_step(_other), do: []

  defp tool_call_from_runtime_item(%RuntimeTrace.Item{} = item) do
    opaque = latest_opaque_content(item)
    raw = tool_call_raw_from_opaque(opaque)

    call_id =
      [
        Map.get(opaque, "tool_call_id"),
        Map.get(opaque, "call_id"),
        Map.get(raw, "call_id"),
        Map.get(raw, "id"),
        tool_call_id_from_item_key(item.key)
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

    args_value =
      Map.get(raw, "arguments") ||
        get_in(raw, ["function", "arguments"]) ||
        Map.get(opaque, "arguments")

    args = parse_tool_args(args_value)

    if call_id != "" and name != "" do
      [
        %{
          call_id: call_id,
          name: name,
          args: args,
          raw: ensure_tool_call_raw(raw, call_id, name, args_value, args)
        }
      ]
    else
      []
    end
  end

  defp tool_call_from_runtime_item(_other), do: []

  defp parse_tool_args(%{} = args), do: args

  defp parse_tool_args(args) when is_binary(args) do
    text = String.trim(args)

    if text == "" do
      %{}
    else
      case Jason.decode(text) do
        {:ok, %{} = obj} -> obj
        _ -> %{}
      end
    end
  end

  defp parse_tool_args(_other), do: %{}

  defp latest_opaque_content(%RuntimeTrace.Item{} = item) do
    item.contents_by_sequence
    |> Map.values()
    |> Enum.sort_by(& &1.sequence, :desc)
    |> Enum.find_value(%{}, fn
      %{kind: :opaque, content_json: %{} = json} -> normalize_tool_call_map(json)
      _other -> nil
    end)
  end

  defp latest_opaque_content(_other), do: %{}

  defp tool_call_raw_from_opaque(%{} = opaque) do
    opaque
    |> Map.get("raw")
    |> case do
      %{} = raw ->
        normalize_tool_call_map(raw)

      _other ->
        opaque
        |> Map.get("responses_item")
        |> case do
          %{} = raw -> normalize_tool_call_map(raw)
          _ -> normalize_tool_call_map(opaque)
        end
    end
  end

  defp tool_call_raw_from_opaque(_other), do: %{}

  defp tool_call_id_from_item_key("tc:" <> call_id), do: call_id
  defp tool_call_id_from_item_key(_other), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_other), do: false

  defp ensure_tool_call_raw(raw, call_id, name, args_value, args)
       when is_binary(call_id) and is_binary(name) do
    raw = normalize_tool_call_map(raw)
    arguments = tool_call_arguments_text(args_value, args)

    cond do
      is_map(Map.get(raw, "function")) or Map.get(raw, "type") == "function" ->
        function =
          raw
          |> Map.get("function", %{})
          |> normalize_tool_call_map()
          |> Map.put("name", name)
          |> Map.put("arguments", arguments)

        raw
        |> Map.put("id", call_id)
        |> Map.put("type", "function")
        |> Map.put("function", function)

      present_string?(Map.get(raw, "call_id")) or present_string?(Map.get(raw, "name")) or
          Map.get(raw, "type") == "function_call" ->
        raw
        |> Map.put("id", Map.get(raw, "id") || call_id)
        |> Map.put("type", "function_call")
        |> Map.put("call_id", call_id)
        |> Map.put("name", name)
        |> Map.put("arguments", arguments)

      true ->
        %{
          "id" => call_id,
          "type" => "function_call",
          "call_id" => call_id,
          "name" => name,
          "arguments" => arguments
        }
    end
  end

  defp ensure_tool_call_raw(_raw, call_id, name, args_value, args) do
    ensure_tool_call_raw(%{}, call_id, name, args_value, args)
  end

  defp tool_call_arguments_text(value, %{} = args) do
    cond do
      is_binary(value) and String.trim(value) != "" ->
        value

      is_map(value) and map_size(value) > 0 ->
        Jason.encode!(value)

      map_size(args) > 0 ->
        Jason.encode!(args)

      true ->
        "{}"
    end
  end

  defp tool_call_arguments_text(value, _args) when is_binary(value) do
    if String.trim(value) != "" do
      value
    else
      "{}"
    end
  end

  defp tool_call_arguments_text(%{} = value, _args), do: Jason.encode!(value)
  defp tool_call_arguments_text(_value, _args), do: "{}"

  defp normalize_tool_call_map(%{} = value) do
    Map.new(value, fn {key, nested} ->
      {to_string(key), normalize_tool_call_value(nested)}
    end)
  end

  defp normalize_tool_call_map(_other), do: %{}

  defp normalize_tool_call_value(%{} = value), do: normalize_tool_call_map(value)

  defp normalize_tool_call_value(list) when is_list(list),
    do: Enum.map(list, &normalize_tool_call_value/1)

  defp normalize_tool_call_value(value), do: value

  defp start_tool_task(state, tool_calls) when is_list(tool_calls) do
    tool_instances_by_alias = state.context.tool_instances_by_alias || %{}
    execution_context = tool_execution_context(state)

    task =
      Task.async(fn ->
        results =
          Enum.map(tool_calls, fn call ->
            result =
              Executor.execute_llm_tool(
                tool_instances_by_alias,
                call.name,
                call.args || %{},
                execution_context
              )

            decorate_tool_result(call, result)
          end)

        {:tool_results, results}
      end)

    %{state | tool_task: task}
  end

  defp handle_tool_results(state, results) when is_list(results) do
    handle_tool_results(state, results, [])
  end

  defp handle_tool_results(state, results, opts) when is_list(results) and is_list(opts) do
    tools_disabled = state.tools_disabled or Keyword.get(opts, :disable_tools, false)
    next_state = %{state | tools_disabled: tools_disabled}

    followup =
      state.adapter.build_followup_request(%{
        context: next_state.context,
        runtime_step: state.runtime_step,
        results: results,
        tools: current_tools_payload(next_state)
      })

    runtime_step = followup.runtime_step

    case safe_persist(state.context.message_id, :step_done, fn ->
           Persistence.persist_step_trace_only!(state.context.message_id, runtime_step)
         end) do
      :ok ->
        {raw_request, step_id} = start_next_step_metadata(next_state, followup.raw_request)

        runtime_step =
          RuntimeTrace.new_step(
            id: step_id,
            sequence: state.step_sequence + 1,
            started_at: DateTime.utc_now(),
            status: :waiting_provider,
            raw_request: raw_request
          )

        state =
          state
          |> Map.put(:runtime_step, runtime_step)
          |> Map.put(:step_sequence, state.step_sequence + 1)
          |> Map.put(:step_attempt, 1)
          |> Map.put(:tool_round, state.tool_round + Keyword.get(opts, :tool_round_delta, 1))
          |> Map.put(
            :refusal_round,
            state.refusal_round + Keyword.get(opts, :refusal_round_delta, 0)
          )
          |> Map.put(:tools_disabled, tools_disabled)
          |> Map.put(:retry_timer_ref, nil)
          |> Map.put(:stream_task, nil)

        state = start_stream_task(state)
        {:noreply, state}

      {:error, reason} ->
        finalize_error(state, "Failed to persist tool step: #{inspect(reason)}", %{})
    end
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
      provider_type: Map.get(state.context, :provider_type)
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

    Map.merge(call, %{
      text: result.text,
      result_raw: result.raw,
      media_contents: media_contents,
      artifact_contents: artifact_contents,
      raw: call.raw
    })
  end

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
