defmodule IntellectualClub.Generation.StepRequests.Error do
  @moduledoc "An invalid or inaccessible stored request, without exposing its payload."

  defexception [:reason, :step_id]

  @impl true
  def message(%{reason: reason, step_id: nil}), do: "Step request: #{reason}"
  def message(%{reason: reason, step_id: id}), do: "Step request #{id}: #{reason}"
end
