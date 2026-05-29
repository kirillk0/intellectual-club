defmodule IntellectualClub.Knowledge.Changes.UpdateDescendantTagFullNames do
  @moduledoc """
  Recomputes descendant knowledge tag paths after a tag path changes.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Ash.Query
  alias IntellectualClub.Knowledge.KnowledgeTag

  @impl true
  def change(changeset, _opts, context) do
    Changeset.after_action(changeset, fn _changeset, tag ->
      case update_children(tag, context) do
        :ok -> {:ok, tag}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp update_children(%KnowledgeTag{id: tag_id}, context) when is_integer(tag_id) do
    opts = ash_opts(context)

    KnowledgeTag
    |> Query.filter(parent_id == ^tag_id)
    |> Query.sort(id: :asc)
    |> Ash.read(opts)
    |> case do
      {:ok, children} ->
        Enum.reduce_while(children, :ok, fn child, :ok ->
          child
          |> Changeset.for_update(
            :update,
            %{name: child.name, parent_id: child.parent_id},
            opts
          )
          |> Ash.update(opts)
          |> case do
            {:ok, _updated_child} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  defp update_children(_tag, _context), do: :ok

  defp ash_opts(context) do
    []
    |> maybe_put(:actor, context.actor)
    |> maybe_put(:authorize?, context.authorize?)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
