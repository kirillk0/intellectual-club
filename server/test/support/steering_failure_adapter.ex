defmodule IntellectualClub.Test.SteeringFailureAdapter do
  @moduledoc false

  alias IntellectualClub.Test.AsyncPersistenceAdapter

  defdelegate request_snapshot(request), to: AsyncPersistenceAdapter
  defdelegate stream_generate(opts, emit), to: AsyncPersistenceAdapter

  def inject_steering(request, items, context) do
    send(context.test_pid, {:steering_attempted, context.message_id, Enum.map(items, & &1.text)})

    if Map.get(context, :test_reject_steering?, false) do
      raise ArgumentError, "Injected steering-only preparation failure"
    end

    AsyncPersistenceAdapter.inject_steering(request, items, context)
  end

  def build_followup_request(%{context: context} = opts) do
    send(context.test_pid, {:followup_prepared, context.message_id})
    AsyncPersistenceAdapter.build_followup_request(opts)
  end
end
