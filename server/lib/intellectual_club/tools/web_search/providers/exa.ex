defmodule IntellectualClub.Tools.WebSearch.Providers.Exa do
  @moduledoc "Exa search and clean live document contents."
  @behaviour IntellectualClub.Tools.WebSearch.Provider
  alias IntellectualClub.Tools.WebSearch.Http

  @impl true
  def search(cfg, args) do
    payload = %{
      "query" => args["query"],
      "numResults" => args["count"],
      "type" => "auto",
      "contents" => %{"highlights" => true}
    }

    payload =
      if args["country"], do: Map.put(payload, "userLocation", args["country"]), else: payload

    with {:ok, body} <- Http.request(cfg, :post, "/search", payload, {"x-api-key", cfg.token}) do
      Http.search_results(body["results"], "highlights")
    end
  end

  @impl true
  def fetch(cfg, urls, _tool) do
    payload = %{
      "urls" => urls,
      "text" => %{"verbosity" => "compact", "includeHtmlTags" => false},
      "maxAgeHours" => 0,
      "livecrawlTimeout" => min(15_000, cfg.timeout_ms)
    }

    with {:ok, body} <- Http.request(cfg, :post, "/contents", payload, {"x-api-key", cfg.token}) do
      Http.fetch_results(body, urls, "text", "statuses")
    end
  end
end
