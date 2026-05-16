defmodule IntellectualClub.Tools.Drivers.NativeWebReader do
  @moduledoc """
  Native web reader driver.

  This is a fixed-function tool that exposes `read_url` and `search_url`.
  The driver fetches HTTP(S) documents and uses shared document reader helpers
  for extraction, pagination, caching, and regex search.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Tools.DocumentReader
  alias IntellectualClub.Tools.ToolInstance

  @default_max_download_bytes 100 * 1024 * 1024
  @default_http_timeout_seconds 30.0
  @default_user_agent "IntellectualClubWebReader/0.1"

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
      "chunk_size_tokens" => DocumentReader.default_chunk_size_tokens(),
      "cache_ttl_seconds" => DocumentReader.default_cache_ttl_seconds(),
      "cache_max_bytes" => DocumentReader.default_cache_max_bytes(),
      "max_download_bytes" => @default_max_download_bytes,
      "http_timeout_seconds" => @default_http_timeout_seconds,
      "extract_timeout_seconds" => DocumentReader.default_extract_timeout_seconds(),
      "user_agent" => @default_user_agent,
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
         {:ok, page} <- DocumentReader.parse_page(args),
         {:ok, {doc_dir, meta, cached}} <- ensure_cache_ready(tool_instance, normalized_url, cfg) do
      total_pages = DocumentReader.pages_total(doc_dir, meta)
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
          case DocumentReader.read_page_text(doc_dir, used_page) do
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
                "config" => config_raw(cfg)
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
         {:ok, regex_text} <- DocumentReader.required_regex(args),
         {:ok, regex} <-
           DocumentReader.compile_regex(
             regex_text,
             DocumentReader.read_string_arg(args, "regex_flags", "im")
           ),
         {:ok, snippet_len_chars} <- DocumentReader.parse_snippet_len(args),
         {:ok, max_snippets} <- DocumentReader.parse_max_snippets(args),
         {:ok, {doc_dir, meta, cached}} <- ensure_cache_ready(tool_instance, normalized_url, cfg) do
      total_pages = DocumentReader.pages_total(doc_dir, meta)
      final_url = to_string(Map.get(meta, "final_url") || normalized_url)
      regex_flags = DocumentReader.read_string_arg(args, "regex_flags", "im")

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

  defp ensure_cache_ready(%ToolInstance{} = tool_instance, normalized_url, cfg) do
    cache_root = cache_root(tool_instance)
    doc_id = DocumentReader.doc_id(normalized_url)

    DocumentReader.ensure_cache_ready(cache_root, tool_instance.id, doc_id, cfg, fn ->
      download_to_binary(normalized_url, cfg)
    end)
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
          "tool_type" => type(),
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

  defp required_url(args) when is_map(args) do
    url =
      args
      |> DocumentReader.map_get("url")
      |> to_string()
      |> String.trim()

    if url == "" do
      {:error, "Argument `url` is required."}
    else
      {:ok, url}
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

  defp config_from_tool(%ToolInstance{} = tool_instance) do
    cfg = Map.get(tool_instance, :config) || %{}
    cfg = if is_map(cfg), do: cfg, else: %{}
    doc_cfg = DocumentReader.config_from_map(cfg)

    Map.merge(doc_cfg, %{
      max_download_bytes:
        max(
          0,
          DocumentReader.read_integer(cfg, "max_download_bytes", @default_max_download_bytes)
        ),
      http_timeout_seconds:
        max(
          0.1,
          DocumentReader.read_float(cfg, "http_timeout_seconds", @default_http_timeout_seconds)
        ),
      user_agent: DocumentReader.read_string(cfg, "user_agent", @default_user_agent)
    })
  end

  defp config_raw(cfg) when is_map(cfg) do
    %{
      "chunk_size_tokens" => cfg.chunk_size_tokens,
      "cache_ttl_seconds" => cfg.cache_ttl_seconds,
      "cache_max_bytes" => cfg.cache_max_bytes,
      "max_download_bytes" => cfg.max_download_bytes,
      "max_extract_chars" => cfg.max_extract_chars
    }
  end

  defp cache_root(%ToolInstance{} = tool_instance) do
    tmp = System.tmp_dir!() || "/tmp"
    Path.join([tmp, "club_web_reader_cache", "tool_#{tool_instance.id}"])
  end

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

  defp body_to_string(body) do
    body
    |> body_to_binary()
    |> DocumentReader.sanitize_binary_text()
  end
end
