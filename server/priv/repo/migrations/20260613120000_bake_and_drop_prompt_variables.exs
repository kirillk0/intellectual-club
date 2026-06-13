defmodule IntellectualClub.Repo.Migrations.BakeAndDropPromptVariables do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  @comment_prefix "//// "
  @placeholder_regex ~r/\{\{\s*(.+?)\s*\}\}/

  def up do
    bake_knowledge_block_variables()

    alter table(:knowledge_blocks) do
      remove :variables, :map
    end

    alter table(:bots) do
      remove :variables, :map
    end

    alter table(:chats) do
      remove :variables, :map
    end
  end

  def down do
    alter table(:knowledge_blocks) do
      add :variables, :map, null: false, default: %{}
    end

    alter table(:bots) do
      add :variables, :map, null: false, default: %{}
    end

    alter table(:chats) do
      add :variables, :map, null: false, default: %{}
    end
  end

  defp bake_knowledge_block_variables do
    repo = repo()

    blocks =
      repo.all(
        from(b in "knowledge_blocks",
          select: %{id: b.id, content: b.content, variables: b.variables}
        )
      )

    Enum.each(blocks, fn block ->
      content = bake_content(block.content, block.variables)
      token_count = estimate_token_count(content)

      repo.update_all(
        from(b in "knowledge_blocks", where: b.id == ^block.id),
        set: [content: content, token_count: token_count]
      )
    end)
  end

  defp bake_content(content, raw_variables) do
    content = to_string(content || "")
    variables = normalize_variables(raw_variables)

    Regex.replace(@placeholder_regex, content, fn match, key ->
      key = String.trim(key)

      if Map.has_key?(variables, key) do
        Map.fetch!(variables, key)
      else
        match
      end
    end)
  end

  defp normalize_variables(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> normalize_variables(decoded)
      {:error, _error} -> %{}
    end
  end

  defp normalize_variables(raw) when is_map(raw) do
    Enum.reduce(raw, %{}, fn {key, value}, acc ->
      put_variable(acc, key, value)
    end)
  end

  defp normalize_variables(raw) when is_list(raw) do
    Enum.reduce(raw, %{}, fn
      %{"key" => key, "value" => value}, acc -> put_variable(acc, key, value)
      %{key: key, value: value}, acc -> put_variable(acc, key, value)
      _, acc -> acc
    end)
  end

  defp normalize_variables(_raw), do: %{}

  defp put_variable(acc, key, value) do
    key = key |> to_string_or_empty() |> String.trim()

    if key == "" do
      acc
    else
      Map.put(acc, key, normalize_variable_value(value))
    end
  end

  defp normalize_variable_value(nil), do: ""
  defp normalize_variable_value(value) when is_binary(value), do: value

  defp normalize_variable_value(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _error} -> inspect(value)
    end
  end

  defp normalize_variable_value(value), do: to_string_or_empty(value)

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value) when is_binary(value), do: value

  defp to_string_or_empty(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> inspect(value)
  end

  defp estimate_token_count(content) do
    content
    |> strip_comments()
    |> byte_size()
    |> Kernel./(3.5)
    |> ceil()
  end

  defp strip_comments(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.reject(&String.starts_with?(&1, @comment_prefix))
    |> Enum.join("\n")
  end
end
