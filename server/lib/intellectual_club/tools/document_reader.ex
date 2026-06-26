defmodule IntellectualClub.Tools.DocumentReader do
  @moduledoc """
  Shared document extraction, pagination, cache, and search helpers for native tools.
  """

  alias IntellectualClub.TokenCounter
  alias PdfElixide.Document, as: PdfDocument

  @default_chunk_size_tokens 5_000
  @default_cache_ttl_seconds 86_400
  @default_cache_max_bytes 1 * 1024 * 1024 * 1024
  @default_extract_timeout_seconds 45.0
  @default_max_extract_chars 500_000

  def default_chunk_size_tokens, do: @default_chunk_size_tokens
  def default_cache_ttl_seconds, do: @default_cache_ttl_seconds
  def default_cache_max_bytes, do: @default_cache_max_bytes
  def default_extract_timeout_seconds, do: @default_extract_timeout_seconds
  def default_max_extract_chars, do: @default_max_extract_chars

  def config_from_map(cfg) when is_map(cfg) do
    %{
      chunk_size_tokens:
        max(1, read_integer(cfg, "chunk_size_tokens", @default_chunk_size_tokens)),
      cache_ttl_seconds:
        max(0, read_integer(cfg, "cache_ttl_seconds", @default_cache_ttl_seconds)),
      cache_max_bytes: max(0, read_integer(cfg, "cache_max_bytes", @default_cache_max_bytes)),
      extract_timeout_seconds:
        max(0.1, read_float(cfg, "extract_timeout_seconds", @default_extract_timeout_seconds)),
      max_extract_chars:
        max(1, read_integer(cfg, "max_extract_chars", @default_max_extract_chars))
    }
  end

  def config_from_map(_cfg), do: config_from_map(%{})

  def ensure_cache_ready(cache_root, lock_id, doc_id, cfg, source_fun)
      when is_binary(cache_root) and is_binary(doc_id) and is_map(cfg) and
             is_function(source_fun, 0) do
    doc_dir = Path.join(cache_root, doc_id)

    with :ok <- File.mkdir_p(cache_root) do
      if cache_valid?(doc_dir, cfg.cache_ttl_seconds) do
        {:ok, {doc_dir, read_meta(doc_dir), true}}
      else
        with_doc_lock(lock_id, doc_id, fn ->
          if cache_valid?(doc_dir, cfg.cache_ttl_seconds) do
            {:ok, {doc_dir, read_meta(doc_dir), true}}
          else
            cleanup_cache(cache_root, cfg.cache_ttl_seconds, cfg.cache_max_bytes)

            _ = File.rm_rf(doc_dir)

            case build_cache(doc_dir, cfg, source_fun) do
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

  def ensure_text_cache_ready(cache_root, lock_id, doc_id, text, source_meta, cfg)
      when is_binary(cache_root) and is_binary(doc_id) and is_binary(text) and
             is_map(source_meta) and is_map(cfg) do
    doc_dir = Path.join(cache_root, doc_id)

    with :ok <- File.mkdir_p(cache_root) do
      if cache_valid?(doc_dir, cfg.cache_ttl_seconds) do
        {:ok, {doc_dir, read_meta(doc_dir), true}}
      else
        with_doc_lock(lock_id, doc_id, fn ->
          if cache_valid?(doc_dir, cfg.cache_ttl_seconds) do
            {:ok, {doc_dir, read_meta(doc_dir), true}}
          else
            cleanup_cache(cache_root, cfg.cache_ttl_seconds, cfg.cache_max_bytes)

            _ = File.rm_rf(doc_dir)

            case build_text_cache(doc_dir, text, source_meta, cfg) do
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

  def parse_page(args) when is_map(args) do
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

  def required_regex(args) when is_map(args) do
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

  def compile_regex(regex_text, flags_text)
      when is_binary(regex_text) and is_binary(flags_text) do
    flags = sanitize_regex_flags(flags_text)

    case Regex.compile(regex_text, flags) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> {:error, "Invalid regex: #{inspect(reason)}"}
    end
  end

  def parse_snippet_len(args) when is_map(args) do
    case coerce_optional_integer(map_get(args, "snippet_len_chars"), 240) do
      {:ok, value} when value >= 1 -> {:ok, value}
      {:ok, _value} -> {:error, "Argument `snippet_len_chars` must be a positive integer."}
      {:error, _reason} -> {:error, "Argument `snippet_len_chars` must be an integer."}
    end
  end

  def parse_max_snippets(args) when is_map(args) do
    case coerce_optional_integer(map_get(args, "max_snippets"), 25) do
      {:ok, value} when value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, "Argument `max_snippets` must be a non-negative integer."}
      {:error, _reason} -> {:error, "Argument `max_snippets` must be an integer."}
    end
  end

  def read_string_arg(args, key, default)
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

  def collect_snippets(doc_dir, total_pages, regex, snippet_len_chars, max_snippets)
      when is_binary(doc_dir) and is_integer(total_pages) and total_pages >= 0 do
    if total_pages <= 0 do
      {[], []}
    else
      do_collect_snippets(doc_dir, total_pages, regex, snippet_len_chars, max_snippets)
    end
  end

  defp do_collect_snippets(doc_dir, total_pages, regex, snippet_len_chars, max_snippets) do
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

  def pages_total(doc_dir, meta) when is_binary(doc_dir) and is_map(meta) do
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

  def read_page_text(doc_dir, page) when is_binary(doc_dir) and is_integer(page) do
    path = Path.join([doc_dir, "pages", pad_page_index(page) <> ".md"])

    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> {:error, "Failed to read page #{page}."}
    end
  end

  def doc_id(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  def normalize_text(text) when is_binary(text) do
    text
    |> sanitize_binary_text()
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> then(&Regex.replace(~r/\n{3,}/u, &1, "\n\n"))
    |> String.trim()
  end

  def sanitize_binary_text(text) when is_binary(text) do
    text
    |> :binary.replace("\x00", "", [:global])
    |> ensure_valid_utf8()
  end

  def read_integer(cfg, key, default)
      when is_map(cfg) and is_binary(key) and is_integer(default) do
    case coerce_optional_integer(map_get(cfg, key), default) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  def read_float(cfg, key, default) when is_map(cfg) and is_binary(key) and is_number(default) do
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

  def read_string(cfg, key, default)
      when is_map(cfg) and is_binary(key) and is_binary(default) do
    case map_get(cfg, key) do
      nil -> default
      value -> to_string(value)
    end
  end

  def map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case key do
        "url" -> Map.get(map, :url)
        "page" -> Map.get(map, :page)
        "regex" -> Map.get(map, :regex)
        "regex_flags" -> Map.get(map, :regex_flags)
        "snippet_len_chars" -> Map.get(map, :snippet_len_chars)
        "max_snippets" -> Map.get(map, :max_snippets)
        "chunk_size_tokens" -> Map.get(map, :chunk_size_tokens)
        "cache_ttl_seconds" -> Map.get(map, :cache_ttl_seconds)
        "cache_max_bytes" -> Map.get(map, :cache_max_bytes)
        "extract_timeout_seconds" -> Map.get(map, :extract_timeout_seconds)
        "max_extract_chars" -> Map.get(map, :max_extract_chars)
        "pages_total" -> Map.get(map, :pages_total)
        _ -> nil
      end
  end

  def map_get(_map, _key), do: nil

  defp build_cache(doc_dir, cfg, source_fun) do
    with :ok <- File.mkdir_p(doc_dir),
         {:ok, {bytes, source_meta}} <- source_fun.(),
         {:ok, {extracted_text, extraction_meta}} <- extract_text(bytes, source_meta, cfg),
         :ok <- write_pages(doc_dir, split_to_pages(extracted_text, cfg.chunk_size_tokens)) do
      meta =
        source_meta
        |> Map.merge(extraction_meta)
        |> Map.merge(%{
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

  defp build_text_cache(doc_dir, text, source_meta, cfg)
       when is_binary(text) and is_map(source_meta) and is_map(cfg) do
    with :ok <- File.mkdir_p(doc_dir),
         normalized_text <- normalize_text(text),
         :ok <- write_pages(doc_dir, split_to_pages(normalized_text, cfg.chunk_size_tokens)) do
      meta =
        source_meta
        |> Map.merge(%{
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

  defp extract_text(bytes, source_meta, cfg)
       when is_binary(bytes) and is_map(source_meta) and is_map(cfg) do
    timeout_ms = cfg.extract_timeout_seconds |> Kernel.*(1000) |> trunc() |> max(1)

    case extract_with_timeout(bytes, source_meta, cfg, timeout_ms) do
      {:ok, {:ok, {text, metadata}}} ->
        metadata = if is_map(metadata), do: metadata, else: %{}

        extraction_meta =
          %{}
          |> maybe_put("metadata", metadata)

        {:ok, {text, extraction_meta}}

      {:ok, {:error, reason}} ->
        {:error, "Document extraction failed: #{format_reason(reason)}"}

      {:error, :timeout} ->
        seconds = Float.round(timeout_ms / 1000.0, 1)
        {:error, "Document extraction timed out after #{seconds} seconds."}

      {:error, {:exit, reason}} ->
        {:error, "Document extraction exited: #{Exception.format_exit(reason)}"}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  defp extract_with_timeout(bytes, source_meta, cfg, timeout_ms)
       when is_binary(bytes) and is_map(source_meta) and is_map(cfg) and is_integer(timeout_ms) do
    task = Task.async(fn -> extract_bytes(bytes, source_meta, cfg) end)

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

  defp extract_bytes(bytes, source_meta, cfg)
       when is_binary(bytes) and is_map(source_meta) and is_map(cfg) do
    cond do
      pdf_binary?(bytes) or pdf_source?(source_meta) ->
        extract_pdf_text(bytes, cfg)

      docx_source?(source_meta) ->
        extract_docx_text(bytes, cfg)

      html_source?(source_meta) or html_binary?(bytes) ->
        text =
          bytes
          |> extract_html_text()
          |> limit_chars(cfg.max_extract_chars)

        {:ok, {text, %{"extractor" => "html_text"}}}

      text_source?(source_meta) or looks_like_text?(bytes) ->
        text =
          bytes
          |> sanitize_binary_text()
          |> normalize_text()
          |> limit_chars(cfg.max_extract_chars)

        {:ok, {text, %{"extractor" => "plain_text"}}}

      true ->
        {:error, "Unsupported document type. Supported types: PDF, DOCX, HTML, and plain text."}
    end
  end

  defp extract_pdf_text(bytes, cfg) when is_binary(bytes) and is_map(cfg) do
    with {:ok, doc} <- PdfDocument.from_binary(bytes),
         {:ok, page_count} <- PdfDocument.page_count(doc),
         {:ok, {pages, truncated?}} <- extract_pdf_pages(doc, page_count, cfg.max_extract_chars) do
      text =
        pages
        |> Enum.join("\n\n")
        |> normalize_text()
        |> limit_chars(cfg.max_extract_chars)

      metadata =
        %{
          "extractor" => "pdf_elixide",
          "pdf_page_count" => page_count,
          "pdf_version" => format_pdf_version(PdfDocument.version(doc))
        }
        |> maybe_put("truncated", if(truncated?, do: true, else: nil))

      {:ok, {text, metadata}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_docx_text(bytes, cfg) when is_binary(bytes) and is_map(cfg) do
    with {:ok, document_xml} <- read_docx_document_xml(bytes),
         {:ok, paragraphs} <- docx_paragraphs(document_xml) do
      full_text =
        paragraphs
        |> Enum.join("\n\n")
        |> normalize_text()

      text = limit_chars(full_text, cfg.max_extract_chars)
      truncated? = String.length(full_text) > String.length(text)

      metadata =
        %{
          "extractor" => "docx_xml",
          "docx_paragraph_count" => length(paragraphs)
        }
        |> maybe_put("truncated", if(truncated?, do: true, else: nil))

      {:ok, {text, metadata}}
    end
  end

  defp read_docx_document_xml(bytes) when is_binary(bytes) do
    case :zip.extract(bytes, [:memory]) do
      {:ok, entries} ->
        entries
        |> Enum.find(fn {name, _content} -> to_string(name) == "word/document.xml" end)
        |> case do
          {_name, document_xml} when is_binary(document_xml) ->
            {:ok, document_xml}

          _other ->
            {:error, "DOCX archive does not contain word/document.xml."}
        end

      {:error, reason} ->
        {:error, "Invalid DOCX archive: #{inspect(reason)}"}
    end
  end

  defp docx_paragraphs(document_xml) when is_binary(document_xml) do
    initial_state = %{paragraphs: [], current: [], in_paragraph?: false, text_depth: 0}

    event_fun = fn event, _location, state ->
      handle_docx_sax_event(event, state)
    end

    document_xml
    |> sanitize_binary_text()
    |> String.to_charlist()
    |> then(
      &apply(:xmerl_sax_parser, :stream, [
        &1,
        [{:event_fun, event_fun}, {:event_state, initial_state}]
      ])
    )
    |> case do
      {:ok, state, _rest} ->
        paragraphs =
          state.paragraphs
          |> Enum.reverse()
          |> Enum.map(&normalize_text/1)
          |> Enum.reject(&(&1 == ""))

        {:ok, paragraphs}

      {:fatal_error, _location, reason, _state} ->
        {:error, "Invalid DOCX document XML: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Invalid DOCX document XML: #{inspect(reason)}"}

      other ->
        {:error, "Invalid DOCX document XML: #{inspect(other)}"}
    end
  catch
    :exit, reason ->
      {:error, "Invalid DOCX document XML: #{Exception.format_exit(reason)}"}
  end

  defp handle_docx_sax_event({:startElement, _uri, local_name, _qname, _attrs}, state) do
    cond do
      xml_local_name?(local_name, "p") ->
        %{state | in_paragraph?: true, current: [], text_depth: 0}

      state.in_paragraph? and xml_local_name?(local_name, "t") ->
        %{state | text_depth: state.text_depth + 1}

      state.in_paragraph? and xml_local_name?(local_name, "tab") ->
        append_docx_text(state, "\t")

      state.in_paragraph? and
          (xml_local_name?(local_name, "br") or xml_local_name?(local_name, "cr")) ->
        append_docx_text(state, "\n")

      true ->
        state
    end
  end

  defp handle_docx_sax_event({:endElement, _uri, local_name, _qname}, state) do
    cond do
      state.in_paragraph? and xml_local_name?(local_name, "p") ->
        paragraph =
          state.current
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        %{
          state
          | paragraphs: [paragraph | state.paragraphs],
            current: [],
            in_paragraph?: false,
            text_depth: 0
        }

      state.text_depth > 0 and xml_local_name?(local_name, "t") ->
        %{state | text_depth: state.text_depth - 1}

      true ->
        state
    end
  end

  defp handle_docx_sax_event({:characters, chars}, state)
       when state.in_paragraph? and state.text_depth > 0 do
    append_docx_text(state, chars)
  end

  defp handle_docx_sax_event(_event, state), do: state

  defp append_docx_text(state, chars) do
    %{state | current: [chars | state.current]}
  end

  defp xml_local_name?(name, expected) when is_list(name) and is_binary(expected) do
    name == String.to_charlist(expected)
  end

  defp xml_local_name?(name, expected) when is_binary(expected) do
    name
    |> to_string()
    |> String.split(":")
    |> List.last()
    |> Kernel.==(expected)
  end

  defp extract_pdf_pages(_doc, page_count, _max_chars) when page_count <= 0 do
    {:ok, {[], false}}
  end

  defp extract_pdf_pages(doc, page_count, max_chars)
       when is_integer(page_count) and is_integer(max_chars) do
    0..(page_count - 1)
    |> Enum.reduce_while({:ok, {[], 0, false}}, fn page_index, {:ok, {pages, char_count, _}} ->
      remaining = max(0, max_chars - char_count)

      if remaining == 0 do
        {:halt, {:ok, {pages, char_count, true}}}
      else
        case PdfDocument.extract_text(doc, page_index) do
          {:ok, page_text} ->
            text =
              page_text
              |> to_string()
              |> normalize_text()

            clipped = limit_chars(text, remaining)
            new_char_count = char_count + String.length(clipped)
            pages = pages ++ [clipped]

            truncated? =
              String.length(text) > String.length(clipped) or
                (new_char_count >= max_chars and page_index < page_count - 1)

            if truncated? or new_char_count >= max_chars do
              {:halt, {:ok, {pages, new_char_count, truncated?}}}
            else
              {:cont, {:ok, {pages, new_char_count, false}}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    end)
    |> case do
      {:ok, {pages, _char_count, truncated?}} -> {:ok, {pages, truncated?}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_html_text(bytes) when is_binary(bytes) do
    bytes
    |> sanitize_binary_text()
    |> String.replace(~r/<(script|style|noscript)\b[^>]*>.*?<\/\1>/isu, " ")
    |> String.replace(~r/<(br|hr)\b[^>]*>/iu, "\n")
    |> String.replace(
      ~r/<\/(p|div|section|article|header|footer|main|li|tr|h[1-6]|table|ul|ol|blockquote)>/iu,
      "\n"
    )
    |> String.replace(~r/<[^>]+>/u, " ")
    |> decode_html_entities()
    |> normalize_text()
  end

  defp decode_html_entities(text) when is_binary(text) do
    named_entities = %{
      "amp" => "&",
      "lt" => "<",
      "gt" => ">",
      "quot" => "\"",
      "apos" => "'",
      "nbsp" => " ",
      "ndash" => "-",
      "mdash" => "-",
      "hellip" => "...",
      "copy" => "(c)",
      "reg" => "(r)"
    }

    text =
      Regex.replace(~r/&([A-Za-z][A-Za-z0-9]+);/u, text, fn full, name ->
        Map.get(named_entities, String.downcase(name), full)
      end)

    Regex.replace(~r/&#(x?[0-9A-Fa-f]+);/u, text, fn full, value ->
      decode_numeric_entity(value, full)
    end)
  end

  defp decode_numeric_entity("x" <> value, fallback) do
    decode_numeric_entity(value, 16, fallback)
  end

  defp decode_numeric_entity(value, fallback) do
    decode_numeric_entity(value, 10, fallback)
  end

  defp decode_numeric_entity(value, base, fallback) do
    case Integer.parse(value, base) do
      {codepoint, ""} when codepoint in 0..0x10FFFF ->
        try do
          <<codepoint::utf8>>
        rescue
          ArgumentError -> fallback
        end

      _ ->
        fallback
    end
  end

  defp limit_chars(text, max_chars) when is_binary(text) and is_integer(max_chars) do
    String.slice(text, 0, max(0, max_chars))
  end

  defp pdf_binary?(<<"%PDF-", _rest::binary>>), do: true
  defp pdf_binary?(_bytes), do: false

  defp pdf_source?(source_meta) when is_map(source_meta) do
    source_type_contains?(source_meta, "application/pdf") or
      source_extension(source_meta) == ".pdf"
  end

  defp docx_source?(source_meta) when is_map(source_meta) do
    source_type_contains?(source_meta, "wordprocessingml.document") or
      source_extension(source_meta) == ".docx"
  end

  defp html_source?(source_meta) when is_map(source_meta) do
    source_type_contains?(source_meta, "html") or
      source_extension(source_meta) in [".html", ".htm"]
  end

  defp text_source?(source_meta) when is_map(source_meta) do
    source_type = source_type(source_meta)
    extension = source_extension(source_meta)

    String.contains?(source_type, "text/") or
      Enum.any?(
        [
          "application/json",
          "application/xml",
          "application/xhtml",
          "application/javascript",
          "application/x-javascript",
          "application/yaml",
          "application/x-yaml"
        ],
        &String.contains?(source_type, &1)
      ) or
      extension in ~w(.txt .text .md .markdown .json .jsonl .ndjson .csv .tsv .xml .yaml .yml .log)
  end

  defp source_type_contains?(source_meta, needle)
       when is_map(source_meta) and is_binary(needle) do
    source_meta
    |> source_type()
    |> String.contains?(needle)
  end

  defp source_type(source_meta) when is_map(source_meta) do
    [map_get(source_meta, "content_type"), map_get(source_meta, "mime_type")]
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp source_extension(source_meta) when is_map(source_meta) do
    source_meta
    |> map_get("source_extension")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp html_binary?(bytes) when is_binary(bytes) do
    sample =
      bytes
      |> binary_prefix(512)
      |> sanitize_binary_text()
      |> String.trim_leading()
      |> String.downcase()

    String.starts_with?(sample, "<!doctype html") or String.starts_with?(sample, "<html") or
      String.contains?(sample, "<body")
  end

  defp looks_like_text?(bytes) when is_binary(bytes) do
    sample = binary_prefix(bytes, 4096)

    cond do
      sample == "" ->
        true

      :binary.match(sample, <<0>>) != :nomatch ->
        false

      not String.valid?(sample) ->
        false

      true ->
        control_count =
          sample
          |> :binary.bin_to_list()
          |> Enum.count(fn byte ->
            byte < 32 and byte not in [9, 10, 12, 13]
          end)

        control_count / max(1, byte_size(sample)) < 0.05
    end
  end

  defp binary_prefix(bytes, max_bytes) when is_binary(bytes) and is_integer(max_bytes) do
    binary_part(bytes, 0, min(byte_size(bytes), max(0, max_bytes)))
  end

  defp format_pdf_version({major, minor}) when is_integer(major) and is_integer(minor) do
    "#{major}.#{minor}"
  end

  defp format_pdf_version(other), do: inspect(other)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

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

  defp with_doc_lock(lock_id, doc_id, fun)
       when is_binary(doc_id) and is_function(fun, 0) do
    lock = {{__MODULE__, lock_id, doc_id}, self()}

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)

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

  defp ensure_valid_utf8(text) when is_binary(text) do
    if String.valid?(text) do
      text
    else
      :unicode.characters_to_binary(text, :latin1, :utf8)
    end
  end

  defp pad_page_index(page) when is_integer(page),
    do: page |> Integer.to_string() |> String.pad_leading(4, "0")
end
