defmodule IntellectualClub.Tools.Drivers.NativeWebReader do
  @moduledoc """
  Native web reader driver.

  This is a fixed-function tool that exposes `read_url` and `search_url`.
  The driver fetches HTTP(S) documents (including PDF), extracts text with
  `ExtractousEx`, splits content into pages, and keeps a local on-disk cache.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.TokenCounter
  alias IntellectualClub.Tools.ToolInstance

  @default_chunk_size_tokens 5_000
  @default_cache_ttl_seconds 86_400
  @default_cache_max_bytes 1 * 1024 * 1024 * 1024
  @default_max_download_bytes 100 * 1024 * 1024
  @default_http_timeout_seconds 30.0
  @default_extract_timeout_seconds 45.0
  @default_user_agent "IntellectualClubWebReader/0.1"
  @default_max_extract_chars 500_000
  @supported_pdf_ocr_strategies ["NO_OCR", "AUTO", "OCR_ONLY", "OCR_AND_TEXT_EXTRACTION"]
  @default_pdf_ocr_strategy "NO_OCR"

  @impl true
  def type, do: "native-web-reader"

  @impl true
  def title, do: "Web Reader"

  @impl true
  def description do
    "Fetch an HTML or PDF URL, extract text, expose paged reads, and regex search snippets."
  end

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def default_config do
    %{
      "chunk_size_tokens" => @default_chunk_size_tokens,
      "cache_ttl_seconds" => @default_cache_ttl_seconds,
      "cache_max_bytes" => @default_cache_max_bytes,
      "max_download_bytes" => @default_max_download_bytes,
      "http_timeout_seconds" => @default_http_timeout_seconds,
      "extract_timeout_seconds" => @default_extract_timeout_seconds,
      "user_agent" => @default_user_agent,
      "max_extract_chars" => @default_max_extract_chars,
      "pdf_ocr_strategy" => @default_pdf_ocr_strategy
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
        "max_download_bytes" => %{
          "type" => "integer",
          "title" => "Max download bytes",
          "description" => "Maximum allowed HTTP response body size in bytes.",
          "minimum" => 0
        },
        "http_timeout_seconds" => %{
          "type" => "number",
          "title" => "HTTP timeout (seconds)",
          "description" => "HTTP receive timeout in seconds.",
          "minimum" => 0
        },
        "extract_timeout_seconds" => %{
          "type" => "number",
          "title" => "Extract timeout (seconds)",
          "description" => "Extraction timeout in seconds. Exceeding this returns a tool error.",
          "minimum" => 0
        },
        "user_agent" => %{
          "type" => "string",
          "title" => "User agent",
          "description" => "HTTP User-Agent header value.",
          "x-ui" => %{"placeholder" => @default_user_agent}
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
          "enum" => @supported_pdf_ocr_strategies,
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
        "name" => "read_url",
        "description" =>
          "Fetch a URL (HTML or PDF), extract text, and return a requested cached page.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string", "description" => "HTTP(S) URL to fetch and read."},
            "page" => %{
              "type" => "integer",
              "minimum" => 0,
              "default" => 1,
              "description" =>
                "1-based page number to return. If omitted, returns page 1. Page 0 is accepted as page 1."
            }
          },
          "required" => ["url"]
        },
        "enabled" => true
      },
      %{
        "name" => "search_url",
        "description" =>
          "Fetch a URL (HTML or PDF), extract text, and search across pages returning snippets with page numbers.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string", "description" => "HTTP(S) URL to fetch and search."},
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
          "required" => ["url", "regex"]
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
  def execute(%ToolInstance{} = tool_instance, function_name, args, _execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    case function_name do
      "read_url" -> read_url(tool_instance, args || %{})
      "search_url" -> search_url(tool_instance, args || %{})
      _other -> {:error, "Unknown function: #{function_name}"}
    end
  end

  defp read_url(%ToolInstance{} = tool_instance, args) when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, url} <- required_url(args),
         {:ok, normalized_url} <- normalize_url(url),
         {:ok, page} <- parse_page(args),
         {:ok, {doc_dir, meta, cached}} <- ensure_cache_ready(tool_instance, normalized_url, cfg) do
      total_pages = pages_total(doc_dir, meta)
      used_page = page || 1
      final_url = to_string(Map.get(meta, "final_url") || normalized_url)

      cond do
        total_pages <= 0 ->
          text =
            [
              "Source: #{final_url}",
              "Cached: #{if(cached, do: "true", else: "false")}",
              "Error: document has no readable content."
            ]
            |> Enum.join("\n")
            |> Kernel.<>("\n")

          {:ok,
           {text,
            %{
              "url" => final_url,
              "cached" => cached,
              "page" => used_page,
              "pages_total" => total_pages
            }}}

        used_page < 1 or used_page > total_pages ->
          {:error, "Page out of range: #{used_page} (total pages: #{total_pages})"}

        true ->
          case read_page_text(doc_dir, used_page) do
            {:ok, page_text} ->
              text =
                [
                  "Source: #{final_url}",
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
                "url" => final_url,
                "doc_id" => Path.basename(doc_dir),
                "cached" => cached,
                "content_type" => Map.get(meta, "content_type"),
                "page" => used_page,
                "pages_total" => total_pages,
                "config" => %{
                  "chunk_size_tokens" => cfg.chunk_size_tokens,
                  "cache_ttl_seconds" => cfg.cache_ttl_seconds,
                  "cache_max_bytes" => cfg.cache_max_bytes,
                  "max_download_bytes" => cfg.max_download_bytes,
                  "max_extract_chars" => cfg.max_extract_chars
                }
              }

              {:ok, {text, raw}}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp search_url(%ToolInstance{} = tool_instance, args) when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, url} <- required_url(args),
         {:ok, normalized_url} <- normalize_url(url),
         {:ok, regex_text} <- required_regex(args),
         {:ok, regex} <- compile_regex(regex_text, read_string_arg(args, "regex_flags", "im")),
         {:ok, snippet_len_chars} <- parse_snippet_len(args),
         {:ok, max_snippets} <- parse_max_snippets(args),
         {:ok, {doc_dir, meta, cached}} <- ensure_cache_ready(tool_instance, normalized_url, cfg) do
      total_pages = pages_total(doc_dir, meta)
      final_url = to_string(Map.get(meta, "final_url") || normalized_url)

      if max_snippets == 0 do
        text =
          [
            "Source: #{final_url}",
            "Cached: #{if(cached, do: "true", else: "false")}",
            "Pages: #{total_pages}",
            "Regex: /#{regex_text}/",
            "Match pages: none"
          ]
          |> Enum.join("\n")
          |> Kernel.<>("\n")

        raw = %{
          "url" => final_url,
          "doc_id" => Path.basename(doc_dir),
          "cached" => cached,
          "content_type" => Map.get(meta, "content_type"),
          "pages_total" => total_pages,
          "regex" => regex_text,
          "regex_flags" => read_string_arg(args, "regex_flags", "im"),
          "match_pages" => [],
          "snippets" => [],
          "snippet_len_chars" => snippet_len_chars,
          "max_snippets" => max_snippets
        }

        {:ok, {text, raw}}
      else
        {snippets, match_pages} =
          collect_snippets(doc_dir, total_pages, regex, snippet_len_chars, max_snippets)

        header_lines = [
          "Source: #{final_url}",
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
          "url" => final_url,
          "doc_id" => Path.basename(doc_dir),
          "cached" => cached,
          "content_type" => Map.get(meta, "content_type"),
          "pages_total" => total_pages,
          "regex" => regex_text,
          "regex_flags" => read_string_arg(args, "regex_flags", "im"),
          "match_pages" => match_pages,
          "snippets" =>
            Enum.map(snippets, fn item ->
              %{"page" => item.page, "snippet" => item.snippet}
            end),
          "snippet_len_chars" => snippet_len_chars,
          "max_snippets" => max_snippets,
          "config" => %{
            "chunk_size_tokens" => cfg.chunk_size_tokens,
            "cache_ttl_seconds" => cfg.cache_ttl_seconds,
            "cache_max_bytes" => cfg.cache_max_bytes,
            "max_download_bytes" => cfg.max_download_bytes,
            "max_extract_chars" => cfg.max_extract_chars
          }
        }

        {:ok, {text, raw}}
      end
    end
  end

  defp collect_snippets(doc_dir, total_pages, regex, snippet_len_chars, max_snippets)
       when is_integer(total_pages) and total_pages >= 0 do
    Enum.reduce_while(1..total_pages, {[], []}, fn page, {snippets, match_pages} ->
      if length(snippets) >= max_snippets do
        {:halt, {snippets, match_pages}}
      else
        case read_page_text(doc_dir, page) do
          {:ok, text} ->
            remaining = max_snippets - length(snippets)

            page_snippets =
              text
              |> extract_non_overlapping_snippets(regex, snippet_len_chars, remaining)
              |> Enum.map(fn {start_pos, end_pos} ->
                %{page: page, snippet: format_snippet(text, start_pos, end_pos)}
              end)

            if page_snippets == [] do
              {:cont, {snippets, match_pages}}
            else
              {:cont, {snippets ++ page_snippets, match_pages ++ [page]}}
            end

          {:error, _reason} ->
            {:cont, {snippets, match_pages}}
        end
      end
    end)
  end

  defp compile_regex(regex_text, flags_text)
       when is_binary(regex_text) and is_binary(flags_text) do
    flags = sanitize_regex_flags(flags_text)

    case Regex.compile(regex_text, flags) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> {:error, "Invalid regex: #{inspect(reason)}"}
    end
  end

  defp sanitize_regex_flags(flags_text) when is_binary(flags_text) do
    flags_text
    |> String.to_charlist()
    |> Enum.filter(&(&1 in ~c"imsu"))
    |> to_string()
  end

  defp extract_non_overlapping_snippets(text, regex, snippet_len_chars, max_snippets)
       when is_binary(text) and is_struct(regex, Regex) and is_integer(snippet_len_chars) and
              is_integer(max_snippets) do
    if text == "" or snippet_len_chars <= 0 or max_snippets <= 0 do
      []
    else
      snippet_len = max(1, snippet_len_chars)
      pre_context = min(80, div(snippet_len, 3))

      Regex.scan(regex, text, return: :index)
      |> Enum.map(fn
        [{start_pos, _len} | _rest] -> start_pos
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce_while({[], 0}, fn start_pos, {windows, covered_until} ->
        cond do
          length(windows) >= max_snippets ->
            {:halt, {windows, covered_until}}

          start_pos < covered_until ->
            {:cont, {windows, covered_until}}

          true ->
            start_byte = max(0, start_pos - pre_context)
            end_byte = min(byte_size(text), start_byte + snippet_len)
            start_byte = max(0, end_byte - snippet_len)
            {:cont, {windows ++ [{start_byte, end_byte}], end_byte}}
        end
      end)
      |> elem(0)
    end
  end

  defp format_snippet(text, start_byte, end_byte) do
    len = max(0, end_byte - start_byte)

    snippet =
      text
      |> String.byte_slice(start_byte, len)
      |> then(&Regex.replace(~r/\s+/u, &1, " "))
      |> String.trim()

    prefix = if start_byte > 0, do: "...", else: ""
    suffix = if end_byte < byte_size(text), do: "...", else: ""
    prefix <> snippet <> suffix
  end

  defp ensure_cache_ready(%ToolInstance{} = tool_instance, normalized_url, cfg) do
    cache_root = cache_root(tool_instance)
    doc_id = doc_id(normalized_url)
    doc_dir = Path.join(cache_root, doc_id)

    with :ok <- File.mkdir_p(cache_root) do
      if cache_valid?(doc_dir, cfg.cache_ttl_seconds) do
        {:ok, {doc_dir, read_meta(doc_dir), true}}
      else
        with_doc_lock(tool_instance.id, doc_id, fn ->
          if cache_valid?(doc_dir, cfg.cache_ttl_seconds) do
            {:ok, {doc_dir, read_meta(doc_dir), true}}
          else
            cleanup_cache(cache_root, cfg.cache_ttl_seconds, cfg.cache_max_bytes)

            _ = File.rm_rf(doc_dir)

            case build_cache_for_url(normalized_url, doc_dir, cfg) do
              {:ok, meta} ->
                {:ok, {doc_dir, meta, false}}

              {:error, reason} ->
                _ = File.rm_rf(doc_dir)
                {:error, reason}
            end
          end
        end)
      end
    else
      {:error, reason} ->
        {:error, "Failed to prepare cache: #{inspect(reason)}"}
    end
  end

  defp with_doc_lock(tool_instance_id, doc_id, fun)
       when is_integer(tool_instance_id) and is_binary(doc_id) and is_function(fun, 0) do
    lock = {{__MODULE__, tool_instance_id, doc_id}, self()}

    if :global.set_lock(lock, [node()], 120_000) do
      try do
        fun.()
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, "Timeout waiting for cache lock."}
    end
  end

  defp build_cache_for_url(normalized_url, doc_dir, cfg) do
    with :ok <- File.mkdir_p(doc_dir),
         {:ok, {bytes, download_meta}} <- download_to_binary(normalized_url, cfg),
         {:ok, {extracted_text, extraction_meta}} <- extract_text(bytes, cfg),
         :ok <- write_pages(doc_dir, split_to_pages(extracted_text, cfg.chunk_size_tokens)) do
      meta =
        download_meta
        |> Map.merge(extraction_meta)
        |> Map.merge(%{
          "tool_type" => type(),
          "chunk_size_tokens" => cfg.chunk_size_tokens,
          "pages_total" => pages_total(doc_dir, %{})
        })

      with :ok <- write_json(Path.join(doc_dir, "meta.json"), meta),
           :ok <- File.write(Path.join(doc_dir, "READY"), "ok\n") do
        {:ok, meta}
      else
        {:error, reason} ->
          {:error, "Failed to finalize cache: #{inspect(reason)}"}
      end
    end
  end

  defp download_to_binary(url, cfg) when is_binary(url) and is_map(cfg) do
    timeout_ms = cfg.http_timeout_seconds |> Kernel.*(1000) |> trunc() |> max(1)

    headers = [
      {"user-agent", cfg.user_agent},
      {"accept", "*/*"}
    ]

    resp =
      Req.request!(
        method: :get,
        url: url,
        headers: headers,
        redirect: true,
        receive_timeout: timeout_ms
      )

    if resp.status >= 400 do
      body_text = body_to_string(resp.body)

      {:error,
       "HTTP error while fetching URL: #{resp.status}. #{String.slice(body_text, 0, 500)}"}
    else
      body = body_to_binary(resp.body)

      if cfg.max_download_bytes > 0 and byte_size(body) > cfg.max_download_bytes do
        {:error, "Download exceeds max_download_bytes limit."}
      else
        content_type = first_header_value(resp.headers, "content-type")

        meta = %{
          "url" => url,
          "final_url" => url,
          "content_type" => content_type,
          "status_code" => resp.status,
          "download_bytes" => byte_size(body),
          "source_extension" => guess_extension(content_type, url)
        }

        {:ok, {body, meta}}
      end
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    :exit, reason ->
      {:error, Exception.format_exit(reason)}
  end

  defp extract_text(bytes, cfg) when is_binary(bytes) and is_map(cfg) do
    opts = [max_length: cfg.max_extract_chars, pdf: [ocr_strategy: cfg.pdf_ocr_strategy]]
    timeout_ms = cfg.extract_timeout_seconds |> Kernel.*(1000) |> trunc() |> max(1)

    case extract_with_timeout(bytes, opts, timeout_ms) do
      {:ok, {:ok, %{content: content, metadata: metadata}}} ->
        text = normalize_text(to_string(content || ""))
        metadata = if is_map(metadata), do: metadata, else: %{}

        extraction_meta =
          %{}
          |> maybe_put("title", map_get(metadata, "title"))
          |> maybe_put("metadata", metadata)

        {:ok, {text, extraction_meta}}

      {:ok, {:ok, other}} ->
        text =
          other
          |> inspect(limit: :infinity)
          |> normalize_text()

        {:ok, {text, %{}}}

      {:ok, {:error, reason}} ->
        {:error, "Extractous extraction failed: #{inspect(reason)}"}

      {:error, :timeout} ->
        seconds = Float.round(timeout_ms / 1000.0, 1)
        {:error, "Extractous extraction timed out after #{seconds} seconds."}

      {:error, {:exit, reason}} ->
        {:error, "Extractous extraction exited: #{Exception.format_exit(reason)}"}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  defp extract_with_timeout(bytes, opts, timeout_ms)
       when is_binary(bytes) and is_list(opts) and is_integer(timeout_ms) do
    task = Task.async(fn -> ExtractousEx.extract_from_bytes(bytes, opts) end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        {:ok, result}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  defp split_to_pages(text, chunk_size_tokens)
       when is_binary(text) and is_integer(chunk_size_tokens) do
    limit = max(1, chunk_size_tokens)

    if String.trim(text) == "" do
      [""]
    else
      text
      |> String.split(~r/\n{2,}/u)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(&split_large_segment(&1, limit))
      |> Enum.reduce({[], ""}, fn segment, {acc, current} ->
        candidate =
          if current == "" do
            segment
          else
            current <> "\n\n" <> segment
          end

        if current == "" or TokenCounter.estimate(candidate) <= limit do
          {acc, candidate}
        else
          {acc ++ [current], segment}
        end
      end)
      |> then(fn {pages, current} ->
        pages =
          if current == "" do
            pages
          else
            pages ++ [current]
          end

        if pages == [], do: [text], else: pages
      end)
    end
  end

  defp split_large_segment(segment, limit) when is_binary(segment) and is_integer(limit) do
    if TokenCounter.estimate(segment) <= limit do
      [segment]
    else
      max_bytes = max(256, trunc(limit * 4))
      do_split_by_bytes(segment, max_bytes, [])
    end
  end

  defp do_split_by_bytes(segment, _max_bytes, acc) when segment in [nil, ""],
    do: Enum.reverse(acc)

  defp do_split_by_bytes(segment, max_bytes, acc) do
    chunk = take_valid_prefix(segment, min(max_bytes, byte_size(segment)))
    chunk = if chunk == "", do: segment, else: chunk
    rest = binary_part(segment, byte_size(chunk), byte_size(segment) - byte_size(chunk))
    do_split_by_bytes(String.trim_leading(rest), max_bytes, [String.trim(chunk) | acc])
  end

  defp take_valid_prefix(text, max_bytes) when is_binary(text) and is_integer(max_bytes) do
    max_bytes = max(0, max_bytes)
    prefix = binary_part(text, 0, min(max_bytes, byte_size(text)))

    if String.valid?(prefix) do
      prefix
    else
      Enum.reduce_while(1..4, prefix, fn i, _acc ->
        n = max_bytes - i

        if n <= 0 do
          {:halt, ""}
        else
          candidate = binary_part(text, 0, n)
          if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, candidate}
        end
      end)
    end
  end

  defp write_pages(doc_dir, pages) when is_binary(doc_dir) and is_list(pages) do
    pages_dir = Path.join(doc_dir, "pages")

    _ = File.rm_rf(pages_dir)

    with :ok <- File.mkdir_p(pages_dir) do
      Enum.reduce_while(Enum.with_index(pages, 1), :ok, fn {page_text, idx}, _ ->
        path = Path.join(pages_dir, pad_page_index(idx) <> ".md")

        text =
          page_text
          |> to_string()
          |> String.trim()
          |> ensure_newline()

        case File.write(path, text) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp write_pages(_doc_dir, _pages), do: {:error, :invalid_pages}

  defp ensure_newline(text) when is_binary(text) do
    if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
  end

  defp write_json(path, value) when is_binary(path) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> File.write(path, json <> "\n")
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_meta(doc_dir) when is_binary(doc_dir) do
    path = Path.join(doc_dir, "meta.json")

    with true <- File.exists?(path),
         {:ok, raw} <- File.read(path),
         {:ok, parsed} <- Jason.decode(raw),
         true <- is_map(parsed) do
      parsed
    else
      _ -> %{}
    end
  end

  defp read_page_text(doc_dir, page) when is_binary(doc_dir) and is_integer(page) do
    path = Path.join([doc_dir, "pages", pad_page_index(page) <> ".md"])

    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, "Failed to read page #{page}."}
    end
  end

  defp pages_total(doc_dir, meta) when is_binary(doc_dir) and is_map(meta) do
    value = map_get(meta, "pages_total")

    cond do
      is_integer(value) and value > 0 ->
        value

      true ->
        pages_dir = Path.join(doc_dir, "pages")

        case File.ls(pages_dir) do
          {:ok, names} ->
            names
            |> Enum.count(&String.ends_with?(&1, ".md"))

          {:error, _reason} ->
            0
        end
    end
  end

  defp cache_root(%ToolInstance{} = tool_instance) do
    tmp = System.tmp_dir!() || "/tmp"
    Path.join([tmp, "club_web_reader_cache", "tool_#{tool_instance.id}"])
  end

  defp cleanup_cache(cache_root, ttl_seconds, max_bytes)
       when is_binary(cache_root) and is_integer(ttl_seconds) and is_integer(max_bytes) do
    doc_dirs = list_doc_dirs(cache_root)
    now = System.system_time(:second)

    if ttl_seconds > 0 do
      Enum.each(doc_dirs, fn doc_dir ->
        ts = freshness_timestamp(doc_dir)

        if now - ts > ttl_seconds do
          _ = File.rm_rf(doc_dir)
        end
      end)
    end

    if max_bytes > 0 do
      total = dir_size_bytes(cache_root)

      if total > max_bytes do
        docs =
          cache_root
          |> list_doc_dirs()
          |> Enum.map(fn doc_dir -> {freshness_timestamp(doc_dir), doc_dir} end)
          |> Enum.sort_by(fn {ts, _dir} -> ts end)

        {_total, _docs} =
          Enum.reduce_while(docs, {total, docs}, fn {_ts, doc_dir}, {running_total, full_docs} ->
            if running_total <= max_bytes do
              {:halt, {running_total, full_docs}}
            else
              removed_size = dir_size_bytes(doc_dir)
              _ = File.rm_rf(doc_dir)
              {:cont, {max(0, running_total - removed_size), full_docs}}
            end
          end)
      end
    end
  end

  defp list_doc_dirs(cache_root) when is_binary(cache_root) do
    case File.ls(cache_root) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn name ->
          full = Path.join(cache_root, name)

          if File.dir?(full) do
            [full]
          else
            []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp freshness_timestamp(doc_dir) when is_binary(doc_dir) do
    ready = Path.join(doc_dir, "READY")

    case File.stat(ready) do
      {:ok, stat} ->
        datetime_to_unix(stat.mtime)

      {:error, _} ->
        case File.stat(doc_dir) do
          {:ok, stat} -> datetime_to_unix(stat.mtime)
          {:error, _} -> 0
        end
    end
  end

  defp datetime_to_unix({{year, month, day}, {hour, minute, second}}) do
    case DateTime.from_naive(
           NaiveDateTime.new!(year, month, day, hour, minute, second),
           "Etc/UTC"
         ) do
      {:ok, dt} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp datetime_to_unix(_other), do: 0

  defp cache_valid?(doc_dir, ttl_seconds) when is_binary(doc_dir) and is_integer(ttl_seconds) do
    ready = Path.join(doc_dir, "READY")

    cond do
      ttl_seconds <= 0 ->
        false

      not File.exists?(ready) ->
        false

      true ->
        now = System.system_time(:second)
        ts = freshness_timestamp(doc_dir)
        now - ts <= ttl_seconds
    end
  end

  defp dir_size_bytes(path) when is_binary(path) do
    if File.exists?(path) do
      path
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.reduce(0, fn child, total ->
        if File.regular?(child) do
          case File.stat(child) do
            {:ok, stat} -> total + stat.size
            {:error, _reason} -> total
          end
        else
          total
        end
      end)
    else
      0
    end
  end

  defp parse_page(args) when is_map(args) do
    raw = map_get(args, "page")

    cond do
      raw in [nil, ""] ->
        {:ok, 1}

      is_integer(raw) and raw < 0 ->
        {:error, "Argument `page` must be a non-negative integer (1-based)."}

      is_integer(raw) and raw == 0 ->
        {:ok, 1}

      is_integer(raw) ->
        {:ok, raw}

      is_binary(raw) ->
        case Integer.parse(String.trim(raw)) do
          {page, ""} when page < 0 ->
            {:error, "Argument `page` must be a non-negative integer (1-based)."}

          {0, ""} ->
            {:ok, 1}

          {page, ""} ->
            {:ok, page}

          _ ->
            {:error, "Argument `page` must be an integer."}
        end

      true ->
        {:error, "Argument `page` must be an integer."}
    end
  end

  defp parse_snippet_len(args) when is_map(args) do
    case coerce_optional_integer(map_get(args, "snippet_len_chars"), 240) do
      {:ok, value} when value >= 1 -> {:ok, value}
      {:ok, _value} -> {:error, "Argument `snippet_len_chars` must be a positive integer."}
      {:error, _reason} -> {:error, "Argument `snippet_len_chars` must be an integer."}
    end
  end

  defp parse_max_snippets(args) when is_map(args) do
    case coerce_optional_integer(map_get(args, "max_snippets"), 25) do
      {:ok, value} when value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, "Argument `max_snippets` must be a non-negative integer."}
      {:error, _reason} -> {:error, "Argument `max_snippets` must be an integer."}
    end
  end

  defp required_url(args) when is_map(args) do
    url =
      args
      |> map_get("url")
      |> to_string()
      |> String.trim()

    if url == "" do
      {:error, "Argument `url` is required."}
    else
      {:ok, url}
    end
  end

  defp required_regex(args) when is_map(args) do
    regex_text =
      args
      |> map_get("regex")
      |> to_string()
      |> String.trim()

    if regex_text == "" do
      {:error, "Argument `regex` is required."}
    else
      {:ok, regex_text}
    end
  end

  defp normalize_url(raw_url) when is_binary(raw_url) do
    uri = raw_url |> String.trim() |> URI.parse()
    scheme = (uri.scheme || "") |> String.downcase()

    cond do
      scheme not in ["http", "https"] ->
        {:error, "Only http(s) URLs are supported."}

      is_nil(uri.host) or String.trim(uri.host) == "" ->
        {:error, "URL host is required."}

      true ->
        normalized =
          uri
          |> Map.put(:scheme, scheme)
          |> Map.put(:host, String.downcase(uri.host))
          |> Map.put(:path, if(uri.path in [nil, ""], do: "/", else: uri.path))
          |> Map.put(:fragment, nil)
          |> URI.to_string()

        {:ok, normalized}
    end
  end

  defp normalize_url(_other), do: {:error, "Argument `url` must be a string."}

  defp doc_id(url) when is_binary(url) do
    :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
  end

  defp guess_extension(content_type, url) do
    ct = content_type |> to_string() |> String.downcase()
    path = URI.parse(url).path |> to_string() |> String.downcase()

    cond do
      String.contains?(ct, "application/pdf") -> ".pdf"
      String.contains?(ct, "text/html") or String.contains?(ct, "application/xhtml") -> ".html"
      String.ends_with?(path, ".pdf") -> ".pdf"
      String.ends_with?(path, ".html") or String.ends_with?(path, ".htm") -> ".html"
      true -> ".bin"
    end
  end

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.replace("\x00", "")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> then(&Regex.replace(~r/\n{3,}/u, &1, "\n\n"))
    |> String.trim()
  end

  defp config_from_tool(%ToolInstance{} = tool_instance) do
    cfg = Map.get(tool_instance, :config) || %{}
    cfg = if is_map(cfg), do: cfg, else: %{}

    %{
      chunk_size_tokens:
        max(1, read_integer(cfg, "chunk_size_tokens", @default_chunk_size_tokens)),
      cache_ttl_seconds:
        max(0, read_integer(cfg, "cache_ttl_seconds", @default_cache_ttl_seconds)),
      cache_max_bytes: max(0, read_integer(cfg, "cache_max_bytes", @default_cache_max_bytes)),
      max_download_bytes:
        max(0, read_integer(cfg, "max_download_bytes", @default_max_download_bytes)),
      http_timeout_seconds:
        max(0.1, read_float(cfg, "http_timeout_seconds", @default_http_timeout_seconds)),
      extract_timeout_seconds:
        max(0.1, read_float(cfg, "extract_timeout_seconds", @default_extract_timeout_seconds)),
      user_agent: read_string(cfg, "user_agent", @default_user_agent),
      max_extract_chars:
        max(1, read_integer(cfg, "max_extract_chars", @default_max_extract_chars)),
      pdf_ocr_strategy: read_pdf_ocr_strategy(cfg, "pdf_ocr_strategy", @default_pdf_ocr_strategy)
    }
  end

  defp read_string_arg(args, key, default)
       when is_map(args) and is_binary(key) and is_binary(default) do
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

  defp read_string(cfg, key, default)
       when is_map(cfg) and is_binary(key) and is_binary(default) do
    case map_get(cfg, key) do
      nil -> default
      value -> to_string(value)
    end
  end

  defp read_integer(cfg, key, default)
       when is_map(cfg) and is_binary(key) and is_integer(default) do
    case coerce_optional_integer(map_get(cfg, key), default) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  defp read_float(cfg, key, default) when is_map(cfg) and is_binary(key) and is_number(default) do
    case map_get(cfg, key) do
      nil ->
        default

      value when is_number(value) ->
        value * 1.0

      value ->
        case Float.parse(to_string(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end

  defp read_pdf_ocr_strategy(cfg, key, default)
       when is_map(cfg) and is_binary(key) and is_binary(default) do
    value =
      cfg
      |> map_get(key)
      |> case do
        nil -> default
        other -> other |> to_string() |> String.trim() |> String.upcase()
      end

    if value in @supported_pdf_ocr_strategies, do: value, else: default
  end

  defp coerce_optional_integer(nil, default) when is_integer(default), do: {:ok, default}
  defp coerce_optional_integer(value, _default) when is_integer(value), do: {:ok, value}
  defp coerce_optional_integer(value, _default) when is_float(value), do: {:ok, trunc(value)}

  defp coerce_optional_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp coerce_optional_integer(_value, _default), do: {:error, :invalid_integer}

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case key do
        "page" -> Map.get(map, :page)
        "url" -> Map.get(map, :url)
        "regex" -> Map.get(map, :regex)
        "regex_flags" -> Map.get(map, :regex_flags)
        "snippet_len_chars" -> Map.get(map, :snippet_len_chars)
        "max_snippets" -> Map.get(map, :max_snippets)
        "chunk_size_tokens" -> Map.get(map, :chunk_size_tokens)
        "cache_ttl_seconds" -> Map.get(map, :cache_ttl_seconds)
        "cache_max_bytes" -> Map.get(map, :cache_max_bytes)
        "max_download_bytes" -> Map.get(map, :max_download_bytes)
        "http_timeout_seconds" -> Map.get(map, :http_timeout_seconds)
        "extract_timeout_seconds" -> Map.get(map, :extract_timeout_seconds)
        "user_agent" -> Map.get(map, :user_agent)
        "max_extract_chars" -> Map.get(map, :max_extract_chars)
        "pdf_ocr_strategy" -> Map.get(map, :pdf_ocr_strategy)
        "title" -> Map.get(map, :title)
        "pages_total" -> Map.get(map, :pages_total)
        _ -> nil
      end
  end

  defp map_get(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)

  defp first_header_value(headers, key) when is_map(headers) and is_binary(key) do
    case Map.get(headers, String.downcase(key)) || Map.get(headers, key) do
      [value | _rest] -> to_string(value)
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp first_header_value(_headers, _key), do: ""

  defp body_to_binary(body) when is_binary(body), do: body
  defp body_to_binary(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_to_binary(body) when is_map(body), do: Jason.encode!(body)
  defp body_to_binary(body), do: to_string(body)

  defp body_to_string(body), do: body_to_binary(body)

  defp pad_page_index(page) when is_integer(page),
    do: page |> Integer.to_string() |> String.pad_leading(4, "0")
end
