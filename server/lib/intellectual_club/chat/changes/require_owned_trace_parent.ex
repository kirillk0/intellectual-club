defmodule IntellectualClub.Chat.Changes.RequireOwnedTraceParent do
  @moduledoc """
  Authorizes copied trace parents in batches. Trace write policies require ownership.
  """
  use Ash.Resource.Change

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
  def before_batch(changesets, opts, %{actor: actor}) do
    relationship = Ash.Resource.Info.relationship(hd(changesets).resource, opts[:relationship])
    field = relationship.source_attribute
    ids = changesets |> Enum.map(&Ash.Changeset.get_attribute(&1, field)) |> Enum.uniq()

    query =
      relationship.destination
      |> Ash.Query.filter(id in ^ids and owner_id == ^actor.id)
      |> Ash.Query.select([:id])

    query =
      if opts[:terminal?] do
        query
        |> Ash.Query.filter(status in [:done, :error, :canceled])
        |> Ash.Query.lock(:for_update)
      else
        query
      end

    owned =
      query
      |> Ash.read!(actor: actor, authorize?: true)
      |> MapSet.new(& &1.id)

    Enum.map(changesets, fn changeset ->
      if Ash.Changeset.get_attribute(changeset, field) in owned do
        changeset
      else
        Ash.Changeset.add_error(changeset, field: field, message: "is invalid or not accessible")
      end
    end)
  end
end
