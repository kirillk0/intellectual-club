defmodule IntellectualClub.Generation.StepRequests do
  @moduledoc """
  Opaque compact request storage. This module has no provider or image knowledge.

  Writers merge `create_attributes/2` into their ChatMessageStep create input.
  Readers must reconstruct through this API instead of reading `raw_request`.
  All storage reads require an explicit actor and preserve Ash authorization.
  Backfill is manual, opt-in, bounded, and dry-run by default.
  """

  alias IntellectualClub.Generation.StepRequests.{Backfill, Codec, Reader}
  alias IntellectualClub.Generation.StepRequests.Backfill.Job

  defdelegate normalize!(request), to: Codec
  defdelegate create_attributes(request, opts \\ []), to: Codec

  def request_for_step!(step_id, opts) do
    [step_id] |> requests_for_steps!(opts) |> Map.fetch!(step_id)
  end

  def request_for_step(step_id, opts) do
    {:ok, request_for_step!(step_id, opts)}
  rescue
    error -> {:error, error}
  end

  defdelegate requests_for_steps!(steps, opts), to: Reader
  defdelegate backfill_batch(opts), to: Backfill, as: :run_batch
  defdelegate start_backfill(opts), to: Job, as: :start
  defdelegate backfill_status(pid, opts), to: Job, as: :status
  defdelegate cancel_backfill(pid, opts), to: Job, as: :cancel
end
