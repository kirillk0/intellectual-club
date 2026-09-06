defmodule IntellectualClub.Tools.WebSearch.Providers.Firecrawl do
  @moduledoc "Firecrawl search and Markdown scraping with maximum cleaning."
  @behaviour IntellectualClub.Tools.WebSearch.Provider
  alias IntellectualClub.Tools.WebSearch.Http

  @impl true
  def search(cfg, args) do
    payload = %{
      "query" => args["query"],
      "limit" => args["count"],
      "sources" => ["web"],
      "timeout" => cfg.timeout_ms
    }

    payload = if args["country"], do: Map.put(payload, "country", args["country"]), else: payload

    with {:ok, body} <-
           Http.request(cfg, :post, "/search", payload, {"authorization", "Bearer " <> cfg.token}),
         {:ok, result} <- Http.search_results(get_in(body, ["data", "web"]), "description") do
      {:ok, %{result | warnings: Http.warnings(body)}}
    end
  end

  @impl true
  def fetch(cfg, urls, _tool) do
    {results, errors, warnings} =
      Enum.reduce(urls, {[], [], []}, fn url, {results, errors, warnings} ->
        payload = %{
          "url" => url,
          "formats" => ["markdown"],
          "onlyMainContent" => true,
          "onlyCleanContent" => true,
          "timeout" => min(120_000, cfg.timeout_ms)
        }

        case Http.request(
               cfg,
               :post,
               "/scrape",
               payload,
               {"authorization", "Bearer " <> cfg.token}
             ) do
          {:ok, %{"data" => %{"markdown" => text} = data} = body} when is_binary(text) ->
            if String.trim(text) == "" do
              {results,
               [
                 Map.put(Http.error("empty_content", "Page has no readable content."), :url, url)
                 | errors
               ], warnings}
            else
              metadata = if is_map(data["metadata"]), do: data["metadata"], else: %{}

              result = %{
                "url" => url,
                "final_url" => metadata["url"] || metadata["sourceURL"] || url,
                "title" => metadata["title"],
                "text" => text
              }

              {[result | results], errors,
               warnings ++ Http.warnings(body) ++ Http.warnings(data) ++ Http.warnings(metadata)}
            end

          {:ok, _} ->
            {results,
             [
               Map.put(
                 Http.error(
                   "invalid_response",
                   "Provider returned an unexpected response shape."
                 ),
                 :url,
                 url
               )
               | errors
             ], warnings}

          {:error, error} ->
            {results, [Map.put(error, :url, url) | errors], warnings}
        end
      end)

    {:ok, %{results: Enum.reverse(results), errors: Enum.reverse(errors), warnings: warnings}}
  end
end
