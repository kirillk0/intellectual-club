defmodule IntellectualClub.Knowledge.MarkdownTransfer do
  @moduledoc """
  Imports and exports knowledge blocks as Markdown files.
  """

  alias IntellectualClub.Knowledge.{KnowledgeBlock, KnowledgeBlockTag, KnowledgeTag, TagTree}

  require Ash.Query

  @markdown_extensions [".md", ".markdown"]
  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
  @filename_external_id_pattern ~r/\s+\[([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]\s*$/
  @unsafe_filename_pattern ~r/[\x00-\x1F\x7F\/\\:\*\?"<>\|]/u

  @type import_decisions :: %{optional(String.t()) => String.t()}

  @spec export_archive(integer(), [integer()], term()) ::
          {:ok, %{filename: String.t(), payload: binary(), count: non_neg_integer()}}
          | {:error, String.t()}
  def export_archive(tag_id, block_ids, actor) when is_integer(tag_id) and is_list(block_ids) do
    block_ids = normalize_integer_ids(block_ids)

    with {:ok, tag} <- get_tag(tag_id, actor),
         {:ok, blocks} <- export_blocks(tag.id, block_ids, actor),
         :ok <- require_non_empty(blocks, "No exportable blocks selected."),
         {:ok, payload} <- zip_blocks(blocks) do
      {:ok,
       %{
         filename: archive_filename(tag),
         payload: payload,
         count: length(blocks)
       }}
    end
  end

  def export_archive(_tag_id, _block_ids, _actor), do: {:error, "Tag is required."}

  @spec preview_import(integer(), [Plug.Upload.t()] | Plug.Upload.t(), term()) ::
          {:ok, %{items: [map()]}} | {:error, String.t()}
  def preview_import(tag_id, uploads, actor) when is_integer(tag_id) do
    with {:ok, _tag} <- get_tag(tag_id, actor),
         {:ok, entries} <- extract_import_entries(uploads),
         :ok <- require_non_empty(entries, "No Markdown files found."),
         {:ok, items} <- build_import_items(entries, actor) do
      {:ok, %{items: Enum.map(items, &serialize_preview_item/1)}}
    end
  end

  def preview_import(_tag_id, _uploads, _actor), do: {:error, "Tag is required."}

  @spec import_entries(
          integer(),
          [Plug.Upload.t()] | Plug.Upload.t(),
          String.t() | nil,
          import_decisions(),
          term()
        ) ::
          {:ok, map()} | {:error, String.t()}
  def import_entries(tag_id, uploads, version, decisions, actor) when is_integer(tag_id) do
    with {:ok, tag} <- get_tag(tag_id, actor),
         {:ok, entries} <- extract_import_entries(uploads),
         :ok <- require_non_empty(entries, "No Markdown files found."),
         {:ok, items} <- build_import_items(entries, actor) do
      apply_import_items(
        items,
        tag,
        normalize_import_version(version),
        normalize_decisions(decisions),
        actor
      )
    end
  end

  def import_entries(_tag_id, _uploads, _version, _decisions, _actor),
    do: {:error, "Tag is required."}

  @spec sanitize_filename(String.t(), String.t()) :: String.t()
  def sanitize_filename(value, fallback) do
    value
    |> to_string()
    |> String.replace(@unsafe_filename_pattern, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.trim(" .")
    |> case do
      "" -> fallback
      sanitized -> sanitized
    end
  end

  defp get_tag(tag_id, actor) do
    case Ash.get(KnowledgeTag, tag_id, actor: actor) do
      {:ok, %KnowledgeTag{} = tag} -> {:ok, tag}
      {:error, _error} -> {:error, "Tag not found."}
    end
  end

  defp export_blocks(_tag_id, [], _actor), do: {:ok, []}

  defp export_blocks(tag_id, block_ids, actor) do
    tag_ids = TagTree.subtree_ids(tag_id, actor: actor, authorize?: true)

    blocks =
      KnowledgeBlock
      |> Ash.Query.filter(id in ^block_ids and exists(tags, id in ^tag_ids))
      |> Ash.Query.select([:id, :name, :external_id, :content])
      |> Ash.read!(actor: actor)

    by_id = Map.new(blocks, &{&1.id, &1})
    ordered = block_ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)

    {:ok, ordered}
  rescue
    _error -> {:error, "Failed to load export blocks."}
  end

  defp zip_blocks(blocks) do
    {files, _used} =
      Enum.map_reduce(blocks, MapSet.new(), fn block, used ->
        base_name =
          block.name
          |> sanitize_filename("Knowledge Block")
          |> then(&"#{&1} [#{block.external_id}].md")

        {filename, used} = unique_filename(base_name, used)

        {{String.to_charlist(filename), block.content || ""}, used}
      end)

    case :zip.create(~c"knowledge-blocks.zip", files, [:memory]) do
      {:ok, {_zip_name, payload}} -> {:ok, payload}
      {:error, reason} -> {:error, "Failed to create ZIP archive: #{inspect(reason)}"}
    end
  end

  defp archive_filename(%KnowledgeTag{} = tag) do
    label =
      [tag.full_name, tag.name]
      |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
      |> Kernel.||("Knowledge Blocks")

    "#{sanitize_filename(label, "Knowledge Blocks")}.zip"
  end

  defp unique_filename(filename, used) do
    root = Path.rootname(filename)
    ext = Path.extname(filename)

    1
    |> Stream.iterate(&(&1 + 1))
    |> Enum.reduce_while(nil, fn index, _acc ->
      candidate = if index == 1, do: filename, else: "#{root} (#{index})#{ext}"

      if MapSet.member?(used, candidate) do
        {:cont, nil}
      else
        {:halt, {candidate, MapSet.put(used, candidate)}}
      end
    end)
  end

  defp extract_import_entries(uploads) do
    uploads
    |> normalize_uploads()
    |> Enum.reduce_while({:ok, []}, fn upload, {:ok, acc} ->
      case extract_upload_entries(upload) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, entries} ->
        keyed =
          entries
          |> Enum.with_index()
          |> Enum.map(fn {entry, index} -> Map.put(entry, :key, Integer.to_string(index)) end)

        {:ok, keyed}

      {:error, message} ->
        {:error, message}
    end
  end

  defp normalize_uploads(nil), do: []
  defp normalize_uploads(%Plug.Upload{} = upload), do: [upload]

  defp normalize_uploads(uploads) when is_list(uploads),
    do: Enum.filter(uploads, &match?(%Plug.Upload{}, &1))

  defp normalize_uploads(_other), do: []

  defp extract_upload_entries(%Plug.Upload{} = upload) do
    case upload_extension(upload.filename) do
      ".zip" -> extract_zip_entries(upload)
      extension when extension in @markdown_extensions -> extract_markdown_upload(upload)
      _other -> {:ok, []}
    end
  end

  defp extract_markdown_upload(%Plug.Upload{} = upload) do
    with {:ok, payload} <- File.read(upload.path),
         :ok <- validate_markdown_payload(upload.filename, payload) do
      {:ok, [%{filename: Path.basename(upload.filename), content: payload}]}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "Failed to read #{inspect(upload.filename)}: #{inspect(reason)}"}
    end
  end

  defp extract_zip_entries(%Plug.Upload{} = upload) do
    case :zip.extract(String.to_charlist(upload.path), [:memory]) do
      {:ok, files} ->
        files
        |> Enum.reduce_while({:ok, []}, fn {zip_path, payload}, {:ok, acc} ->
          filename = zip_path |> to_string() |> Path.basename()

          cond do
            zip_directory?(zip_path) ->
              {:cont, {:ok, acc}}

            upload_extension(filename) not in @markdown_extensions ->
              {:cont, {:ok, acc}}

            true ->
              case validate_markdown_payload(filename, payload) do
                :ok -> {:cont, {:ok, acc ++ [%{filename: filename, content: payload}]}}
                {:error, message} -> {:halt, {:error, message}}
              end
          end
        end)

      {:error, reason} ->
        {:error, "Failed to read ZIP archive #{inspect(upload.filename)}: #{inspect(reason)}"}
    end
  end

  defp zip_directory?(zip_path) do
    zip_path
    |> to_string()
    |> String.ends_with?("/")
  end

  defp upload_extension(filename) do
    filename
    |> to_string()
    |> Path.extname()
    |> String.downcase()
  end

  defp validate_markdown_payload(filename, payload) when is_binary(payload) do
    if String.valid?(payload) do
      :ok
    else
      {:error, "Markdown file #{inspect(filename)} is not valid UTF-8."}
    end
  end

  defp validate_markdown_payload(filename, _payload) do
    {:error, "Markdown file #{inspect(filename)} could not be read."}
  end

  defp build_import_items(entries, actor) do
    parsed_entries = Enum.map(entries, &parse_import_entry/1)
    existing_by_external_id = existing_blocks_by_external_id(parsed_entries, actor)

    items =
      Enum.map(parsed_entries, fn entry ->
        existing =
          if entry.external_id do
            Map.get(existing_by_external_id, entry.external_id)
          else
            nil
          end

        actions =
          if existing do
            ["update", "create_new", "skip"]
          else
            ["import", "skip"]
          end

        default_action = if existing, do: "update", else: "import"

        entry
        |> Map.put(:existing_block, existing)
        |> Map.put(:available_actions, actions)
        |> Map.put(:default_action, default_action)
      end)

    {:ok, items}
  end

  defp parse_import_entry(%{filename: filename, content: content, key: key}) do
    root =
      filename
      |> Path.basename()
      |> Path.rootname()
      |> String.trim()

    {name, external_id} =
      case Regex.run(@filename_external_id_pattern, root, capture: :all_but_first) do
        [external_id] ->
          name =
            root
            |> String.replace(@filename_external_id_pattern, "")
            |> String.trim()

          {fallback_name(name), String.downcase(external_id)}

        _other ->
          {fallback_name(root), nil}
      end

    %{
      key: key,
      filename: filename,
      name: name,
      external_id: external_id,
      content: content
    }
  end

  defp fallback_name(name) do
    case String.trim(to_string(name)) do
      "" -> "Imported block"
      value -> value
    end
  end

  defp existing_blocks_by_external_id(entries, actor) do
    external_ids =
      entries
      |> Enum.map(& &1.external_id)
      |> Enum.filter(&valid_uuid?/1)
      |> Enum.uniq()

    if external_ids == [] do
      %{}
    else
      KnowledgeBlock
      |> Ash.Query.filter(owner_id == ^actor.id and external_id in ^external_ids)
      |> Ash.Query.select([:id, :external_id, :name, :version])
      |> Ash.read!(actor: actor)
      |> Map.new(&{String.downcase(to_string(&1.external_id)), &1})
    end
  end

  defp apply_import_items(items, tag, version, decisions, actor) do
    Enum.reduce_while(items, {:ok, empty_summary()}, fn item, {:ok, summary} ->
      action = normalize_action(Map.get(decisions, item.key, item.default_action))

      if action in item.available_actions do
        case apply_import_item(item, action, tag, version, actor) do
          {:ok, result} -> {:cont, {:ok, add_summary_item(summary, result)}}
          {:error, message} -> {:halt, {:error, message}}
        end
      else
        {:halt, {:error, "Invalid import action for #{inspect(item.filename)}."}}
      end
    end)
  end

  defp apply_import_item(item, "skip", _tag, _version, _actor) do
    {:ok,
     %{
       key: item.key,
       filename: item.filename,
       action: "skip",
       status: "skipped",
       external_id: item.external_id
     }}
  end

  defp apply_import_item(item, "import", tag, version, actor) do
    attrs =
      %{
        name: item.name,
        content: item.content,
        tag_bindings: [%{knowledge_tag_id: tag.id}]
      }
      |> maybe_put(:external_id, item.external_id)
      |> maybe_put(:version, version)

    create_block(item, attrs, "import", actor)
  end

  defp apply_import_item(item, "create_new", tag, version, actor) do
    attrs =
      %{
        name: item.name,
        content: item.content,
        tag_bindings: [%{knowledge_tag_id: tag.id}]
      }
      |> maybe_put(:version, version)

    create_block(item, attrs, "create_new", actor)
  end

  defp apply_import_item(item, "update", tag, version, actor) do
    with %KnowledgeBlock{} = block <- item.existing_block,
         attrs <- %{name: item.name, content: item.content} |> maybe_put(:version, version),
         {:ok, updated} <-
           block
           |> Ash.Changeset.for_update(:update, attrs, actor: actor)
           |> Ash.update(actor: actor),
         :ok <- ensure_tag_binding(updated.id, tag.id, actor) do
      {:ok,
       %{
         key: item.key,
         filename: item.filename,
         action: "update",
         status: "updated",
         block_id: updated.id,
         external_id: updated.external_id
       }}
    else
      nil ->
        {:error, "No matching block found for #{inspect(item.filename)}."}

      {:error, error} ->
        {:error, "Failed to update #{inspect(item.filename)}: #{error_message(error)}"}
    end
  end

  defp create_block(item, attrs, action, actor) do
    case KnowledgeBlock
         |> Ash.Changeset.for_create(:import_markdown, attrs, actor: actor)
         |> Ash.create(actor: actor) do
      {:ok, block} ->
        {:ok,
         %{
           key: item.key,
           filename: item.filename,
           action: action,
           status: "created",
           block_id: block.id,
           external_id: block.external_id
         }}

      {:error, error} ->
        {:error, "Failed to import #{inspect(item.filename)}: #{error_message(error)}"}
    end
  end

  defp ensure_tag_binding(block_id, tag_id, actor) do
    existing =
      KnowledgeBlockTag
      |> Ash.Query.filter(knowledge_block_id == ^block_id and knowledge_tag_id == ^tag_id)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: actor)

    if existing == [] do
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block_id, knowledge_tag_id: tag_id},
        actor: actor
      )
      |> Ash.create(actor: actor)
      |> case do
        {:ok, _binding} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      :ok
    end
  end

  defp serialize_preview_item(item) do
    %{
      key: item.key,
      filename: item.filename,
      name: item.name,
      external_id: item.external_id,
      existing_block: serialize_existing_block(item.existing_block),
      available_actions: item.available_actions,
      default_action: item.default_action
    }
  end

  defp serialize_existing_block(nil), do: nil

  defp serialize_existing_block(%KnowledgeBlock{} = block) do
    %{
      id: block.id,
      external_id: block.external_id,
      name: block.name,
      version: block.version
    }
  end

  defp empty_summary do
    %{imported: 0, updated: 0, created: 0, skipped: 0, items: []}
  end

  defp add_summary_item(summary, %{status: "skipped"} = item) do
    summary
    |> Map.update!(:skipped, &(&1 + 1))
    |> Map.update!(:items, &(&1 ++ [item]))
  end

  defp add_summary_item(summary, %{status: "updated"} = item) do
    summary
    |> Map.update!(:imported, &(&1 + 1))
    |> Map.update!(:updated, &(&1 + 1))
    |> Map.update!(:items, &(&1 ++ [item]))
  end

  defp add_summary_item(summary, %{status: "created"} = item) do
    summary
    |> Map.update!(:imported, &(&1 + 1))
    |> Map.update!(:created, &(&1 + 1))
    |> Map.update!(:items, &(&1 ++ [item]))
  end

  defp normalize_import_version(nil), do: nil

  defp normalize_import_version(version) when is_binary(version) do
    case String.trim(version) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_import_version(version), do: normalize_import_version(to_string(version))

  defp normalize_decisions(decisions) when is_map(decisions) do
    Map.new(decisions, fn {key, value} -> {to_string(key), normalize_action(value)} end)
  end

  defp normalize_decisions(_decisions), do: %{}

  defp normalize_action(action) when is_binary(action) do
    action
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_action(_action), do: ""

  defp normalize_integer_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(fn
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp valid_uuid?(value) when is_binary(value), do: Regex.match?(@uuid_pattern, value)
  defp valid_uuid?(_value), do: false

  defp require_non_empty([], message), do: {:error, message}
  defp require_non_empty(_items, _message), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)
end
