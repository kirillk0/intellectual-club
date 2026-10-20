defmodule IntellectualClub.Chat.Changes.CopyStoredStep do
  @moduledoc """
  Copies persisted physical encodings without decoding or hashing complete request chains.
  The source is read through Ash; callers cannot supply replacement request fields.
  """
  use Ash.Resource.Change

  alias IntellectualClub.Chat.ChatMessageStep

  @fields [
    :sequence,
    :status,
    :raw_request,
    :request_mode,
    :request_patch,
    :request_hash,
    :request_base_hash,
    :request_base_sequence,
    :request_checkpoint_distance,
    :raw_response,
    :response_final,
    :input_tokens,
    :output_tokens,
    :cached_input_tokens,
    :reasoning_tokens,
    :cost,
    :first_token_at,
    :last_token_at,
    :finished_at
  ]

  @impl true
  def batch_callbacks?(_changesets, _opts, context), do: Map.get(context, :bulk?, false)

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      [changeset] = before_batch([changeset], opts, context)
      changeset
    end)
  end

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def before_batch(changesets, _opts, %{actor: actor}) do
    ids = Enum.map(changesets, &Ash.Changeset.get_argument(&1, :source_step_id))

    sources =
      ChatMessageStep
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id | @fields])
      |> Ash.read!(actor: actor, authorize?: true)
      |> Map.new(&{&1.id, &1})

    Enum.map(changesets, fn changeset ->
      case Map.get(sources, Ash.Changeset.get_argument(changeset, :source_step_id)) do
        nil ->
          Ash.Changeset.add_error(changeset, field: :source_step_id, message: "is not accessible")

        source ->
          attrs = Map.take(source, @fields)

          attrs =
            if source.status in [:waiting_provider, :waiting_tools],
              do: Map.merge(attrs, %{status: :canceled, finished_at: DateTime.utc_now()}),
              else: attrs

          Ash.Changeset.force_change_attributes(changeset, attrs)
      end
    end)
  end
end
