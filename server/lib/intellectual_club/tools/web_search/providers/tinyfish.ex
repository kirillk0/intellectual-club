defmodule IntellectualClub.Tools.WebSearch.Providers.Tinyfish do
  @moduledoc "TinyFish Search and Fetch APIs."
  @behaviour IntellectualClub.Tools.WebSearch.Provider
  alias IntellectualClub.Tools.WebSearch.Http

  @impl true
  def search(cfg, args) do
    params = %{"query" => args["query"]}

    params =
      Enum.reduce([{"country", "location"}, {"search_lang", "language"}], params, fn {source,
                                                                                      target},
                                                                                     params ->
        if args[source], do: Map.put(params, target, args[source]), else: params
      end)

    with {:ok, body} <- Http.request(cfg, :get, "", params, {"x-api-key", cfg.token}) do
      Http.search_results(body["results"], "snippet")
    end
  end

  @impl true
  def fetch(cfg, urls, _tool) do
    payload = %{
      "urls" => urls,
      "format" => "markdown",
      "per_url_timeout_ms" => min(110_000, cfg.timeout_ms)
    }

    with {:ok, body} <-
           Http.request(
             %{cfg | api_base_url: cfg.fetch_api_base_url},
             :post,
             "",
             payload,
             {"x-api-key", cfg.token}
           ) do
      Http.fetch_results(body, urls, "text")
    end
  end
end
