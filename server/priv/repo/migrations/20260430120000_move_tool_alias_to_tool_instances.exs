defmodule IntellectualClub.Repo.Migrations.MoveToolAliasToToolInstances do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  @max_alias_length 64
  @binding_tables [
    {"bot_tool_bindings", 0},
    {"chat_tool_bindings", 1},
    {"bot_user_tool_bindings", 2}
  ]

  def up do
    alter table(:tool_instances) do
      add :alias, :text
    end

    flush()

    backfill_tool_aliases()

    unless sqlite?() do
      alter table(:tool_instances) do
        modify :alias, :text, null: false
      end
    end

    create unique_index(:tool_instances, [:owner_id, :alias],
             name: "tool_instances_unique_owner_alias_index"
           )

    drop_if_exists unique_index(:bot_tool_bindings, [:bot_id, :alias],
                     name: "bot_tool_bindings_unique_bot_alias_index"
                   )

    drop_if_exists unique_index(:bot_user_tool_bindings, [:owner_id, :bot_id, :alias],
                     name: "bot_user_tool_bindings_unique_owner_bot_alias_index"
                   )

    drop_if_exists unique_index(:chat_tool_bindings, [:chat_id, :alias],
                     name: "chat_tool_bindings_unique_chat_alias_index"
                   )

    delete_duplicate_tool_bindings()

    create unique_index(:bot_tool_bindings, [:bot_id, :tool_instance_id],
             name: "bot_tool_bindings_unique_bot_tool_instance_index"
           )

    create unique_index(:bot_user_tool_bindings, [:owner_id, :bot_id, :tool_instance_id],
             name: "bot_user_tool_bindings_unique_owner_bot_tool_instance_index"
           )

    create unique_index(:chat_tool_bindings, [:chat_id, :tool_instance_id],
             name: "chat_tool_bindings_unique_chat_tool_instance_index"
           )

    alter table(:bot_tool_bindings) do
      remove :alias
    end

    alter table(:bot_user_tool_bindings) do
      remove :alias
    end

    alter table(:chat_tool_bindings) do
      remove :alias
    end
  end

  def down do
    alter table(:bot_tool_bindings) do
      add :alias, :text
    end

    alter table(:bot_user_tool_bindings) do
      add :alias, :text
    end

    alter table(:chat_tool_bindings) do
      add :alias, :text
    end

    flush()

    restore_binding_aliases()

    unless sqlite?() do
      alter table(:bot_tool_bindings) do
        modify :alias, :text, null: false
      end

      alter table(:bot_user_tool_bindings) do
        modify :alias, :text, null: false
      end

      alter table(:chat_tool_bindings) do
        modify :alias, :text, null: false
      end
    end

    drop_if_exists unique_index(:bot_tool_bindings, [:bot_id, :tool_instance_id],
                     name: "bot_tool_bindings_unique_bot_tool_instance_index"
                   )

    drop_if_exists unique_index(:bot_user_tool_bindings, [:owner_id, :bot_id, :tool_instance_id],
                     name: "bot_user_tool_bindings_unique_owner_bot_tool_instance_index"
                   )

    drop_if_exists unique_index(:chat_tool_bindings, [:chat_id, :tool_instance_id],
                     name: "chat_tool_bindings_unique_chat_tool_instance_index"
                   )

    create unique_index(:bot_tool_bindings, [:bot_id, :alias],
             name: "bot_tool_bindings_unique_bot_alias_index"
           )

    create unique_index(:bot_user_tool_bindings, [:owner_id, :bot_id, :alias],
             name: "bot_user_tool_bindings_unique_owner_bot_alias_index"
           )

    create unique_index(:chat_tool_bindings, [:chat_id, :alias],
             name: "chat_tool_bindings_unique_chat_alias_index"
           )

    drop_if_exists unique_index(:tool_instances, [:owner_id, :alias],
                     name: "tool_instances_unique_owner_alias_index"
                   )

    alter table(:tool_instances) do
      remove :alias
    end
  end

  defp backfill_tool_aliases do
    repo = repo()
    bindings_by_tool_id = load_binding_alias_candidates(repo)

    tools =
      repo.all(
        from(t in "tool_instances",
          order_by: [asc: t.id],
          select: %{id: t.id, owner_id: t.owner_id, name: t.name}
        )
      )

    {_seen_by_owner, updates} =
      Enum.reduce(tools, {%{}, []}, fn tool, {seen_by_owner, updates} ->
        owner_id = tool.owner_id
        seen = Map.get(seen_by_owner, owner_id, MapSet.new())

        preferred =
          bindings_by_tool_id
          |> Map.get(tool.id, [])
          |> List.first()
          |> case do
            %{alias: alias_value} -> normalize_existing_alias(alias_value)
            _ -> nil
          end

        base = preferred || generated_alias(tool.name, tool.id)
        alias_value = unique_alias_for_tool(base, tool.id, seen)

        {
          Map.put(seen_by_owner, owner_id, MapSet.put(seen, alias_value)),
          [{tool.id, alias_value} | updates]
        }
      end)

    Enum.each(updates, fn {tool_id, alias_value} ->
      repo.update_all(
        from(t in "tool_instances", where: t.id == ^tool_id),
        set: [alias: alias_value]
      )
    end)
  end

  defp load_binding_alias_candidates(repo) do
    @binding_tables
    |> Enum.flat_map(fn {table_name, priority} ->
      repo.all(
        from(b in table_name,
          where: not is_nil(b.tool_instance_id) and not is_nil(b.alias),
          select: %{
            tool_instance_id: b.tool_instance_id,
            alias: b.alias,
            created_at: b.created_at,
            priority: ^priority,
            id: b.id
          }
        )
      )
    end)
    |> Enum.group_by(& &1.tool_instance_id)
    |> Map.new(fn {tool_instance_id, candidates} ->
      {tool_instance_id, Enum.sort_by(candidates, &candidate_sort_key/1)}
    end)
  end

  defp candidate_sort_key(candidate) do
    created_at = candidate.created_at

    {
      is_nil(created_at),
      if(is_nil(created_at), do: "", else: to_string(created_at)),
      candidate.priority,
      candidate.id
    }
  end

  defp restore_binding_aliases do
    repo = repo()

    for {table_name, _priority} <- @binding_tables do
      bindings =
        repo.all(
          from(b in table_name,
            join: t in "tool_instances",
            on: t.id == b.tool_instance_id,
            select: %{id: b.id, alias: t.alias}
          )
        )

      Enum.each(bindings, fn binding ->
        repo.update_all(
          from(b in table_name, where: b.id == ^binding.id),
          set: [alias: binding.alias]
        )
      end)
    end
  end

  defp delete_duplicate_tool_bindings do
    delete_duplicate_rows("bot_tool_bindings", [:bot_id, :tool_instance_id])
    delete_duplicate_rows("bot_user_tool_bindings", [:owner_id, :bot_id, :tool_instance_id])
    delete_duplicate_rows("chat_tool_bindings", [:chat_id, :tool_instance_id])
  end

  defp delete_duplicate_rows(table_name, key_fields) do
    repo = repo()
    rows = duplicate_candidate_rows(repo, table_name)

    rows
    |> Enum.group_by(fn row -> Enum.map(key_fields, &Map.fetch!(row, &1)) end)
    |> Enum.flat_map(fn {_key, duplicates} ->
      duplicates
      |> Enum.sort_by(fn row -> {row.sequence || 0, row.id} end)
      |> Enum.drop(1)
    end)
    |> Enum.each(fn row ->
      repo.delete_all(from(b in table_name, where: b.id == ^row.id))
    end)
  end

  defp duplicate_candidate_rows(repo, "bot_tool_bindings") do
    repo.all(
      from(b in "bot_tool_bindings",
        select: %{
          id: b.id,
          bot_id: b.bot_id,
          tool_instance_id: b.tool_instance_id,
          sequence: b.sequence
        }
      )
    )
  end

  defp duplicate_candidate_rows(repo, "bot_user_tool_bindings") do
    repo.all(
      from(b in "bot_user_tool_bindings",
        select: %{
          id: b.id,
          owner_id: b.owner_id,
          bot_id: b.bot_id,
          tool_instance_id: b.tool_instance_id,
          sequence: b.sequence
        }
      )
    )
  end

  defp duplicate_candidate_rows(repo, "chat_tool_bindings") do
    repo.all(
      from(b in "chat_tool_bindings",
        select: %{
          id: b.id,
          chat_id: b.chat_id,
          tool_instance_id: b.tool_instance_id,
          sequence: b.sequence
        }
      )
    )
  end

  defp normalize_existing_alias(value) do
    value = value |> to_string() |> String.trim()

    if valid_alias?(value), do: value, else: nil
  end

  defp generated_alias(name, tool_id) do
    base =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_-")
      |> String.slice(0, @max_alias_length)

    if Regex.match?(~r/^[a-z]/, base), do: base, else: "tool_#{tool_id}"
  end

  defp unique_alias_for_tool(base, tool_id, seen) do
    base = if valid_alias?(base), do: base, else: "tool_#{tool_id}"

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate =
        case index do
          0 -> base
          n -> with_suffix(base, "_#{tool_id + n - 1}")
        end

      if MapSet.member?(seen, candidate), do: nil, else: candidate
    end)
  end

  defp with_suffix(base, suffix) do
    suffix_length = String.length(suffix)

    base
    |> String.slice(0, @max_alias_length - suffix_length)
    |> Kernel.<>(suffix)
  end

  defp valid_alias?(value) do
    is_binary(value) and
      String.length(value) <= @max_alias_length and
      not String.contains?(value, "__") and
      Regex.match?(~r/^[A-Za-z][A-Za-z0-9_-]*$/, value)
  end

  defp sqlite? do
    repo().__adapter__() == Ecto.Adapters.SQLite3
  end
end
