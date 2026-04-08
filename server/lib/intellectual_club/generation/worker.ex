defmodule IntellectualClub.Generation.Worker do
  @moduledoc """
  Per-message generation worker.

  It accumulates a canonical runtime trace in memory, broadcasts lightweight
  update signals via PubSub, persists completed steps to the database, and
  finalizes the message when generation finishes.
  """

  use GenServer

  require Logger

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Generation.CacheControl
  alias IntellectualClub.Generation.ProviderStream
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RequestBuilder
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult

  @auto_retry_max_retries 2
  @auto_retry_backoff_ms [500, 1_500]
  @auto_retry_http_status_codes MapSet.new([429, 502])
  @auto_retry_error_kinds MapSet.new(["network", "timeout", "transport"])
  @max_refusal_rounds 3

  defstruct [
    :context,
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
    :messages_for_model,
    :responses_input_items,
    :current_run_cache_marker_index
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

    {messages_for_model, responses_input_items} = initial_provider_state(context)

    initial_step_sequence =
      case Map.get(context, :initial_step_sequence) do
        value when is_integer(value) and value > 0 -> value
        _other -> 1
      end

    state = %__MODULE__{
      context: context,
      status: :generating,
      step_attempt: 1,
      step_sequence: initial_step_sequence,
      tool_round: 0,
      refusal_round: 0,
      tools_disabled: false,
      messages_for_model: messages_for_model,
      responses_input_items: responses_input_items,
      current_run_cache_marker_index: nil,
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

        ProviderStream.stream_generate(
          %{
            provider_id: state.context.provider_id,
            provider_type: state.context.provider_type,
            provider_base_url: state.context.provider_base_url,
            provider_api_key: state.context.provider_api_key,
            provider_auth_method: state.context.provider_auth_method,
            provider_oauth_refresh_token: state.context.provider_oauth_refresh_token,
            model_name: state.context.model_name,
            parameters: state.context.parameters || %{},
            messages: provider_messages(state),
            request_payload: state.runtime_step.raw_request,
            tools: current_tools_payload(state),
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

      error_text =
        cond do
          is_map(error) and is_binary(Map.get(error, "message")) and
              Map.get(error, "message") != "" ->
            Map.get(error, "message")

          is_map(error) ->
            "Provider returned error"

          true ->
            "Provider returned error"
        end

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
    if retryable_provider_error?(meta) and state.step_attempt <= @auto_retry_max_retries do
      attempt = state.step_attempt
      delay_ms = backoff_delay_ms(attempt)
      status_code = status_code_from_meta(meta)
      step_id = state.runtime_step.id

      Logger.warning(
        "generation step auto-retry message_id=#{state.context.message_id} " <>
          "step_id=#{inspect(step_id)} attempt=#{attempt} max_retries=#{@auto_retry_max_retries} " <>
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

  defp backoff_delay_ms(attempt) when is_integer(attempt) and attempt > 0 do
    case @auto_retry_backoff_ms do
      [] ->
        0

      values ->
        idx = min(attempt - 1, length(values) - 1)
        Enum.at(values, idx, 0)
    end
  end

  defp backoff_delay_ms(_attempt), do: 0

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

  @opaque_sequence 10_000
  @responses_include ["reasoning.encrypted_content"]

  defp initial_provider_state(context) do
    case Map.get(context, :provider_type) do
      :responses ->
        input =
          case Map.get(context, :request_payload) do
            %{} = payload ->
              input = Map.get(payload, "input") || Map.get(payload, :input)
              if is_list(input), do: input, else: []

            _ ->
              []
          end

        {[], input}

      _other ->
        messages = Map.get(context, :messages) || []
        messages = if is_list(messages), do: messages, else: []
        {messages, []}
    end
  end

  defp provider_messages(state) do
    messages =
      case state.context.provider_type do
        :responses -> Map.get(state.context, :messages) || []
        _other -> state.messages_for_model || Map.get(state.context, :messages) || []
      end

    if is_list(messages), do: messages, else: []
  end

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

  defp chat_tool_call_raw(%{call_id: call_id, name: name} = tool_call)
       when is_binary(call_id) and call_id != "" and is_binary(name) and name != "" do
    raw = normalize_tool_call_map(Map.get(tool_call, :raw, %{}))

    arguments =
      tool_call_arguments_text(chat_tool_call_arguments(raw), Map.get(tool_call, :args, %{}))

    %{
      "id" => call_id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => arguments
      }
    }
  end

  defp chat_tool_call_raw(_other), do: nil

  defp chat_tool_call_arguments(%{} = raw) do
    get_in(raw, ["function", "arguments"]) || Map.get(raw, "arguments")
  end

  defp chat_tool_call_arguments(_other), do: nil

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
    case state.context.provider_type do
      :responses ->
        handle_tool_results_responses(state, results, opts)

      _other ->
        handle_tool_results_chat(state, results, opts)
    end
  end

  defp handle_tool_results_chat(state, results, opts) when is_list(opts) do
    runtime_step = apply_chat_tool_results_to_trace(state.runtime_step, results)

    case safe_persist(state.context.message_id, :step_done, fn ->
           Persistence.persist_step_trace_only!(state.context.message_id, runtime_step)
         end) do
      :ok ->
        tools_disabled = state.tools_disabled or Keyword.get(opts, :disable_tools, false)
        assistant_tool_message = assistant_tool_message_for_chat(runtime_step, results)

        tool_messages =
          results
          |> Enum.flat_map(fn result ->
            base_message = %{
              "role" => "tool",
              "tool_call_id" => result.call_id,
              "content" => result.text
            }

            [
              base_message
              | Media.media_followup_messages(result.media_contents, media_projection_opts(state))
            ]
          end)

        next_messages =
          (state.messages_for_model || [])
          |> List.wrap()
          |> Kernel.++([assistant_tool_message])
          |> Kernel.++(tool_messages)

        {next_messages, marker_index} =
          maybe_update_chat_run_cache_marker(state, next_messages)

        next_state = %{state | tools_disabled: tools_disabled}

        {raw_request, step_id} =
          start_next_step_metadata(next_state,
            next_messages: next_messages,
            next_input_items: nil
          )

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
          |> Map.put(:messages_for_model, next_messages)
          |> Map.put(:current_run_cache_marker_index, marker_index)
          |> Map.put(:retry_timer_ref, nil)
          |> Map.put(:stream_task, nil)

        state = start_stream_task(state)
        {:noreply, state}

      {:error, reason} ->
        finalize_error(state, "Failed to persist tool step: #{inspect(reason)}", %{})
    end
  end

  defp apply_chat_tool_results_to_trace(%RuntimeTrace.Step{} = runtime_step, results)
       when is_list(results) do
    Enum.reduce(results, runtime_step, fn result, step ->
      key = "tr:" <> to_string(result.call_id)

      opaque = %{
        "tool_call_id" => result.call_id,
        "name" => result.name,
        "raw" => result.result_raw
      }

      step
      |> RuntimeTrace.apply_event({:ensure_item, key, :tool_result, nil})
      |> RuntimeTrace.apply_event({:set_text, key, :tool_result, 1, to_string(result.text || "")})
      |> RuntimeTrace.apply_event({:set_opaque, key, :tool_result, @opaque_sequence, opaque})
      |> apply_media_contents_to_trace(key, :tool_result, result.media_contents)
      |> apply_artifacts_to_trace(result)
    end)
  end

  defp handle_tool_results_responses(state, results, opts) when is_list(opts) do
    output_items =
      case state.runtime_step.raw_response do
        %{} = raw -> Map.get(raw, "output") || []
        _ -> []
      end

    sanitized_output_items =
      sanitize_responses_output_items(output_items,
        provider_base_url: state.context.provider_base_url
      )

    {fco_items, runtime_step} = apply_responses_tool_results_to_trace(state, results)

    case safe_persist(state.context.message_id, :step_done, fn ->
           Persistence.persist_step_trace_only!(state.context.message_id, runtime_step)
         end) do
      :ok ->
        tools_disabled = state.tools_disabled or Keyword.get(opts, :disable_tools, false)

        media_input_items =
          Enum.flat_map(results, fn result ->
            Media.media_followup_input_items(result.media_contents, media_projection_opts(state))
          end)

        next_input_items =
          (state.responses_input_items || [])
          |> List.wrap()
          |> Kernel.++(sanitized_output_items)
          |> Kernel.++(fco_items)
          |> Kernel.++(media_input_items)

        next_state = %{state | tools_disabled: tools_disabled}

        {raw_request, step_id} =
          start_next_step_metadata(next_state,
            next_messages: nil,
            next_input_items: next_input_items
          )

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
          |> Map.put(:responses_input_items, next_input_items)
          |> Map.put(:retry_timer_ref, nil)
          |> Map.put(:stream_task, nil)

        state = start_stream_task(state)
        {:noreply, state}

      {:error, reason} ->
        finalize_error(state, "Failed to persist tool step: #{inspect(reason)}", %{})
    end
  end

  defp sanitize_responses_output_items(output_items, opts)
       when is_list(output_items) and is_list(opts) do
    base_url =
      opts
      |> Keyword.get(:provider_base_url)
      |> to_string()
      |> String.downcase()
      |> String.trim()

    # OpenRouter may return reasoning items with ids like `rs_...`. Passing those ids back can
    # trigger provider errors when responses are not stored. OpenAI's Responses API, however,
    # expects those ids to remain stable because function_call items are linked to reasoning items.
    drop_reasoning_ids? = base_url != "" and String.contains?(base_url, "openrouter.ai")

    output_items
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      item = Map.new(item)

      case {drop_reasoning_ids?, Map.get(item, "type"), Map.get(item, "id")} do
        {true, "reasoning", id} when is_binary(id) ->
          if String.starts_with?(id, "rs_") do
            Map.delete(item, "id")
          else
            item
          end

        _ ->
          item
      end
    end)
  end

  defp sanitize_responses_output_items(_other, _opts), do: []

  defp apply_responses_tool_results_to_trace(state, results) when is_list(results) do
    runtime_step = state.runtime_step

    fco_items =
      Enum.map(results, fn result ->
        %{
          "type" => "function_call_output",
          "id" => "fco_" <> Ash.UUID.generate(),
          "call_id" => result.call_id,
          "output" => result.text
        }
      end)

    runtime_step =
      Enum.zip(fco_items, results)
      |> Enum.reduce(runtime_step, fn {fco_item, result}, step ->
        item_id = Map.get(fco_item, "id") |> to_string()
        output_text = Map.get(fco_item, "output") |> to_string()

        opaque = %{
          "responses_item" => fco_item,
          "raw" => result.result_raw
        }

        step
        |> RuntimeTrace.apply_event({:ensure_item, item_id, :tool_result, nil})
        |> RuntimeTrace.apply_event({:set_text, item_id, :tool_result, 1, output_text})
        |> RuntimeTrace.apply_event(
          {:set_opaque, item_id, :tool_result, @opaque_sequence, opaque}
        )
        |> apply_media_contents_to_trace(item_id, :tool_result, result.media_contents)
        |> apply_artifacts_to_trace(result)
      end)

    {fco_items, runtime_step}
  end

  defp start_next_step_metadata(state, opts) when is_map(state) and is_list(opts) do
    next_sequence = state.step_sequence + 1
    now = DateTime.utc_now()

    raw_request =
      case state.context.provider_type do
        :responses ->
          input_items = Keyword.fetch!(opts, :next_input_items) |> List.wrap()

          RequestBuilder.build_responses_payload_from_input_items(
            state.context.model_name,
            state.context.parameters || %{},
            input_items,
            include: @responses_include,
            instructions: state.context.system_prompt,
            tools: current_tools_payload(state)
          )

        _other ->
          messages = Keyword.fetch!(opts, :next_messages) |> List.wrap()

          RequestBuilder.build_chat_completions_payload(
            state.context.model_name,
            state.context.parameters || %{},
            messages,
            tools: current_tools_payload(state)
          )
      end

    step_id =
      Persistence.ensure_step_started!(state.context.message_id, next_sequence, raw_request,
        started_at: now
      )

    {raw_request, step_id}
  end

  defp maybe_update_chat_run_cache_marker(state, messages) when is_list(messages) do
    cache_control_enabled = Map.get(state.context, :cache_control_enabled)
    history_length = Map.get(state.context, :history_length)

    if cache_control_enabled == true and is_integer(history_length) and history_length >= 0 do
      CacheControl.update_current_run_marker(messages,
        history_length: history_length,
        previous_marker_index: state.current_run_cache_marker_index
      )
    else
      {messages, nil}
    end
  end

  defp maybe_update_chat_run_cache_marker(_state, messages) do
    normalized = if is_list(messages), do: messages, else: []
    {normalized, nil}
  end

  defp assistant_tool_message_for_chat(%RuntimeTrace.Step{} = runtime_step, results)
       when is_list(results) do
    raw_response = runtime_step.raw_response
    assistant_raw = extract_assistant_chat_message(raw_response)

    assistant_content =
      assistant_raw
      |> Map.get("content")
      |> case do
        content when is_binary(content) ->
          content

        content when is_list(content) ->
          content
          |> Enum.map(fn
            %{} = part -> part["text"] || part["content"] || ""
            other -> to_string(other)
          end)
          |> Enum.join("")

        _other ->
          RuntimeTrace.text_for_item_type(runtime_step, :answer)
      end

    tool_calls =
      runtime_step
      |> tool_calls_from_runtime_step()
      |> Enum.map(&chat_tool_call_raw/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [_ | _] = list ->
          list

        _other ->
          results
          |> Enum.map(&chat_tool_call_raw/1)
          |> Enum.reject(&is_nil/1)
      end

    message = %{
      "role" => "assistant",
      "content" => to_string(assistant_content || ""),
      "tool_calls" => tool_calls
    }

    reasoning_details = Map.get(assistant_raw, "reasoning_details")

    message =
      cond do
        is_list(reasoning_details) and reasoning_details != [] ->
          Map.put(message, "reasoning_details", sanitize_reasoning_details(reasoning_details))

        true ->
          reasoning_text =
            assistant_raw
            |> Map.get("reasoning", Map.get(assistant_raw, "reasoning_content"))
            |> case do
              value when is_binary(value) ->
                String.trim(value)

              _other ->
                RuntimeTrace.text_for_item_type(runtime_step, :reasoning) |> String.trim()
            end

          if reasoning_text == "" do
            message
          else
            Map.put(message, "reasoning", reasoning_text)
          end
      end

    message
  end

  defp extract_assistant_chat_message(%{} = raw_response) do
    raw_response
    |> Map.get("choices", [])
    |> case do
      [first | _] when is_map(first) ->
        case Map.get(first, "message") do
          %{} = message -> Map.new(message)
          _other -> %{}
        end

      _other ->
        %{}
    end
  end

  defp extract_assistant_chat_message(_other), do: %{}

  defp tool_execution_context(state) do
    %ExecutionContext{
      owner_id: Map.get(state.context, :owner_id),
      chat_id: Map.get(state.context, :chat_id),
      message_id: Map.get(state.context, :message_id),
      assistant_message_id: Map.get(state.context, :message_id),
      provider_type: Map.get(state.context, :provider_type)
    }
  end

  defp media_projection_opts(state) do
    [
      supports_image_input: Map.get(state.context, :supports_image_input, false),
      provider_type: Map.get(state.context, :provider_type)
    ]
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

  defp apply_media_contents_to_trace(runtime_step, _item_key, _item_type, []), do: runtime_step

  defp apply_media_contents_to_trace(runtime_step, item_key, item_type, media_contents)
       when is_list(media_contents) do
    Enum.reduce(media_contents, runtime_step, fn content, step ->
      RuntimeTrace.apply_event(
        step,
        {:set_media, item_key, item_type, Map.get(content, :sequence, 1), content}
      )
    end)
  end

  defp apply_artifacts_to_trace(runtime_step, %{artifact_contents: []}), do: runtime_step

  defp apply_artifacts_to_trace(runtime_step, %{
         call_id: call_id,
         artifact_contents: artifact_contents
       }) do
    Enum.reduce(Enum.with_index(artifact_contents, 1), runtime_step, fn {content, idx}, step ->
      key = "artifact:" <> to_string(call_id) <> ":" <> Integer.to_string(idx)

      step
      |> RuntimeTrace.apply_event({:ensure_item, key, :artifact, nil})
      |> RuntimeTrace.apply_event({:set_media, key, :artifact, 1, Map.put(content, :sequence, 1)})
    end)
  end

  defp provider_error_value?(nil), do: false
  defp provider_error_value?(false), do: false
  defp provider_error_value?(""), do: false
  defp provider_error_value?(%{}), do: true
  defp provider_error_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp provider_error_value?(_other), do: true

  defp sanitize_reasoning_details(value) when not is_list(value), do: value

  defp sanitize_reasoning_details(value) when is_list(value) do
    Enum.map(value, fn
      %{} = item ->
        id = Map.get(item, "id") || Map.get(item, :id)

        if is_binary(id) and String.starts_with?(id, "rs_") do
          Map.delete(Map.new(item), "id")
        else
          Map.new(item)
        end

      other ->
        other
    end)
  end

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
