defmodule IntellectualClub.Generation.DemoStreamTrace do
  @moduledoc """
  Trace-oriented adapter for the local `DemoStream`.

  DemoStream is used for the prototype and does not provide a real raw response.
  This module converts its `:content_delta` events into canonical runtime trace
  events so the worker can be provider-agnostic.
  """

  alias IntellectualClub.Generation.DemoStream

  @type trace_event :: IntellectualClub.Generation.RuntimeTrace.trace_event()

  @type event ::
          {:trace, trace_event()}
          | {:response_complete, map()}
          | {:response_error, map()}

  @spec stream_generate(map(), (event() -> any())) :: :ok
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    raw_request =
      case Map.get(opts, :request_payload) do
        payload when is_map(payload) -> payload
        _ -> %{}
      end

    emit.({:trace, {:set_step_raw_request, raw_request}})

    chunk_delay_ms = Map.get(opts, :chunk_delay_ms, 40)
    messages = Map.get(opts, :messages, [])

    emit_old = fn
      {:content_delta, delta} ->
        emit.({:trace, {:ensure_item, "answer", :answer, 1}})
        emit.({:trace, {:append_text, "answer", :answer, 1, to_string(delta || "")}})

      {:content_delta, delta, _raw} ->
        emit.({:trace, {:ensure_item, "answer", :answer, 1}})
        emit.({:trace, {:append_text, "answer", :answer, 1, to_string(delta || "")}})

      {:reasoning_delta, _delta} ->
        :ok

      {:reasoning_delta, _delta, _raw} ->
        :ok

      {:response_complete, meta} ->
        emit.({:trace, {:set_step_response_final, true}})

        meta =
          meta
          |> Map.new()
          |> Map.put_new(:provider, :demo)
          |> Map.put_new(:raw_request, raw_request)
          |> Map.put_new(:raw_response, nil)
          |> Map.put_new(:usage, nil)

        emit.({:response_complete, meta})

      {:response_error, meta} ->
        meta =
          meta
          |> Map.new()
          |> Map.put_new(:provider, :demo)
          |> Map.put_new(:raw_request, raw_request)
          |> Map.put_new(:raw_response, nil)

        emit.({:response_error, meta})

      other ->
        emit.(
          {:response_error,
           %{provider: :demo, error_text: inspect(other), raw_request: raw_request}}
        )
    end

    DemoStream.run(messages, [chunk_delay_ms: chunk_delay_ms], emit_old)
  end
end
