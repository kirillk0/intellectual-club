defmodule IntellectualClub.Tools.Drivers.NativeKnowledgeLibrary do
  @moduledoc """
  Native knowledge library driver.

  The driver exposes knowledge blocks from one owner-selected knowledge tag
  through fixed read and search functions. Shared recipients execute the tool
  through the tool instance owner authority instead of gaining direct block
  access.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeTag
  alias IntellectualClub.Knowledge.PromptContent
  alias IntellectualClub.Knowledge.TagTree
  alias IntellectualClub.Tools.DocumentReader
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @default_max_context_blocks 40
  @default_list_max_results 50

  @impl true
  def type, do: "native-knowledge-library"

  @impl true
  def title, do: "Knowledge Library"

  @impl true
  def description do
    "Expose knowledge blocks from a selected tag as a paged library with regex search."
  end

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def supports_artifacts?, do: false

  @impl true
  def default_config do
    %{
      "chunk_size_tokens" => DocumentReader.default_chunk_size_tokens(),
      "cache_ttl_seconds" => DocumentReader.default_cache_ttl_seconds(),
      "cache_max_bytes" => DocumentReader.default_cache_max_bytes(),
      "max_context_blocks" => @default_max_context_blocks
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "knowledge_tag_id" => %{
          "type" => "integer",
          "title" => "Knowledge block tag",
          "description" => "Knowledge tag whose block subtree is exposed through this tool.",
          "minimum" => 1,
          "x-ui" => %{"widget" => "knowledge-tag-select", "order" => 0}
        },
        "chunk_size_tokens" => %{
          "type" => "integer",
          "title" => "Chunk size (tokens)",
          "description" => "Approximate token count per cached block page.",
          "minimum" => 1
        },
        "cache_ttl_seconds" => %{
          "type" => "integer",
          "title" => "Cache TTL (seconds)",
          "description" => "How long cached block pages stay fresh.",
          "minimum" => 0
        },
        "cache_max_bytes" => %{
          "type" => "integer",
          "title" => "Cache max bytes",
          "description" => "Maximum cache size in bytes for this tool instance.",
          "minimum" => 0
        },
        "max_context_blocks" => %{
          "type" => "integer",
          "title" => "Max context blocks",
          "description" => "Maximum block names listed in the model-visible instance context.",
          "minimum" => 0
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema, do: nil

  @spec available_file_external_ids(ToolInstance.t()) :: [String.t()]
  def available_file_external_ids(%ToolInstance{} = tool_instance) do
    cfg = config_from_tool(tool_instance)

    with {:ok, tag_id} <- configured_tag_id(cfg),
         owner_actor <- owner_actor(tool_instance, nil),
         {:ok, _tag} <- fetch_tag(tag_id, owner_actor),
         {:ok, blocks} <- list_collection_blocks(tag_id, owner_actor) do
      blocks
      |> Enum.flat_map(&block_attachments_raw/1)
      |> Enum.map(&Map.get(&1, "file_id"))
      |> Enum.reject(&(to_string(&1 || "") == ""))
      |> Enum.uniq()
    else
      _other -> []
    end
  end

  def available_file_external_ids(_tool_instance), do: []

  @impl true
  def normalize_config(config) when is_map(config) do
    config
    |> normalize_map()
    |> normalize_optional_integer("knowledge_tag_id")
    |> normalize_positive_integer("chunk_size_tokens", DocumentReader.default_chunk_size_tokens())
    |> normalize_non_negative_integer(
      "cache_ttl_seconds",
      DocumentReader.default_cache_ttl_seconds()
    )
    |> normalize_non_negative_integer("cache_max_bytes", DocumentReader.default_cache_max_bytes())
    |> normalize_non_negative_integer("max_context_blocks", @default_max_context_blocks)
  end

  def normalize_config(_config), do: default_config()

  @impl true
  def validate_config(%ToolInstance{} = tool_instance, config, actor) when is_map(config) do
    case parse_optional_positive_integer(Map.get(config, "knowledge_tag_id")) do
      {:ok, nil} ->
        :ok

      {:ok, tag_id} ->
        owner_actor = owner_actor(tool_instance, actor)

        case Ash.get(KnowledgeTag, tag_id, actor: owner_actor) do
          {:ok, %KnowledgeTag{}} ->
            :ok

          _other ->
            {:error, "Knowledge tag is not available."}
        end

      {:error, _reason} ->
        {:error, "Knowledge tag must be a positive integer."}
    end
  end

  @impl true
  def fixed_functions(%ToolInstance{} = _tool_instance) do
    [
      %{
        "name" => "list_blocks",
        "description" =>
          "List knowledge blocks available in this library. Use q to filter by block name or version.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "q" => %{
              "type" => "string",
              "description" => "Optional case-insensitive filter for block name or version."
            },
            "max_results" => %{
              "type" => "integer",
              "minimum" => 0,
              "default" => @default_list_max_results,
              "description" => "Maximum number of blocks to return."
            }
          },
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "read_block",
        "description" =>
          "Read a knowledge block by block_id or exact block_name and return one cached page.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "block_id" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" => "Knowledge block id from list_blocks output."
            },
            "block_name" => %{
              "type" => "string",
              "description" =>
                "Exact knowledge block name. If names are duplicated, use block_id."
            },
            "page" => %{
              "type" => "integer",
              "minimum" => 0,
              "default" => 1,
              "description" =>
                "1-based page number to return. If omitted, returns page 1. Page 0 is accepted as page 1."
            }
          },
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "search_blocks",
        "description" =>
          "Search all knowledge block pages in this library and return snippets with block ids and page numbers.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "regex" => %{
              "type" => "string",
              "description" => "Regular expression to search across block pages."
            },
            "regex_flags" => %{
              "type" => "string",
              "description" => "Regex flags. Supported: i, m, s.",
              "default" => "im"
            },
            "snippet_len_chars" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" => "Target snippet length in characters.",
              "default" => 240
            },
            "max_snippets" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Maximum number of snippets to return.",
              "default" => 25
            }
          },
          "required" => ["regex"],
          "additionalProperties" => false
        },
        "enabled" => true
      }
    ]
  end

  @impl true
  def instance_prompt_context(%ToolInstance{} = tool_instance) do
    cfg = config_from_tool(tool_instance)

    with {:ok, tag_id} <- configured_tag_id(cfg),
         owner_actor <- owner_actor(tool_instance, nil),
         {:ok, tag} <- fetch_tag(tag_id, owner_actor),
         {:ok, blocks} <- list_collection_blocks(tag_id, owner_actor) do
      total = length(blocks)
      visible = Enum.take(blocks, cfg.max_context_blocks)

      block_lines =
        visible
        |> Enum.map(fn block ->
          version = block.version |> to_string() |> String.trim()
          suffix = if version == "", do: "", else: " (#{version})"
          "- #{block.name}#{suffix}"
        end)

      [
        "Knowledge tag: #{tag_display_name(tag)}",
        "Available knowledge blocks: #{total}",
        if(block_lines == [], do: "No blocks are available.", else: Enum.join(block_lines, "\n")),
        if(total > length(visible),
          do: "The list is truncated. Use `list_blocks` to inspect the full library.",
          else: ""
        )
      ]
      |> Enum.reject(&(String.trim(to_string(&1)) == ""))
      |> Enum.join("\n")
    else
      {:error, :missing_tag} ->
        "Knowledge library is not configured with a knowledge tag."

      {:error, _reason} ->
        "Configured knowledge library tag is not available."
    end
  end

  @impl true
  def discover(%ToolInstance{} = _tool_instance) do
    {:error, "Discovery is not supported for this tool type."}
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, function_name, args, _execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    case function_name do
      "list_blocks" -> list_blocks(tool_instance, args || %{})
      "read_block" -> read_block(tool_instance, args || %{})
      "search_blocks" -> search_blocks(tool_instance, args || %{})
      _other -> {:error, "Unknown function: #{function_name}"}
    end
  end

  defp list_blocks(%ToolInstance{} = tool_instance, args) when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, tag_id} <- configured_tag_id(cfg),
         owner_actor <- owner_actor(tool_instance, nil),
         {:ok, tag} <- fetch_tag(tag_id, owner_actor),
         {:ok, blocks} <- list_collection_blocks(tag_id, owner_actor),
         {:ok, max_results} <- parse_max_results(args) do
      q = read_string_arg(args, "q", "")

      filtered =
        blocks
        |> filter_blocks(q)

      returned = Enum.take(filtered, max_results)

      block_lines =
        Enum.map(returned, fn block ->
          "- #{format_block_ref(block)}"
        end)

      text =
        [
          "Knowledge tag: #{tag_display_name(tag)}",
          "Total blocks: #{length(filtered)}",
          "Returned blocks: #{length(returned)}",
          if(q == "", do: "", else: "Filter: #{q}"),
          "",
          "---",
          "",
          Enum.join(block_lines, "\n")
        ]
        |> Enum.join("\n")
        |> String.trim()
        |> Kernel.<>("\n")

      raw = %{
        "knowledge_tag_id" => tag.id,
        "knowledge_tag_name" => tag_display_name(tag),
        "q" => q,
        "total_blocks" => length(filtered),
        "returned_blocks" => length(returned),
        "blocks" => Enum.map(returned, &block_raw/1)
      }

      {:ok, {text, raw}}
    end
  end

  defp read_block(%ToolInstance{} = tool_instance, args) when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, tag_id} <- configured_tag_id(cfg),
         owner_actor <- owner_actor(tool_instance, nil),
         {:ok, _tag} <- fetch_tag(tag_id, owner_actor),
         {:ok, blocks} <- list_collection_blocks(tag_id, owner_actor),
         {:ok, block} <- resolve_block(blocks, args),
         {:ok, page} <- DocumentReader.parse_page(args),
         {:ok, {doc_dir, meta, cached}} <- ensure_block_cache_ready(tool_instance, block, cfg) do
      total_pages = DocumentReader.pages_total(doc_dir, meta)
      used_page = page || 1

      cond do
        total_pages <= 0 ->
          attachment_section = block_attachment_section(block)

          text =
            [
              "Knowledge block: #{block.name} (id: #{block.id})",
              "Cached: #{if(cached, do: "true", else: "false")}",
              "Error: block has no readable content.",
              attachment_section
            ]
            |> Enum.join("\n")
            |> String.trim()
            |> Kernel.<>("\n")

          {:ok,
           {text,
            %{
              "block_id" => block.id,
              "cached" => cached,
              "page" => used_page,
              "pages_total" => total_pages,
              "attachments" => block_attachments_raw(block)
            }}}

        used_page < 1 or used_page > total_pages ->
          {:error, "Page out of range: #{used_page} (total pages: #{total_pages})"}

        true ->
          case DocumentReader.read_page_text(doc_dir, used_page) do
            {:ok, page_text} ->
              attachment_section = block_attachment_section(block)

              text =
                [
                  "Knowledge block: #{format_block_ref(block)}",
                  "Cached: #{if(cached, do: "true", else: "false")}",
                  "Page: #{used_page} / #{total_pages}",
                  "",
                  "---",
                  "",
                  String.trim(page_text),
                  attachment_section
                ]
                |> Enum.join("\n")
                |> String.trim()
                |> Kernel.<>("\n")

              raw =
                block_raw(block)
                |> Map.merge(%{
                  "doc_id" => Path.basename(doc_dir),
                  "cached" => cached,
                  "page" => used_page,
                  "pages_total" => total_pages,
                  "attachments" => block_attachments_raw(block),
                  "config" => config_raw(cfg)
                })

              {:ok, {text, raw}}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp search_blocks(%ToolInstance{} = tool_instance, args) when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, tag_id} <- configured_tag_id(cfg),
         owner_actor <- owner_actor(tool_instance, nil),
         {:ok, tag} <- fetch_tag(tag_id, owner_actor),
         {:ok, blocks} <- list_collection_blocks(tag_id, owner_actor),
         {:ok, regex_text} <- DocumentReader.required_regex(args),
         {:ok, regex} <-
           DocumentReader.compile_regex(
             regex_text,
             DocumentReader.read_string_arg(args, "regex_flags", "im")
           ),
         {:ok, snippet_len_chars} <- DocumentReader.parse_snippet_len(args),
         {:ok, max_snippets} <- DocumentReader.parse_max_snippets(args) do
      regex_flags = DocumentReader.read_string_arg(args, "regex_flags", "im")

      {snippets, searched_count} =
        collect_block_snippets(tool_instance, blocks, cfg, regex, snippet_len_chars, max_snippets)

      body_lines =
        Enum.map(snippets, fn item ->
          "Block #{item.block_id} #{item.block_name}, page #{item.page}: #{item.snippet}"
        end)

      text =
        [
          "Knowledge tag: #{tag_display_name(tag)}",
          "Blocks searched: #{searched_count}",
          "Regex: /#{regex_text}/",
          if(snippets == [], do: "Matches: none", else: "Matches: #{length(snippets)}"),
          "",
          "---",
          "",
          Enum.join(body_lines, "\n")
        ]
        |> Enum.join("\n")
        |> String.trim()
        |> Kernel.<>("\n")

      raw = %{
        "knowledge_tag_id" => tag.id,
        "knowledge_tag_name" => tag_display_name(tag),
        "blocks_searched" => searched_count,
        "regex" => regex_text,
        "regex_flags" => regex_flags,
        "snippets" =>
          Enum.map(snippets, fn item ->
            %{
              "block_id" => item.block_id,
              "block_name" => item.block_name,
              "page" => item.page,
              "snippet" => item.snippet
            }
          end),
        "snippet_len_chars" => snippet_len_chars,
        "max_snippets" => max_snippets,
        "config" => config_raw(cfg)
      }

      {:ok, {text, raw}}
    end
  end

  defp configured_tag_id(%{} = cfg) do
    case parse_optional_positive_integer(Map.get(cfg, "knowledge_tag_id")) do
      {:ok, nil} -> {:error, :missing_tag}
      {:ok, tag_id} -> {:ok, tag_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_tag(tag_id, actor) when is_integer(tag_id) do
    case Ash.get(KnowledgeTag, tag_id, actor: actor) do
      {:ok, %KnowledgeTag{} = tag} -> {:ok, tag}
      _other -> {:error, :tag_not_found}
    end
  end

  defp list_collection_blocks(tag_id, actor) when is_integer(tag_id) do
    tag_ids = TagTree.subtree_ids(tag_id, actor: actor)

    if tag_ids == [] do
      {:error, :tag_not_found}
    else
      blocks =
        KnowledgeBlock
        |> Ash.Query.filter(exists(tags, id in ^tag_ids))
        |> Ash.Query.sort(name: :asc, id: :asc)
        |> Ash.Query.load(block_file_bindings_load(), strict?: true)
        |> Ash.read!(actor: actor)

      {:ok, blocks}
    end
  end

  defp resolve_block(blocks, args) when is_list(blocks) and is_map(args) do
    case parse_optional_positive_integer(map_get(args, "block_id")) do
      {:ok, nil} ->
        resolve_block_by_name(blocks, args)

      {:ok, block_id} ->
        case block_by_id(blocks, block_id) do
          nil -> {:error, "Block is not available in this knowledge library."}
          block -> {:ok, block}
        end

      {:error, _reason} ->
        {:error, "Argument `block_id` must be a positive integer."}
    end
  end

  defp resolve_block_by_name(blocks, args) do
    name =
      args
      |> map_get("block_name")
      |> to_string()
      |> String.trim()

    if name == "" do
      {:error, "Argument `block_id` or `block_name` is required."}
    else
      matches =
        Enum.filter(blocks, fn block ->
          String.trim(to_string(block.name || "")) == name
        end)

      case matches do
        [block] ->
          {:ok, block}

        [] ->
          {:error, "Block is not available in this knowledge library."}

        _many ->
          {:error, "Multiple blocks have this name. Use `block_id` from list_blocks."}
      end
    end
  end

  defp block_by_id(_blocks, nil), do: nil
  defp block_by_id(blocks, block_id), do: Enum.find(blocks, &(&1.id == block_id))

  defp collect_block_snippets(_tool_instance, _blocks, _cfg, _regex, _snippet_len_chars, 0) do
    {[], 0}
  end

  defp collect_block_snippets(tool_instance, blocks, cfg, regex, snippet_len_chars, max_snippets) do
    {matches, searched_count} =
      collect_first_block_matches(
        tool_instance,
        blocks,
        cfg,
        regex,
        snippet_len_chars,
        max_snippets
      )

    first_snippets = Enum.map(matches, & &1.first_snippet)
    remaining = max_snippets - length(first_snippets)

    snippets =
      if remaining > 0 do
        first_snippets ++
          collect_additional_block_snippets(
            matches,
            regex,
            snippet_len_chars,
            max_snippets,
            remaining
          )
      else
        first_snippets
      end

    {snippets, searched_count}
  end

  defp collect_first_block_matches(
         tool_instance,
         blocks,
         cfg,
         regex,
         snippet_len_chars,
         max_snippets
       ) do
    Enum.reduce_while(blocks, {[], 0}, fn block, {matches, searched_count} ->
      if length(matches) >= max_snippets do
        {:halt, {matches, searched_count}}
      else
        searched_count = searched_count + 1

        case ensure_block_cache_ready(tool_instance, block, cfg) do
          {:ok, {doc_dir, meta, _cached}} ->
            total_pages = DocumentReader.pages_total(doc_dir, meta)

            {block_snippets, _match_pages} =
              DocumentReader.collect_snippets(doc_dir, total_pages, regex, snippet_len_chars, 1)

            case block_snippets do
              [first_snippet | _rest] ->
                match = %{
                  block: block,
                  doc_dir: doc_dir,
                  total_pages: total_pages,
                  first_snippet: block_snippet(block, first_snippet)
                }

                {:cont, {matches ++ [match], searched_count}}

              [] ->
                {:cont, {matches, searched_count}}
            end

          {:error, _reason} ->
            {:cont, {matches, searched_count}}
        end
      end
    end)
  end

  defp collect_additional_block_snippets(
         matches,
         regex,
         snippet_len_chars,
         max_snippets,
         remaining
       ) do
    matches
    |> Enum.map(fn match ->
      {block_snippets, _match_pages} =
        DocumentReader.collect_snippets(
          match.doc_dir,
          match.total_pages,
          regex,
          snippet_len_chars,
          max_snippets
        )

      block_snippets
      |> Enum.drop(1)
      |> Enum.map(&block_snippet(match.block, &1))
    end)
    |> round_robin_snippets(remaining)
  end

  defp round_robin_snippets(snippet_groups, remaining) do
    snippet_groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, group_index} ->
      group
      |> Enum.with_index()
      |> Enum.map(fn {snippet, snippet_index} -> {snippet_index, group_index, snippet} end)
    end)
    |> Enum.sort()
    |> Enum.map(fn {_snippet_index, _group_index, snippet} -> snippet end)
    |> Enum.take(remaining)
  end

  defp block_snippet(block, item) do
    %{
      block_id: block.id,
      block_name: block.name,
      page: item.page,
      snippet: item.snippet
    }
  end

  defp block_file_bindings_load do
    [
      file_bindings: [
        :id,
        :external_id,
        :sequence,
        :file_id,
        file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
      ]
    ]
  end

  defp ensure_block_cache_ready(%ToolInstance{} = tool_instance, %KnowledgeBlock{} = block, cfg)
       when is_map(cfg) do
    cache_root = cache_root(tool_instance)
    doc_id = block_doc_id(block, cfg)
    content = block.content |> to_string() |> PromptContent.strip_comments()

    meta = %{
      "tool_type" => type(),
      "block_id" => block.id,
      "block_external_id" => to_string(block.external_id || ""),
      "name" => block.name,
      "version" => block.version,
      "token_count" => block.token_count,
      "updated_at" => datetime_iso(block.updated_at),
      "content_type" => "text/markdown",
      "source_extension" => ".md"
    }

    DocumentReader.ensure_text_cache_ready(
      cache_root,
      tool_instance.id,
      doc_id,
      content,
      meta,
      cfg
    )
  end

  defp block_doc_id(%KnowledgeBlock{} = block, cfg) when is_map(cfg) do
    stable_id = block.external_id || block.id
    updated_at = datetime_iso(block.updated_at)
    DocumentReader.doc_id("knowledge_block:#{stable_id}:#{updated_at}:#{cfg.chunk_size_tokens}")
  end

  defp parse_max_results(args) when is_map(args) do
    case coerce_optional_integer(map_get(args, "max_results"), @default_list_max_results) do
      {:ok, value} when value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, "Argument `max_results` must be a non-negative integer."}
      {:error, _reason} -> {:error, "Argument `max_results` must be an integer."}
    end
  end

  defp filter_blocks(blocks, q) when is_list(blocks) and is_binary(q) do
    q = String.downcase(String.trim(q))

    if q == "" do
      blocks
    else
      Enum.filter(blocks, fn block ->
        haystack =
          [block.name, block.version]
          |> Enum.map_join(" ", &String.downcase(to_string(&1 || "")))

        String.contains?(haystack, q)
      end)
    end
  end

  defp format_block_ref(%KnowledgeBlock{} = block) do
    version = block.version |> to_string() |> String.trim()
    version_part = if version == "", do: "", else: ", version: #{version}"
    "#{block.name} (block_id: #{block.id}#{version_part}, tokens: #{block.token_count || 0})"
  end

  defp block_raw(%KnowledgeBlock{} = block) do
    %{
      "block_id" => block.id,
      "name" => block.name,
      "version" => block.version || "",
      "token_count" => block.token_count || 0
    }
  end

  defp block_attachment_section(%KnowledgeBlock{} = block) do
    case PromptContent.attachment_placeholders(block) do
      "" -> ""
      placeholders -> "Attached files:\n" <> placeholders
    end
  end

  defp block_attachments_raw(%KnowledgeBlock{} = block) do
    block
    |> Map.get(:file_bindings, [])
    |> case do
      %Ash.NotLoaded{} -> []
      bindings when is_list(bindings) -> bindings
      _other -> []
    end
    |> Enum.sort_by(fn binding ->
      {Map.get(binding, :sequence) || 0, Map.get(binding, :id) || 0}
    end)
    |> Enum.flat_map(&attachment_raw/1)
  end

  defp block_attachments_raw(_block), do: []

  defp attachment_raw(binding) when is_map(binding) do
    case Map.get(binding, :file) do
      %Ash.NotLoaded{} ->
        []

      %{} = file ->
        [
          %{
            "id" => Map.get(binding, :id),
            "external_id" => Map.get(binding, :external_id),
            "file_id" => Map.get(file, :external_id),
            "filename" => Map.get(file, :filename),
            "mime_type" => Map.get(file, :mime_type),
            "size_bytes" => Map.get(file, :size_bytes),
            "sha256" => Map.get(file, :sha256),
            "sequence" => Map.get(binding, :sequence) || 0
          }
        ]

      _other ->
        []
    end
  end

  defp attachment_raw(_binding), do: []

  defp tag_display_name(%KnowledgeTag{} = tag) do
    tag.full_name
    |> to_string()
    |> String.trim()
    |> case do
      "" -> to_string(tag.name || "")
      value -> value
    end
  end

  defp owner_actor(%ToolInstance{owner_id: owner_id}, _fallback) when is_integer(owner_id) do
    %{id: owner_id}
  end

  defp owner_actor(_tool_instance, %{id: id} = actor) when is_integer(id), do: actor
  defp owner_actor(_tool_instance, _fallback), do: nil

  defp config_from_tool(%ToolInstance{} = tool_instance) do
    cfg =
      tool_instance
      |> Map.get(:config)
      |> normalize_config()

    doc_cfg = DocumentReader.config_from_map(cfg)

    Map.merge(doc_cfg, %{
      "knowledge_tag_id" => Map.get(cfg, "knowledge_tag_id"),
      knowledge_tag_id: Map.get(cfg, "knowledge_tag_id"),
      max_context_blocks:
        max(0, read_integer(cfg, "max_context_blocks", @default_max_context_blocks))
    })
  end

  defp config_raw(cfg) when is_map(cfg) do
    %{
      "knowledge_tag_id" => Map.get(cfg, :knowledge_tag_id, Map.get(cfg, "knowledge_tag_id")),
      "chunk_size_tokens" => cfg.chunk_size_tokens,
      "cache_ttl_seconds" => cfg.cache_ttl_seconds,
      "cache_max_bytes" => cfg.cache_max_bytes,
      "max_context_blocks" => Map.get(cfg, :max_context_blocks, @default_max_context_blocks)
    }
  end

  defp cache_root(%ToolInstance{} = tool_instance) do
    tmp = System.tmp_dir!() || "/tmp"
    Path.join([tmp, "club_knowledge_library_cache", "tool_#{tool_instance.id}"])
  end

  defp normalize_map(%{} = map) do
    Enum.into(map, %{}, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_other), do: %{}

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp normalize_optional_integer(config, key) do
    case parse_optional_positive_integer(Map.get(config, key)) do
      {:ok, nil} -> Map.delete(config, key)
      {:ok, value} -> Map.put(config, key, value)
      {:error, _reason} -> config
    end
  end

  defp normalize_positive_integer(config, key, default) do
    case coerce_optional_integer(Map.get(config, key), default) do
      {:ok, value} when value >= 1 -> Map.put(config, key, value)
      _other -> Map.put(config, key, default)
    end
  end

  defp normalize_non_negative_integer(config, key, default) do
    case coerce_optional_integer(Map.get(config, key), default) do
      {:ok, value} when value >= 0 -> Map.put(config, key, value)
      _other -> Map.put(config, key, default)
    end
  end

  defp parse_optional_positive_integer(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_optional_positive_integer(value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_optional_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, :invalid_integer}
    end
  end

  defp parse_optional_positive_integer(_value), do: {:error, :invalid_integer}

  defp coerce_optional_integer(value, default) when value in [nil, ""], do: {:ok, default}
  defp coerce_optional_integer(value, _default) when is_integer(value), do: {:ok, value}

  defp coerce_optional_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _other -> {:error, :invalid_integer}
    end
  end

  defp coerce_optional_integer(_value, _default), do: {:error, :invalid_integer}

  defp read_integer(cfg, key, default) do
    case coerce_optional_integer(map_get(cfg, key), default) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  defp read_string_arg(args, key, default) do
    args
    |> map_get(key)
    |> case do
      nil -> default
      value -> to_string(value) |> String.trim()
    end
    |> case do
      "" -> default
      value -> value
    end
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case key do
        "block_id" -> Map.get(map, :block_id)
        "block_name" -> Map.get(map, :block_name)
        "knowledge_tag_id" -> Map.get(map, :knowledge_tag_id)
        "max_context_blocks" -> Map.get(map, :max_context_blocks)
        "max_results" -> Map.get(map, :max_results)
        "q" -> Map.get(map, :q)
        _other -> nil
      end
  end

  defp map_get(_map, _key), do: nil

  defp datetime_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_iso(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime_iso(nil), do: ""
  defp datetime_iso(value), do: to_string(value)
end
