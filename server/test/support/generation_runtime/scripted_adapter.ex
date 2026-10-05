defmodule IntellectualClub.Test.GenerationRuntime.ScriptedAdapter do
  @moduledoc """
  A scriptable fake provider adapter for Generation Worker tests.

  Every provider attempt announces itself to `context.test_pid` as
  `{:provider_started, message_id, provider_pid, request}`, runs the actions of
  its script and then, by default, serves commands sent by the test:

      send(provider, {:complete, :answer})          # "Committed answer" + usage
      send(provider, {:complete, {:answer, text}})
      send(provider, {:complete, :tools})           # tool calls from the context
      send(provider, :retry)                        # retryable 503 network error
      send(provider, {:run, actions})               # any of the actions below

  ## Script

  `context.test_script` is a list of actions run on every attempt, or a function
  `attempt -> actions` (attempts are counted per context, starting at 1; the
  context must carry `test_attempts: :counters.new(1, [])`). The default script
  is `[:await]`. Actions:

    * `{:emit, event}` — emits a raw provider event;
    * `{:text, kind, text}` — emits `{:trace, {:set_text, "<kind>", kind, 1, text}}`;
    * `:answer`, `{:answer, text}`, `:tools` — completes the response;
    * `{:complete, meta}` — emits `:response_complete` with `meta` over the defaults;
    * `:retry`, `{:error, meta}` — emits `:response_error` with `meta` over a
      retryable 503 network error;
    * `{:notify, message}` — sends `message` to the test;
    * `:share_emit` — sends `{:provider_emit, message_id, self(), emit}` so the
      test can replay events from this stream after it became stale;
    * `:await` — serves commands until one of them completes the response;
    * `:hang` — blocks until the Worker kills the provider.

  ## Other context switches

    * `:test_tool_calls` (`[%{name:, args:}]`) or `:test_tool_name` /
      `:test_tool_args` — the calls emitted by `:tools`;
    * `:test_reject_steering?` — `inject_steering/3` raises;
    * `:test_fail_followup?` — `build_followup_request/1` raises.

  Steering injection and follow-up preparation are reported to the test as
  `{:steering_attempted, message_id, texts}` and `{:followup_prepared, message_id}`.
  """

  @default_answer "Committed answer"

  def request_snapshot(raw_request) do
    %{model_input: Map.get(raw_request, "messages", []), system_prompt: "", history_length: nil}
  end

  def inject_steering(raw_request, items, context) do
    texts = Enum.map(items, & &1.text)
    send(context.test_pid, {:steering_attempted, context.message_id, texts})

    if Map.get(context, :test_reject_steering?, false) do
      raise ArgumentError, "Injected steering-only preparation failure"
    end

    steering = Enum.map(texts, &%{"role" => "user", "content" => &1})
    request = Map.update(raw_request, "messages", steering, &(&1 ++ steering))
    %{raw_request: request, request_snapshot: request_snapshot(request)}
  end

  def build_followup_request(%{context: context} = followup) do
    send(context.test_pid, {:followup_prepared, context.message_id})

    if Map.get(context, :test_fail_followup?, false) do
      raise ArgumentError, "Deterministic invalid follow-up"
    end

    followup_payload(followup)
  end

  @doc "The follow-up request built from a step and its tool results, without side effects."
  def followup_payload(%{runtime_step: runtime, results: results}) do
    outputs = Enum.map(results, &%{"role" => "tool", "content" => &1.text})
    request = Map.update(runtime.raw_request, "messages", outputs, &(&1 ++ outputs))
    %{raw_request: request, request_snapshot: request_snapshot(request)}
  end

  def stream_generate(%{context: context, request_payload: request}, emit) do
    send(context.test_pid, {:provider_started, context.message_id, self(), request})
    env = %{context: context, request: request, emit: emit}
    run(script(context), env)
    :ok
  end

  defp script(context) do
    case Map.get(context, :test_script, [:await]) do
      script when is_list(script) ->
        script

      script when is_function(script, 1) ->
        counter = Map.fetch!(context, :test_attempts)
        :counters.add(counter, 1, 1)
        script.(:counters.get(counter, 1))
    end
  end

  defp run([], _env), do: :ok
  defp run([:await | _rest], env), do: await(env)
  defp run([:hang | _rest], _env), do: Process.sleep(:infinity)

  defp run([action | rest], env) do
    case act(action, env) do
      :continue -> run(rest, env)
      :done -> :ok
    end
  end

  defp await(env) do
    receive do
      {:complete, meta} when is_map(meta) -> act({:complete, meta}, env)
      {:complete, completion} -> act(completion, env)
      :retry -> act(:retry, env)
      {:run, actions} -> run(actions ++ [:await], env)
    end
  end

  defp act({:emit, event}, env), do: emit(env, event)

  defp act({:text, kind, text}, env) do
    emit(env, {:trace, {:set_text, Atom.to_string(kind), kind, 1, text}})
  end

  defp act({:notify, message}, env) do
    send(env.context.test_pid, message)
    :continue
  end

  defp act(:share_emit, env) do
    send(env.context.test_pid, {:provider_emit, env.context.message_id, self(), env.emit})
    :continue
  end

  defp act(:answer, env), do: act({:answer, @default_answer}, env)

  defp act({:answer, text}, env) do
    act({:text, :answer, text}, env)
    act({:complete, %{}}, env)
  end

  defp act(:tools, env) do
    env.context
    |> tool_calls()
    |> Enum.with_index(1)
    |> Enum.each(fn {call, index} ->
      emit(
        env,
        {:trace,
         {:set_opaque, "call_#{index}", :tool_call, index,
          %{
            "type" => "function_call",
            "call_id" => if(index == 1, do: "call_async", else: "call_async_#{index}"),
            "name" => call.name,
            "arguments" => Jason.encode!(call.args)
          }}}
      )
    end)

    act({:complete, %{}}, env)
  end

  defp act({:complete, meta}, env) when is_map(meta) do
    emit(env, {:response_complete, Map.merge(complete_meta(), meta)})
    :done
  end

  defp act(:retry, env), do: act({:error, %{}}, env)

  defp act({:error, meta}, env) when is_map(meta) do
    emit(env, {:response_error, Map.merge(error_meta(), meta)})
    :done
  end

  defp emit(env, event) do
    env.emit.(event)
    :continue
  end

  defp tool_calls(context) do
    Map.get_lazy(context, :test_tool_calls, fn ->
      [
        %{
          name: Map.get(context, :test_tool_name, "missing__run"),
          args: Map.get(context, :test_tool_args, %{})
        }
      ]
    end)
  end

  defp complete_meta do
    %{
      raw_request: %{"must_not_replace" => true},
      raw_response: %{"id" => "async_response", "large_raw_only" => "not for poll"},
      usage: %{
        input_tokens: 12,
        output_tokens: 3,
        cached_input_tokens: 4,
        reasoning_tokens: 1,
        cost: 0.125
      }
    }
  end

  defp error_meta do
    %{retryable: true, status_code: 503, error_kind: "network", error_text: "Transient failure"}
  end
