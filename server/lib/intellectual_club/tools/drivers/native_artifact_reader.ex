defmodule IntellectualClub.Tools.Drivers.NativeArtifactReader do
  @moduledoc """
  Native artifact reader driver.

  This fixed-function tool reads files that are already available in the current
  chat context, projects image files into native image modality, and saves text
  as user-visible artifacts.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Chat.ContentFiles
  alias IntellectualClub.Files
  alias IntellectualClub.Tools.DocumentReader
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  @impl true
  def type, do: "native-artifact-reader"

  @impl true
  def title, do: "Artifact Reader"

  @impl true
  def description do
    "Read chat artifacts by file_id, search extracted text, attach images, and save text files."
  end

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def supports_artifacts?, do: true

  @impl true
  def default_config do
    %{
      "chunk_size_tokens" => DocumentReader.default_chunk_size_tokens(),
      "cache_ttl_seconds" => DocumentReader.default_cache_ttl_seconds(),
      "cache_max_bytes" => DocumentReader.default_cache_max_bytes(),
      "extract_timeout_seconds" => DocumentReader.default_extract_timeout_seconds(),
      "max_extract_chars" => DocumentReader.default_max_extract_chars(),
      "pdf_ocr_strategy" => DocumentReader.default_pdf_ocr_strategy()
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "chunk_size_tokens" => %{
          "type" => "integer",
          "title" => "Chunk size (tokens)",
          "description" => "Approximate token count per cached page.",
          "minimum" => 1
        },
        "cache_ttl_seconds" => %{
          "type" => "integer",
          "title" => "Cache TTL (seconds)",
          "description" => "How long cached documents stay fresh.",
          "minimum" => 0
        },
        "cache_max_bytes" => %{
          "type" => "integer",
          "title" => "Cache max bytes",
          "description" => "Maximum cache size in bytes for this tool instance.",
          "minimum" => 0
        },
        "extract_timeout_seconds" => %{
          "type" => "number",
          "title" => "Extract timeout (seconds)",
          "description" => "Extraction timeout in seconds. Exceeding this returns a tool error.",
          "minimum" => 0
        },
        "max_extract_chars" => %{
          "type" => "integer",
          "title" => "Max extract chars",
          "description" => "Maximum number of extracted characters per document.",
          "minimum" => 0
        },
        "pdf_ocr_strategy" => %{
          "type" => "string",
          "title" => "PDF OCR strategy",
          "enum" => DocumentReader.supported_pdf_ocr_strategies(),
          "description" => "PDF OCR strategy used by Extractous."
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema, do: nil

  @impl true
  def fixed_functions(%ToolInstance{} = _tool_instance) do
    [
      %{
        "name" => "read_file",
        "description" =>
          "Read a text, HTML, PDF, or office artifact by file_id and return one extracted page.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "file_id" => %{
              "type" => "string",
              "description" => "File external UUID from attachment or artifact metadata."
            },
            "page" => %{
              "type" => "integer",
              "minimum" => 0,
              "default" => 1,
              "description" =>
                "1-based page number to return. If omitted, returns page 1. Page 0 is accepted as page 1."
            }
          },
          "required" => ["file_id"],
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "search_file",
        "description" =>
          "Search extracted artifact text by file_id and return snippets with page numbers.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "file_id" => %{
              "type" => "string",
              "description" => "File external UUID from attachment or artifact metadata."
            },
            "regex" => %{
              "type" => "string",
              "description" => "Regular expression to search across pages."
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
          "required" => ["file_id", "regex"],
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "read_image",
        "description" => "Read an image artifact by file_id and attach it as image media.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "file_id" => %{
              "type" => "string",
              "description" => "File external UUID from attachment or artifact metadata."
            }
          },
          "required" => ["file_id"],
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "upload_file",
        "description" => "Save text as a user-visible text artifact.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string", "description" => "Text content to save."},
            "filename" => %{
              "type" => "string",
              "description" => "Artifact filename. Defaults to artifact.txt.",
              "default" => "artifact.txt"
            }
          },
          "required" => ["text"],
          "additionalProperties" => false
        },
        "enabled" => true
      }
    ]
  end

  @impl true
  def discover(%ToolInstance{} = _tool_instance) do
    {:error, "Discovery is not supported for this tool type."}
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, function_name, args, execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    case function_name do
      "read_file" -> read_file(tool_instance, args || %{}, execution_context)
      "search_file" -> search_file(tool_instance, args || %{}, execution_context)
      "read_image" -> read_image(args || %{}, execution_context)
      "upload_file" -> upload_file(args || %{})
      _other -> {:error, "Unknown function: #{function_name}"}
    end
  end

  defp read_file(%ToolInstance{} = tool_instance, args, %ExecutionContext{} = execution_context)
       when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, file_external_id} <- required_file_id(args),
         {:ok, page} <- DocumentReader.parse_page(args),
         {:ok, {_content, file, payload}} <-
           ContentFiles.load_payload_for_execution(file_external_id, execution_context)
           |> normalize_payload_error(),
         {:ok, {doc_dir, meta, cached}} <- ensure_cache_ready(tool_instance, file, payload, cfg) do
      total_pages = DocumentReader.pages_total(doc_dir, meta)
      used_page = page || 1

      cond do
        total_pages <= 0 ->
          text =
            [
              source_line(file),
              "Cached: #{if(cached, do: "true", else: "false")}",
              "Error: document has no readable content."
            ]
            |> Enum.join("\n")
            |> Kernel.<>("\n")

          {:ok,
           {text,
            %{
              "file_id" => file.external_id,
              "cached" => cached,
              "page" => used_page,
              "pages_total" => total_pages
            }}}

        used_page < 1 or used_page > total_pages ->
          {:error, "Page out of range: #{used_page} (total pages: #{total_pages})"}

        true ->
          case DocumentReader.read_page_text(doc_dir, used_page) do
            {:ok, page_text} ->
              text =
                [
                  source_line(file),
                  "Cached: #{if(cached, do: "true", else: "false")}",
                  "Page: #{used_page} / #{total_pages}",
                  "",
                  "---",
                  "",
                  String.trim(page_text)
                ]
                |> Enum.join("\n")
                |> String.trim()
                |> Kernel.<>("\n")

              raw = %{
                "file_id" => file.external_id,
                "doc_id" => Path.basename(doc_dir),
                "cached" => cached,
                "filename" => file.filename,
                "mime_type" => file.mime_type,
                "size_bytes" => file.size_bytes,
                "page" => used_page,
                "pages_total" => total_pages,
                "config" => config_raw(cfg)
              }

              {:ok, {text, raw}}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp read_file(%ToolInstance{} = _tool_instance, _args, _execution_context) do
    {:error, "Execution context is required for read_file."}
  end

  defp search_file(%ToolInstance{} = tool_instance, args, %ExecutionContext{} = execution_context)
       when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, file_external_id} <- required_file_id(args),
         {:ok, regex_text} <- DocumentReader.required_regex(args),
         {:ok, regex} <-
           DocumentReader.compile_regex(
             regex_text,
             DocumentReader.read_string_arg(args, "regex_flags", "im")
           ),
         {:ok, snippet_len_chars} <- DocumentReader.parse_snippet_len(args),
         {:ok, max_snippets} <- DocumentReader.parse_max_snippets(args),
         {:ok, {_content, file, payload}} <-
           ContentFiles.load_payload_for_execution(file_external_id, execution_context)
           |> normalize_payload_error(),
         {:ok, {doc_dir, meta, cached}} <- ensure_cache_ready(tool_instance, file, payload, cfg) do
      total_pages = DocumentReader.pages_total(doc_dir, meta)
      regex_flags = DocumentReader.read_string_arg(args, "regex_flags", "im")

      if max_snippets == 0 do
        text =
          [
            source_line(file),
            "Cached: #{if(cached, do: "true", else: "false")}",
            "Pages: #{total_pages}",
            "Regex: /#{regex_text}/",
            "Match pages: none"
          ]
          |> Enum.join("\n")
          |> Kernel.<>("\n")

        raw = %{
          "file_id" => file.external_id,
          "doc_id" => Path.basename(doc_dir),
          "cached" => cached,
          "filename" => file.filename,
          "mime_type" => file.mime_type,
          "pages_total" => total_pages,
          "regex" => regex_text,
          "regex_flags" => regex_flags,
          "match_pages" => [],
          "snippets" => [],
          "snippet_len_chars" => snippet_len_chars,
          "max_snippets" => max_snippets
        }

        {:ok, {text, raw}}
      else
        {snippets, match_pages} =
          DocumentReader.collect_snippets(
            doc_dir,
            total_pages,
            regex,
            snippet_len_chars,
            max_snippets
          )

        header_lines = [
          source_line(file),
          "Cached: #{if(cached, do: "true", else: "false")}",
          "Pages: #{total_pages}",
          "Regex: /#{regex_text}/",
          if(match_pages == [],
            do: "Match pages: none",
            else: "Match pages: #{Enum.join(match_pages, ", ")}"
          )
        ]

        body_lines =
          Enum.map(snippets, fn item ->
            "Page #{item.page}: #{item.snippet}"
          end)

        text =
          [Enum.join(header_lines, "\n"), "", "---", "", Enum.join(body_lines, "\n")]
          |> Enum.join("\n")
          |> String.trim()
          |> Kernel.<>("\n")

        raw = %{
          "file_id" => file.external_id,
          "doc_id" => Path.basename(doc_dir),
          "cached" => cached,
          "filename" => file.filename,
          "mime_type" => file.mime_type,
          "pages_total" => total_pages,
          "regex" => regex_text,
          "regex_flags" => regex_flags,
          "match_pages" => match_pages,
          "snippets" =>
            Enum.map(snippets, fn item ->
              %{"page" => item.page, "snippet" => item.snippet}
            end),
          "snippet_len_chars" => snippet_len_chars,
          "max_snippets" => max_snippets,
          "config" => config_raw(cfg)
        }

        {:ok, {text, raw}}
      end
    end
  end

  defp search_file(%ToolInstance{} = _tool_instance, _args, _execution_context) do
    {:error, "Execution context is required for search_file."}
  end

  defp read_image(args, %ExecutionContext{} = execution_context) when is_map(args) do
    with {:ok, file_external_id} <- required_file_id(args),
         {:ok, {_content, file, payload}} <-
           ContentFiles.load_payload_for_execution(file_external_id, execution_context)
           |> normalize_payload_error(),
         {:ok, mime_type} <- detect_image_mime(payload) do
      media = file_result(%{file | mime_type: mime_type})

      {:ok,
       %ExecutionResult{
         text: "Image #{file.external_id} read from #{file.filename}",
         raw: %{
           "file_id" => file.external_id,
           "filename" => file.filename,
           "mime_type" => mime_type,
           "size_bytes" => file.size_bytes
         },
         media: [media],
         artifacts: []
       }}
    end
  end

  defp read_image(_args, _execution_context) do
    {:error, "Execution context is required for read_image."}
  end

  defp upload_file(args) when is_map(args) do
    with {:ok, text} <- required_text(args),
         filename <- read_filename(args),
         {:ok, file} <- Files.create_from_binary(filename, "text/plain", text) do
      {:ok,
       %ExecutionResult{
         text: "File #{file.external_id} uploaded",
         raw: %{
           "file_id" => file.external_id,
           "filename" => file.filename,
           "mime_type" => file.mime_type,
           "size_bytes" => file.size_bytes
         },
         media: [],
         artifacts: [file_result(file)]
       }}
    end
  end

  @doc false
  @spec detect_image_mime(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def detect_image_mime(payload) when is_binary(payload) do
    case ExImageInfo.info(payload) do
      {mime_type, _width, _height, _variant} -> {:ok, mime_type}
      nil -> {:error, "File content is not a valid image."}
    end
  end

  def detect_image_mime(_payload), do: {:error, "File content is not a valid image."}

  defp ensure_cache_ready(%ToolInstance{} = tool_instance, file, payload, cfg)
       when is_binary(payload) and is_map(cfg) do
    cache_root = cache_root(tool_instance)
    doc_id = DocumentReader.doc_id(to_string(file.external_id))

    DocumentReader.ensure_cache_ready(cache_root, tool_instance.id, doc_id, cfg, fn ->
      {:ok,
       {payload,
        %{
          "tool_type" => type(),
          "file_id" => file.external_id,
          "filename" => file.filename,
          "mime_type" => file.mime_type,
          "size_bytes" => file.size_bytes,
          "sha256" => file.sha256,
          "source_extension" => Path.extname(file.filename || "")
        }}}
    end)
  end

  defp required_file_id(args) when is_map(args) do
    file_id =
      args
      |> Map.get("file_id", Map.get(args, :file_id))
      |> to_string()
      |> String.trim()

    cond do
      file_id == "" ->
        {:error, "Argument `file_id` is required."}

      Ecto.UUID.cast(file_id) == :error ->
        {:error, "Argument `file_id` must be a valid UUID."}

      true ->
        {:ok, file_id}
    end
  end

  defp required_text(args) when is_map(args) do
    case Map.fetch(args, "text") do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, "Argument `text` must be a string."}
      :error -> {:error, "Argument `text` is required."}
    end
  end

  defp read_filename(args) when is_map(args) do
    args
    |> Map.get("filename", Map.get(args, :filename, "artifact.txt"))
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "artifact.txt"
      value -> Path.basename(value)
    end
  end

  defp normalize_payload_error({:ok, value}), do: {:ok, value}

  defp normalize_payload_error({:error, :invalid_request}) do
    {:error, "Argument `file_id` must be a valid UUID."}
  end

  defp normalize_payload_error({:error, reason})
       when reason in [:file_not_found, :not_found, :payload_not_found] do
    {:error, "File not found or not available in this chat."}
  end

  defp normalize_payload_error({:error, reason}), do: {:error, inspect(reason)}

  defp source_line(file) do
    "File: #{file.filename} (file_id=#{file.external_id}, mime_type=#{file.mime_type}, size_bytes=#{file.size_bytes})"
  end

  defp config_from_tool(%ToolInstance{} = tool_instance) do
    tool_instance
    |> Map.get(:config)
    |> case do
      %{} = cfg -> cfg
      _other -> %{}
    end
    |> DocumentReader.config_from_map()
  end

  defp config_raw(cfg) when is_map(cfg) do
    %{
      "chunk_size_tokens" => cfg.chunk_size_tokens,
      "cache_ttl_seconds" => cfg.cache_ttl_seconds,
      "cache_max_bytes" => cfg.cache_max_bytes,
      "max_extract_chars" => cfg.max_extract_chars
    }
  end

  defp cache_root(%ToolInstance{} = tool_instance) do
    tmp = System.tmp_dir!() || "/tmp"
    Path.join([tmp, "club_artifact_reader_cache", "tool_#{tool_instance.id}"])
  end

  defp file_result(file) do
    %{
      "file_id" => file.id,
      "file_external_id" => file.external_id,
      "filename" => file.filename,
      "mime_type" => file.mime_type,
      "size_bytes" => file.size_bytes,
      "sha256" => file.sha256
    }
  end
end
