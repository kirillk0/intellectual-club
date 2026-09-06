defmodule IntellectualClub.Tools.WebDocumentReader do
  @moduledoc "Shared HTTP document loading, extraction, and caching for web tools."

  alias IntellectualClub.Tools.{DocumentReader, ToolInstance}

  @default_max_download_bytes 100 * 1024 * 1024
  @default_http_timeout_seconds 30.0
  @default_user_agent "IntellectualClubWebReader/0.1"
  @unsupported_url_suffixes ~w(
    .7z
    .bz2
    .csv.gz
    .gz
    .gzip
    .jsonl.gz
    .ndjson.gz
    .rar
    .tar
    .tar.bz2
    .tar.gz
    .tar.xz
    .tar.zst
    .tbz
    .tgz
    .tsv.gz
    .txz
    .xz
    .zip
    .zst
  )
  @unsupported_content_type_parts ~w(
    application/gzip
    application/zip
    application/x-7z-compressed
    application/x-bzip
    application/x-bzip2
    application/x-gzip
    application/x-rar-compressed
    application/x-tar
    application/x-xz
    application/zstd
  )

  def default_config do
    %{
      "chunk_size_tokens" => DocumentReader.default_chunk_size_tokens(),
      "cache_ttl_seconds" => DocumentReader.default_cache_ttl_seconds(),
      "cache_max_bytes" => DocumentReader.default_cache_max_bytes(),
      "max_download_bytes" => @default_max_download_bytes,
      "http_timeout_seconds" => @default_http_timeout_seconds,
      "extract_timeout_seconds" => DocumentReader.default_extract_timeout_seconds(),
      "user_agent" => @default_user_agent,
      "max_extract_chars" => DocumentReader.default_max_extract_chars()
    }
  end

  def fetch_document(%ToolInstance{} = tool, url, options \\ %{}) do
    cfg = config_from_tool(%{tool | config: Map.merge(default_config(), options)})

    with {:ok, normalized} <- normalize_url(url),
         :ok <- reject_unsupported_download(normalized),
         {:ok, {dir, meta, cached}} <- ensure_cache_ready(tool, normalized, cfg),
         {:ok, text} <- read_document(dir, DocumentReader.pages_total(dir, meta)) do
      if String.trim(text) == "" do
        {:error, "Document has no readable content."}
      else
        {:ok,
         %{
           "url" => normalized,
           "final_url" => Map.get(meta, "final_url", normalized),
           "title" => Map.get(meta, "title"),
           "text" => text,
           "cached" => cached,
           "content_type" => Map.get(meta, "content_type"),
           "truncated" =>
             get_in(meta, ["metadata", "truncated"]) == true or
               String.length(text) >= cfg.max_extract_chars
         }}
      end
    end
  end

  defp read_document(_dir, total) when total <= 0, do: {:ok, ""}

  defp read_document(dir, total) do
    Enum.reduce_while(1..total, {:ok, []}, fn page, {:ok, parts} ->
      case DocumentReader.read_page_text(dir, page) do
        {:ok, text} -> {:cont, {:ok, [text | parts]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join("\n\n")}
      error -> error
    end
  end

  def ensure_cache_ready(%ToolInstance{} = tool_instance, normalized_url, cfg) do
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
      {"accept", "*/*"},
      {"accept-encoding", "gzip"}
    ]

    {request, resp} =
      Req.run!(
        method: :get,
        url: url,
        headers: headers,
        redirect: true,
        decode_body: false,
        into: limited_body_stream(cfg.max_download_bytes),
        receive_timeout: timeout_ms,
        retry: Map.get(cfg, :http_retry, :safe_transient)
      )

    with {:ok, resp} <- finalize_streamed_body(resp),
         {:ok, body} <- decode_http_body(resp, cfg.max_download_bytes) do
      if resp.status >= 400 do
        body_text = body_to_string(body)

        {:error,
         "HTTP error while fetching URL: #{resp.status}. #{String.slice(body_text, 0, 500)}"}
      else
        content_type = first_header_value(resp.headers, "content-type")

        with :ok <- reject_unsupported_content_type(content_type, url) do
          meta = %{
            "tool_type" => "native-web-reader",
            "url" => url,
            "final_url" => URI.to_string(request.url),
            "content_type" => content_type,
            "status_code" => resp.status,
            "download_bytes" => byte_size(body),
            "source_extension" => guess_extension(content_type, url)
          }

          {:ok, {body, meta}}
        end
      end
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    :exit, reason ->
      {:error, Exception.format_exit(reason)}
  end

  defp limited_body_stream(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    fn {:data, data}, {request, response} ->
      bytes = Map.get(response.private, :web_reader_download_bytes, 0) + byte_size(data)

      if bytes > max_bytes do
        response = put_in(response.private[:web_reader_download_limit_exceeded], true)
        {:halt, {request, response}}
      else
        chunks = Map.get(response.private, :web_reader_download_chunks, [])

        response =
          response
          |> put_in([Access.key(:private), :web_reader_download_bytes], bytes)
          |> put_in([Access.key(:private), :web_reader_download_chunks], [data | chunks])

        {:cont, {request, response}}
      end
    end
  end

  defp finalize_streamed_body(%Req.Response{} = response) do
    if Map.get(response.private, :web_reader_download_limit_exceeded, false) do
      {:error, "Download exceeds max_download_bytes limit."}
    else
      body =
        response.private
        |> Map.get(:web_reader_download_chunks, [])
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      {:ok, %{response | body: body}}
    end
  end

  defp decode_http_body(%Req.Response{} = response, max_bytes) do
    encodings =
      response
      |> Req.Response.get_header("content-encoding")
      |> Enum.flat_map(&String.split(&1, ",", trim: true))
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 in ["", "identity"]))

    case encodings do
      [] ->
        {:ok, response.body}

      [encoding] when encoding in ["gzip", "x-gzip"] ->
        gunzip_with_limit(response.body, max_bytes)

      _other ->
        {:error, "Unsupported HTTP Content-Encoding: #{Enum.join(encodings, ", ")}."}
    end
  end

  defp gunzip_with_limit(compressed, max_bytes)
       when is_binary(compressed) and is_integer(max_bytes) and max_bytes > 0 do
    zstream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zstream, 31)

      with {:ok, chunks, _bytes} <- inflate_with_limit(zstream, compressed, max_bytes, 0, []),
           :ok <- :zlib.inflateEnd(zstream) do
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      else
        {:error, :limit_exceeded} ->
          {:error, "Decompressed body exceeds max_download_bytes limit."}
      end
    rescue
      ErlangError ->
        {:error, "Invalid gzip response body."}
    after
      :zlib.close(zstream)
    end
  end

  defp inflate_with_limit(zstream, input, max_bytes, bytes, chunks) do
    case :zlib.safeInflate(zstream, input) do
      {status, output} when status in [:continue, :finished] ->
        output_bytes = IO.iodata_length(output)
        total_bytes = bytes + output_bytes

        cond do
          total_bytes > max_bytes ->
            {:error, :limit_exceeded}

          status == :continue ->
            inflate_with_limit(zstream, <<>>, max_bytes, total_bytes, [output | chunks])

          true ->
            {:ok, [output | chunks], total_bytes}
        end

      {:need_dictionary, _adler, _output} ->
        :erlang.error(:data_error)
    end
  end

  def required_url(args) when is_map(args) do
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

  def normalize_url(raw_url) when is_binary(raw_url) do
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

  def normalize_url(_other), do: {:error, "Argument `url` must be a string."}

  def reject_unsupported_download(url) when is_binary(url) do
    path =
      url
      |> URI.parse()
      |> Map.get(:path)
      |> to_string()
      |> String.downcase()

    if Enum.any?(@unsupported_url_suffixes, &String.ends_with?(path, &1)) do
      {:error, unsupported_download_message()}
    else
      :ok
    end
  end

  defp reject_unsupported_content_type(content_type, url) do
    normalized =
      content_type
      |> to_string()
      |> String.downcase()

    if docx_url?(url) and String.contains?(normalized, "application/zip") do
      :ok
    else
      if Enum.any?(@unsupported_content_type_parts, &String.contains?(normalized, &1)) do
        {:error, unsupported_download_message()}
      else
        :ok
      end
    end
  end

  defp docx_url?(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> to_string()
    |> String.downcase()
    |> String.ends_with?(".docx")
  end

  defp docx_url?(_url), do: false

  defp unsupported_download_message do
    "Web Reader does not support compressed archives or bulk data dumps. Use a smaller HTML, PDF, DOCX, or text endpoint instead."
  end

  defp guess_extension(content_type, url) do
    ct = content_type |> to_string() |> String.downcase()
    path = URI.parse(url).path |> to_string() |> String.downcase()

    cond do
      String.contains?(ct, "application/pdf") -> ".pdf"
      String.contains?(ct, "wordprocessingml.document") -> ".docx"
      String.contains?(ct, "text/html") or String.contains?(ct, "application/xhtml") -> ".html"
      String.ends_with?(path, ".pdf") -> ".pdf"
      String.ends_with?(path, ".docx") -> ".docx"
      String.ends_with?(path, ".html") or String.ends_with?(path, ".htm") -> ".html"
      true -> ".bin"
    end
  end

  def config_from_tool(%ToolInstance{} = tool_instance) do
    cfg = Map.get(tool_instance, :config) || %{}
    cfg = if is_map(cfg), do: cfg, else: %{}
    doc_cfg = DocumentReader.config_from_map(cfg)

    Map.merge(doc_cfg, %{
      max_download_bytes: max_download_bytes(cfg),
      http_retry: Map.get(cfg, "http_retry", :safe_transient),
      http_timeout_seconds:
        max(
          0.1,
          DocumentReader.read_float(cfg, "http_timeout_seconds", @default_http_timeout_seconds)
        ),
      user_agent: DocumentReader.read_string(cfg, "user_agent", @default_user_agent)
    })
  end

  defp max_download_bytes(cfg) when is_map(cfg) do
    case DocumentReader.read_integer(cfg, "max_download_bytes", @default_max_download_bytes) do
      value when value > 0 -> value
      _other -> @default_max_download_bytes
    end
  end

  def config_raw(cfg) when is_map(cfg) do
    %{
      "chunk_size_tokens" => cfg.chunk_size_tokens,
      "cache_ttl_seconds" => cfg.cache_ttl_seconds,
      "cache_max_bytes" => cfg.cache_max_bytes,
      "max_download_bytes" => cfg.max_download_bytes,
      "max_extract_chars" => cfg.max_extract_chars
    }
  end

  defp cache_root(%ToolInstance{} = tool_instance) do
    tmp = System.tmp_dir!()
    Path.join([tmp, "club_web_reader_cache", "tool_#{tool_instance.id}"])
  end

  defp first_header_value(headers, key) when is_map(headers) and is_binary(key) do
    normalized_key = String.downcase(key)

    headers
    |> Enum.find_value(fn {header_key, value} ->
      if String.downcase(to_string(header_key)) == normalized_key do
        header_value_to_string(value)
      end
    end)
    |> case do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp first_header_value(headers, key) when is_list(headers) and is_binary(key) do
    normalized_key = String.downcase(key)

    headers
    |> Enum.find_value(fn
      {header_key, value} ->
        if String.downcase(to_string(header_key)) == normalized_key do
          header_value_to_string(value)
        end

      _other ->
        nil
    end)
    |> case do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp first_header_value(_headers, _key), do: ""

  defp header_value_to_string([value | _rest]), do: to_string(value)
  defp header_value_to_string(value) when is_binary(value), do: value
  defp header_value_to_string(value) when not is_nil(value), do: to_string(value)
  defp header_value_to_string(_value), do: nil

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
