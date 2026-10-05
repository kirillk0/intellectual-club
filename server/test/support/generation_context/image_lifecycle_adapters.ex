defmodule IntellectualClub.GenerationContext.ImageLifecycleAdapters do
  @moduledoc """
  Provider adapters for request image lifecycle tests of the generation worker.

  Every adapter hydrates the logical request before "transport", exactly as a
  real Responses adapter does, and reports
  `{:image_request, attempt, stream_pid, step_id, logical_request, wire_request}`
  to `context.test_pid`. `context.attempts` must be an Agent holding the number
  of stream attempts so far. Streams that do not finish immediately block until
  they receive `:complete` (or the worker is canceled).

    * `Steering` supports steering injection;
    * `RetryOnce` fails the first attempt with a retryable network error;
    * `ToolFollowup` returns a tool call on the first attempt and supports
      follow-up requests.
  """

  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Llm.Providers.Responses.ImageMapper

  @doc false
  def hydrate_and_report(opts) do
    context = Map.fetch!(opts, :context)
    logical_request = Map.fetch!(opts, :request_payload)
    step_id = Map.fetch!(opts, :request_step_id)
    attempt = Agent.get_and_update(context.attempts, &{&1 + 1, &1 + 1})

    {:ok, wire_request} =
      RequestImages.hydrate(logical_request, step_id,
        mapper: &ImageMapper.map_request_images/3,
        cache: Map.fetch!(opts, :image_cache),
        on_cache: Map.fetch!(opts, :image_cache_update)
      )

    send(
      context.test_pid,
      {:image_request, attempt, self(), step_id, logical_request, wire_request}
    )

    {attempt, logical_request}
  end

  @doc false
  def complete_on_signal(emit, logical_request, text) do
    receive do
      :complete ->
        emit.({:trace, {:set_text, "answer", :answer, 1, text}})

        emit.(
          {:response_complete,
           %{raw_request: logical_request, raw_response: %{"id" => "complete", "output" => []}}}
        )
    end

    :ok
  end

  @doc false
  def request_snapshot(raw_request) do
    %{model_input: Map.get(raw_request, "input", []), system_prompt: "", history_length: nil}
  end

  defmodule Steering do
    @moduledoc false

    alias IntellectualClub.GenerationContext.ImageLifecycleAdapters, as: Adapters

    defdelegate map_request_images(request, acc, mapper),
      to: IntellectualClub.Llm.Providers.Responses.ImageMapper

    defdelegate request_snapshot(raw_request), to: Adapters

    def inject_steering(raw_request, steering_items, _context) do
      steering_input =
        Enum.map(steering_items, fn item ->
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => Map.fetch!(item, :text)}]
          }
        end)

      raw_request = Map.update(raw_request, "input", steering_input, &(&1 ++ steering_input))
      %{raw_request: raw_request, request_snapshot: request_snapshot(raw_request)}
    end

    def stream_generate(opts, emit) do
      {_attempt, logical_request} = Adapters.hydrate_and_report(opts)
      Adapters.complete_on_signal(emit, logical_request, "Completed after steering.")
    end
  end

  defmodule RetryOnce do
    @moduledoc false

    alias IntellectualClub.GenerationContext.ImageLifecycleAdapters, as: Adapters

    defdelegate map_request_images(request, acc, mapper),
      to: IntellectualClub.Llm.Providers.Responses.ImageMapper

    def stream_generate(opts, emit) do
      case Adapters.hydrate_and_report(opts) do
        {1, logical_request} ->
          emit.(
            {:response_error,
             %{
               retryable: true,
               error_kind: "network",
               status_code: 503,
               error_text: "Retry once",
               raw_request: logical_request
             }}
          )

          :ok

        {_attempt, logical_request} ->
          Adapters.complete_on_signal(emit, logical_request, "Recovered.")
      end
    end
  end

  defmodule ToolFollowup do
    @moduledoc false

    alias IntellectualClub.GenerationContext.ImageLifecycleAdapters, as: Adapters

    defdelegate map_request_images(request, acc, mapper),
      to: IntellectualClub.Llm.Providers.Responses.ImageMapper

    defdelegate request_snapshot(raw_request), to: Adapters

    def build_followup_request(opts) do
      runtime_step = Map.fetch!(opts, :runtime_step)

      %{
        runtime_step: runtime_step,
        raw_request: runtime_step.raw_request,
        request_snapshot: request_snapshot(runtime_step.raw_request)
      }
    end

    def stream_generate(opts, emit) do
      case Adapters.hydrate_and_report(opts) do
        {1, logical_request} ->
          emit_tool_call(emit, "call_image_followup")

          emit.(
            {:response_complete,
             %{raw_request: logical_request, raw_response: %{"id" => "tool-step", "output" => []}}}
          )

          :ok

        {_attempt, logical_request} ->
          Adapters.complete_on_signal(emit, logical_request, "Follow-up completed.")
      end
    end

    defp emit_tool_call(emit, call_id) do
      arguments = Jason.encode!(%{"value" => "one"})
      emit.({:trace, {:ensure_item, "tc:" <> call_id, :tool_call, 1}})

      emit.(
        {:trace,
         {:set_opaque, "tc:" <> call_id, :tool_call, 10_000,
          %{
            "tool_call_id" => call_id,
            "call_id" => call_id,
            "name" => "demo__echo",
            "raw" => %{
              "id" => call_id,
              "type" => "function",
              "function" => %{"name" => "demo__echo", "arguments" => arguments}
            }
          }}}
      )
    end
  end
end
