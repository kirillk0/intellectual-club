defmodule IntellectualClub.Test.AsyncPersistenceAdapter do
  @moduledoc false

  def request_snapshot(raw_request) do
    %{model_input: Map.get(raw_request, "messages", []), system_prompt: "", history_length: nil}
  end

  def inject_steering(raw_request, items, _context) do
    messages = Map.get(raw_request, "messages", [])
    steering = Enum.map(items, &%{"role" => "user", "content" => &1.text})
    request = Map.put(raw_request, "messages", messages ++ steering)
    %{raw_request: request, request_snapshot: request_snapshot(request)}
  end

  def build_followup_request(%{runtime_step: runtime, results: results}) do
    messages = Map.get(runtime.raw_request, "messages", [])
    outputs = Enum.map(results, &%{"role" => "tool", "content" => &1.text})
    request = Map.put(runtime.raw_request, "messages", messages ++ outputs)
    %{raw_request: request, request_snapshot: request_snapshot(request)}
  end

  def stream_generate(%{context: context, request_payload: request}, emit) do
    send(context.test_pid, {:provider_started, context.message_id, self(), request})

    receive do
      {:complete, :tools} ->
        emit.(
          {:trace,
           {:set_opaque, "call", :tool_call, 1,
            %{
              "type" => "function_call",
              "call_id" => "call_async",
              "name" => Map.get(context, :test_tool_name, "missing__run"),
              "arguments" => Jason.encode!(Map.get(context, :test_tool_args, %{}))
            }}}
        )

        complete(emit)

      {:complete, :answer} ->
        emit.({:trace, {:set_text, "answer", :answer, 1, "Committed answer"}})
        complete(emit)

      {:complete, {:answer, text}} ->
        emit.({:trace, {:set_text, "answer", :answer, 1, text}})
        complete(emit)

      :retry ->
        emit.(
          {:response_error,
           %{
             retryable: true,
             status_code: 503,
             error_kind: "network",
             error_text: "Transient failure"
           }}
        )
    end

    :ok
  end

  defp complete(emit) do
    emit.(
      {:response_complete,
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
       }}
    )
  end
end
