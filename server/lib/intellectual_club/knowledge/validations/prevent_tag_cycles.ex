defmodule IntellectualClub.Knowledge.Validations.PreventTagCycles do
  @moduledoc """
  Prevents creating cycles in knowledge tag hierarchies.

  A cycle happens when a tag becomes a parent of itself (directly or through
  any of its descendants).
  """

  use Ash.Resource.Validation

  alias IntellectualClub.Knowledge.KnowledgeTag

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)
    self_id = changeset.data.id

    cond do
      is_nil(self_id) ->
        :ok

      is_nil(parent_id) ->
        :ok

      parent_id == self_id ->
        {:error, field: :parent_id, message: "cannot be the tag itself"}

      true ->
        case check_ancestor_chain(parent_id, self_id, context) do
          :ok ->
            :ok

          {:error, :descendant} ->
            {:error, field: :parent_id, message: "cannot be a descendant tag"}

          {:error, :cycle} ->
            {:error, field: :parent_id, message: "tag hierarchy contains a cycle"}

          {:error, :invalid_parent} ->
            {:error, field: :parent_id, message: "must reference an existing tag"}
        end
    end
  end

  defp check_ancestor_chain(parent_id, self_id, context) do
    opts =
      [actor: context.actor]
      |> maybe_put_authorize(context)

    do_check_ancestor_chain(parent_id, self_id, MapSet.new(), opts)
  end

  defp do_check_ancestor_chain(current_id, self_id, visited, opts) do
    cond do
      current_id == self_id ->
        {:error, :descendant}

      MapSet.member?(visited, current_id) ->
        {:error, :cycle}

      true ->
        visited = MapSet.put(visited, current_id)

        case Ash.get(KnowledgeTag, current_id, opts) do
          {:ok, tag} ->
            case tag.parent_id do
              nil -> :ok
              next_id -> do_check_ancestor_chain(next_id, self_id, visited, opts)
            end

          {:error, _error} ->
            {:error, :invalid_parent}
        end
    end
  end

  defp maybe_put_authorize(opts, context) do
    if is_boolean(context.authorize?) do
      Keyword.put(opts, :authorize?, context.authorize?)
    else
      opts
    end
  end
end
