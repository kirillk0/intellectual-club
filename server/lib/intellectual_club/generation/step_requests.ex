defmodule IntellectualClub.Generation.StepRequests do
  @moduledoc """
  Opaque compact request storage. This module has no provider or image knowledge.

  Generation writers prepare the resource-owned logical action with `prepare_create!/3`.
  `create_attributes/2` remains available for independently validated physical writes.
  Readers must reconstruct through this API instead of reading `raw_request`.
  All storage reads require an explicit actor and preserve Ash authorization.
  Backfill is manual, opt-in, bounded, and dry-run by default.
  """

  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Generation.StepRequests.{Backfill, Codec, Reader}
  alias IntellectualClub.Generation.StepRequests.Backfill.Job

  defdelegate normalize!(request), to: Codec
  defdelegate snapshot!(request), to: Codec
  defdelegate hash(request), to: Codec
  defdelegate equal?(left, right), to: Codec
  defdelegate create_attributes(request, opts \\ []), to: Codec

  @doc """
  Prepares a logical create before publication locks are acquired.

  Returns `{changeset, snapshot}`. Publish the changeset via `Ash.create!` in the
  same transaction that attaches staged image bindings. The snapshot is useful
  to the runtime but is never accepted as authority at the Ash boundary.
  """
  def prepare_create!(attributes, request, opts) do
    actor = Reader.actor!(opts)
    previous = Keyword.get(opts, :previous_step)

    if previous &&
         (previous.chat_message_id != attributes.chat_message_id or
            previous.sequence != attributes.sequence - 1),
       do: raise(ArgumentError, "Request base must be the previous step in this message")

    changeset =
      ChatMessageStep
      |> Ash.Changeset.for_create(:create_request, attributes,
        actor: actor,
        private_arguments: %{
          request: request,
          request_base: Keyword.get(opts, :previous_request),
          request_base_step_id: if(previous, do: previous.id),
          force_full: Keyword.get(opts, :force_full, false),
          max_chain: Keyword.get(opts, :max_chain, Codec.max_chain())
        }
      )
      |> Ash.Changeset.set_context(%{generation_lease: Keyword.get(opts, :lease)})

    unless changeset.valid?, do: raise(Ash.Error.to_error_class(changeset))
    {changeset, Map.fetch!(changeset.context, :step_request_snapshot)}
  end

  def request_for_step!(step_id, opts) do
    [step_id] |> requests_for_steps!(opts) |> Map.fetch!(step_id)
  end

  def request_for_step(step_id, opts) do
    {:ok, request_for_step!(step_id, opts)}
  rescue
    error -> {:error, error}
  end

  defdelegate requests_for_steps!(steps, opts), to: Reader
  defdelegate snapshots_for_steps!(steps, opts), to: Reader
  defdelegate backfill_batch(opts), to: Backfill, as: :run_batch
  defdelegate start_backfill(opts), to: Job, as: :start
  defdelegate backfill_status(pid, opts), to: Job, as: :status
  defdelegate cancel_backfill(pid, opts), to: Job, as: :cancel
end
