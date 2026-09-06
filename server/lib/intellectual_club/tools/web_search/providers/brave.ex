defmodule IntellectualClub.Tools.WebSearch.Providers.Brave do
  @moduledoc "Brave search with the built-in document reader for URL retrieval."
  @behaviour IntellectualClub.Tools.WebSearch.Provider
  alias IntellectualClub.Tools.{WebDocumentReader, WebSearch.Http}

  @impl true
  def search(cfg, args) do
    params =
      args
      |> Map.take(["country", "search_lang", "safesearch", "offset", "count"])
      |> Map.put("q", args["query"])

    with {:ok, body} <-
           Http.request(cfg, :get, "/web/search", params, {"x-subscription-token", cfg.token}) do
      case body do
        %{"web" => %{"results" => results}} ->
          Http.search_results(results, "description")

        %{"type" => "search", "query" => query} when is_map(query) ->
          Http.search_results([], "description")

        _ ->
          Http.invalid_response()
      end
    end
  end

  @impl true
  def fetch(cfg, urls, tool) do
    options = %{
      "http_timeout_seconds" => min(30.0, cfg.timeout_ms / 1000),
      "user_agent" => cfg.user_agent,
      "http_retry" => false
    }

    {results, errors} =
      Enum.reduce(urls, {[], []}, fn url, {results, errors} ->
        case WebDocumentReader.fetch_document(tool, url, options) do
          {:ok, result} ->
            {[result | results], errors}

          {:error, message} ->
            {results, [Map.put(reader_error(message), :url, url) | errors]}
        end
      end)

    {:ok, %{results: Enum.reverse(results), errors: Enum.reverse(errors), warnings: []}}
  end

  defp reader_error(message) when is_binary(message) do
    case Regex.run(~r/^HTTP error while fetching URL: (\d{3})\./, message) do
      [_, status] ->
        Http.error(
          "http_error",
          "HTTP #{status}: Web Reader could not fetch the page.",
          String.to_integer(status)
        )

      _ ->
        safe_message =
          cond do
            String.contains?(message, "max_download_bytes") ->
              "Document exceeds the download or decompression limit."

            String.starts_with?(message, "Unsupported") ->
              "Unsupported document type or content encoding."

            String.starts_with?(message, "Document extraction timed out") ->
              "Document extraction timed out."

            String.starts_with?(message, "Document extraction") ->
              "Document extraction failed."

            message == "Document has no readable content." ->
              message

            message == "Invalid gzip response body." ->
              message

            true ->
              "Web Reader could not load or extract the document."
          end

        Http.error("reader_error", safe_message)
    end
  end

  defp reader_error(_), do: Http.error("reader_error", "Web Reader could not read the document.")
end
