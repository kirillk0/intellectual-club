defmodule IntellectualClub.Tools.WebSearch.Providers.Tavily do
  @moduledoc "Tavily search and advanced Markdown extraction."
  @behaviour IntellectualClub.Tools.WebSearch.Provider
  alias IntellectualClub.Tools.WebSearch.Http

  @impl true
  def search(cfg, args) do
    payload = %{
      "query" => args["query"],
      "max_results" => min(args["count"], 20),
      "search_depth" => "advanced",
      "include_answer" => false
    }

    with {:ok, body} <-
           Http.request(cfg, :post, "/search", payload, {"authorization", "Bearer " <> cfg.token}),
         {:ok, result} <- Http.search_results(body["results"], "content") do
      {:ok, %{result | warnings: Http.warnings(body)}}
    end
  end

  @impl true
  def fetch(cfg, urls, _tool) do
    payload = %{
      "urls" => urls,
      "extract_depth" => "advanced",
      "format" => "markdown",
      "timeout" => min(60.0, max(1.0, cfg.timeout_ms / 1000))
    }

    with {:ok, body} <-
           Http.request(
             cfg,
             :post,
             "/extract",
             payload,
             {"authorization", "Bearer " <> cfg.token}
           ) do
      Http.fetch_results(body, urls, "raw_content", "failed_results")
    end
  end
end
