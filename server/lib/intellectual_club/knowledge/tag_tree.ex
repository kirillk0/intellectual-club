defmodule IntellectualClub.Knowledge.TagTree do
  @moduledoc """
  Helpers for traversing hierarchical knowledge tags.

  The core use case is server-side filtering of knowledge blocks by a selected
  tag and all of its descendants.
  """

  alias IntellectualClub.Knowledge.KnowledgeTag

  require Ash.Query

  @default_max_nodes 50_000

  @doc """
  Returns the given tag id and all descendant tag ids (recursive).

  If the tag does not exist (or is not accessible to the actor), returns `[]`.
  The traversal is cycle-safe and stops after `:max_nodes` to avoid unbounded work.
  """
  @spec subtree_ids(integer(), keyword()) :: [integer()]
  def subtree_ids(tag_id, opts) when is_integer(tag_id) do
    max_nodes = Keyword.get(opts, :max_nodes, @default_max_nodes)
    read_opts = read_opts(opts)

    case Ash.get(KnowledgeTag, tag_id, read_opts) do
      {:ok, _tag} ->
        # max_nodes counts the root as well.
        remaining = max(0, max_nodes - 1)

        descendants =
          descendant_ids([tag_id], MapSet.new([tag_id]), read_opts, remaining)

        [tag_id | descendants]

      {:error, _} ->
        []
    end
  end

  defp descendant_ids(_frontier, _visited, _read_opts, remaining) when remaining <= 0, do: []
  defp descendant_ids([], _visited, _read_opts, _remaining), do: []

  defp descendant_ids(frontier, visited, read_opts, remaining) do
    query =
      KnowledgeTag
      |> Ash.Query.filter(parent_id in ^frontier)
      |> Ash.Query.select([])

    case Ash.read(query, read_opts) do
      {:ok, tags} ->
        child_ids =
          tags
          |> Enum.map(& &1.id)
          |> Enum.reject(&MapSet.member?(visited, &1))

        current_batch = Enum.take(child_ids, remaining)

        visited =
          Enum.reduce(current_batch, visited, fn id, acc ->
            MapSet.put(acc, id)
          end)

        current_batch ++
          descendant_ids(current_batch, visited, read_opts, remaining - length(current_batch))

      {:error, _} ->
        []
    end
  end

  defp read_opts(opts) do
    actor = Keyword.get(opts, :actor)
    authorize? = Keyword.get(opts, :authorize?)

    [actor: actor]
    |> maybe_put_authorize(authorize?)
  end

  defp maybe_put_authorize(opts, authorize?) when is_boolean(authorize?),
    do: Keyword.put(opts, :authorize?, authorize?)

  defp maybe_put_authorize(opts, _authorize?), do: opts
end
