defmodule IntellectualClub.TestSupport.UsageCostAdapter do
  @moduledoc false

  def stream_generate(%{context: context, request_payload: request_payload}, emit) do
    usage = Map.fetch!(context, :test_usage)

    emit.({:trace, {:set_text, "answer", :answer, 1, "Priced answer."}})

    if Map.get(context, :usage_delivery) == :trace do
      emit.({:trace, {:set_step_usage, usage}})
    end

    case Map.get(context, :terminal_mode, :complete) do
      :error ->
        emit.(
          {:response_error,
           %{
             error_text: "Priced provider error",
             raw_request: request_payload,
             raw_response: %{"error" => "priced-provider-error"},
             usage: usage
           }}
        )

      :wait ->
        send(Map.fetch!(context, :test_pid), {:usage_cost_adapter_ready, self()})

        receive do
          :finish -> :ok
        end

      :complete ->
        meta = %{
          raw_request: request_payload,
          raw_response: %{"id" => "priced-response", "output" => []}
        }

        meta =
          if Map.get(context, :usage_delivery) == :meta do
            Map.put(meta, :usage, usage)
          else
            meta
          end

        emit.({:response_complete, meta})
    end

    :ok
  end
end
