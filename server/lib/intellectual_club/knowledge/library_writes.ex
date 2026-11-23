defmodule IntellectualClub.Knowledge.LibraryWrites do
  @moduledoc """
  Owner-authorized knowledge library writes, scoped to a configured tag subtree.
  """

  alias IntellectualClub.Knowledge.{
    KnowledgeBlock,
    KnowledgeBlockTag,
    KnowledgeTag,
    LibraryText,
    TagTree
  }

  require Ash.Query

  def revision(%KnowledgeBlock{updated_at: %DateTime{} = updated_at}),
    do: DateTime.to_iso8601(updated_at)

  def create(root_tag_id, actor, attrs) do
    transact(root_tag_id, actor, fn ->
      query =
        KnowledgeTag
        |> Ash.Query.filter(id == ^root_tag_id and owner_id == ^actor.id)
        |> Ash.Query.select([])
        |> Ash.Query.lock("FOR SHARE")

      case Ash.read_one(query, actor: actor, authorize?: true) do
        {:ok, %KnowledgeTag{}} ->
          input =
            attrs
            |> Map.take(["name", "content", "version"])
            |> Map.put("tag_bindings", [%{knowledge_tag_id: root_tag_id}])

          KnowledgeBlock
          |> Ash.Changeset.for_create(:create, input, actor: actor)
          |> Ash.create(actor: actor, authorize?: true)

        _other ->
          tag_unavailable()
      end
    end)
  end

  def edit(root_tag_id, actor, block_id, expected_revision, attrs) do
    with_block(root_tag_id, actor, block_id, expected_revision, fn block, _external_tags? ->
      with {:ok, content} <-
             LibraryText.edit(
               block.content,
               Map.get(attrs, "replacements", []),
               attrs["append_text"]
             ) do
        input = Map.take(attrs, ["name", "version"])
        input = if content == block.content, do: input, else: Map.put(input, "content", content)

        block
        |> Ash.Changeset.for_update(:update, input, actor: actor)
        |> Ash.update(actor: actor, authorize?: true)
      end
    end)
  end

  def delete(root_tag_id, actor, block_id, expected_revision) do
    with_block(root_tag_id, actor, block_id, expected_revision, fn block, external_tags? ->
      if external_tags? do
        in_use("tags outside this library")
      else
        with :ok <- ensure_unused(block, actor) do
          Ash.destroy(block, actor: actor, authorize?: true)
        end
      end
    end)
  end

  defp with_block(root_tag_id, actor, block_id, expected_revision, fun) do
    transact(root_tag_id, actor, fn ->
      case TagTree.subtree_ids(root_tag_id, actor: actor, authorize?: true, lock: "FOR SHARE") do
        [] ->
          tag_unavailable()

        tag_ids ->
          with {:ok, block} <- lock_block(block_id, actor, tag_ids),
               {:ok, external_tags?} <- lock_membership(block_id, actor, tag_ids),
               :ok <- check_revision(block, expected_revision) do
            fun.(block, external_tags?)
          end
      end
    end)
  end

  defp lock_block(id, actor, tag_ids) do
    # FOR UPDATE also excludes new FK references. Inspect dependencies using a
    # fresh statement after this lock, not the locking SELECT's earlier snapshot.
    KnowledgeBlock
    |> Ash.Query.filter(
      id == ^id and owner_id == ^actor.id and exists(tag_bindings, knowledge_tag_id in ^tag_ids)
    )
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(actor: actor, authorize?: true)
    |> case do
      {:ok, nil} -> block_unavailable()
      result -> result
    end
  end

  defp lock_membership(id, actor, tag_ids) do
    # A tag can be detached without updating its block. Lock the bindings and
    # recheck scope after acquiring the block lock, including on edit.
    KnowledgeBlockTag
    |> Ash.Query.filter(knowledge_block_id == ^id)
    |> Ash.Query.select([:knowledge_tag_id])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock("FOR SHARE")
    |> Ash.read(actor: actor, authorize?: true)
    |> case do
      {:ok, bindings} ->
        subtree = MapSet.new(tag_ids)

        {inside, outside} =
          Enum.split_with(bindings, &MapSet.member?(subtree, &1.knowledge_tag_id))

        if inside == [], do: block_unavailable(), else: {:ok, outside != []}

      error ->
        error
    end
  end

  defp check_revision(block, expected) do
    if revision(block) == expected,
      do: :ok,
      else: {:error, :revision_conflict, "Block has changed. Read it again before writing."}
  end

  defp ensure_unused(block, actor) do
    KnowledgeBlock
    |> Ash.Query.for_read(:library_delete_dependencies, %{block_id: block.id}, actor: actor)
    |> Ash.read_one(actor: actor, authorize?: true)
    |> case do
      {:ok, %KnowledgeBlock{aggregates: flags, image_file_id: image}} ->
        usages = for {key, true} <- flags, do: key |> Atom.to_string() |> String.replace("_", " ")
        usages = if is_nil(image), do: usages, else: ["image" | usages]
        if usages == [], do: :ok, else: in_use(Enum.join(Enum.sort(usages), ", "))

      {:ok, nil} ->
        block_unavailable()

      error ->
        error
    end
  end

  defp transact(root_tag_id, %{id: id}, fun)
       when is_integer(root_tag_id) and root_tag_id > 0 and is_integer(id) and id > 0 do
    # Business rejections precede the sole mutating Ash action. Ash.transact
    # rolls back action errors, including any partially managed relationships.
    case Ash.transact(KnowledgeBlock, fun) do
      {:ok, result} -> result
      {:error, _error} -> {:error, :write_failed, "The knowledge block operation failed."}
    end
  end

  defp transact(_root_tag_id, _actor, _fun), do: tag_unavailable()

  defp block_unavailable,
    do: {:error, :block_not_available, "Block is not available in this knowledge library."}

  defp tag_unavailable,
    do: {:error, :block_not_available, "Configured knowledge library tag is not available."}

  defp in_use(usage), do: {:error, :block_in_use, "Block is in use: #{usage}."}
end