end

defmodule IntellectualClub.Test.GenerationRuntime.ScriptedSessionAdapter do
  @moduledoc """
  `IntellectualClub.Test.GenerationRuntime.ScriptedAdapter` with a provider
  session. The session is an unlinked process, or an opaque term when the
  context sets `test_session: :term`. The test receives
  `{:provider_session_started, message_id, session}` and, when the Worker stops
  it gracefully, `{:provider_session_stopped, message_id, session}`.
  """

  alias IntellectualClub.Test.GenerationRuntime.ScriptedAdapter

  defdelegate request_snapshot(raw_request), to: ScriptedAdapter
  defdelegate inject_steering(raw_request, items, context), to: ScriptedAdapter
  defdelegate build_followup_request(opts), to: ScriptedAdapter
  defdelegate stream_generate(opts, emit), to: ScriptedAdapter

  def start_session(context) do
    %{test_pid: test_pid, message_id: message_id} = context

    session =
      if Map.get(context, :test_session) == :term do
        {:scripted_session, test_pid, message_id}
      else
        spawn(fn ->
          receive do
            :stop -> send(test_pid, {:provider_session_stopped, message_id, self()})
          end
        end)
      end

    send(test_pid, {:provider_session_started, message_id, session})
    {:ok, session}
  end

  def stop_session({:scripted_session, test_pid, message_id} = session) do
    send(test_pid, {:provider_session_stopped, message_id, session})
    :ok
  end

  def stop_session(session) when is_pid(session) do
    send(session, :stop)
    :ok
  end
end
