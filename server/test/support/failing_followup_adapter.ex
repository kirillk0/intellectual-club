defmodule IntellectualClub.Test.FailingFollowupAdapter do
  @moduledoc false
  alias IntellectualClub.Test.AsyncPersistenceAdapter

  defdelegate request_snapshot(request), to: AsyncPersistenceAdapter
  defdelegate inject_steering(request, items, context), to: AsyncPersistenceAdapter
  defdelegate stream_generate(request, emit), to: AsyncPersistenceAdapter

  def build_followup_request(%{context: context}) do
    send(context.test_pid, :followup_attempted)
    raise ArgumentError, "Deterministic invalid follow-up"
  end
end
