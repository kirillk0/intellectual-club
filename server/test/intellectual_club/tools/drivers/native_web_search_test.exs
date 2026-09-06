defmodule IntellectualClub.Tools.Drivers.NativeWebSearchTest do
  use IntellectualClub.DataCase, async: false
  alias IntellectualClub.Tools.{ToolInstance, Executor}
  alias IntellectualClub.Tools.Drivers.NativeWebSearch, as: Driver
  alias IntellectualClub.TestSupport.WebSearchServer

  test "search falls through HTTP and credential errors, redacts keys, and preserves diagnostics when truncated" do
    base =
      server(fn
        "/brave/web/search", _ ->
          {402, %{"error" => "Credits exhausted: secret-brave"}}

        "/exa/search", _ ->
          {200,
           %{
             "results" => [
               %{
                 "url" => "https://example.org",
                 "title" => "Example",
                 "highlights" => [String.duplicate("content ", 100)]
               }
             ]
           }}
      end)

    tool =
      tool(base, ~w(brave tavily exa), %{
        "brave_api_key" => "secret-brave",
        "exa_api_key" => "secret-exa"
      })

    assert {:ok, result} = Driver.execute(tool, "web_search", %{"query" => "example"})
    refute result.raw["isError"]
    assert length(result.raw["warnings"]) == 2
    assert Enum.map(result.raw["attempts"], & &1["provider"]) == ~w(brave tavily exa)
    assert result.text =~ "[REDACTED]"
    refute result.text =~ "secret-brave"
    limited = Executor.limit_execution_result(result, 20)
    assert limited.raw["truncated"]
    assert limited.raw["attempts"] == result.raw["attempts"]
    assert limited.raw["warnings"] == result.raw["warnings"]
    assert_receive {:web_request, "/brave/web/search", _, _}
    assert_receive {:web_request, "/exa/search", _, _}
    refute_receive {:web_request, "/brave/web/search", _, _}
  end

  test "valid empty results stop fallback while malformed results do not" do
    base =
      server(fn
        "/brave/web/search", %{"q" => "empty"} -> {200, %{"web" => %{"results" => []}}}
        "/brave/web/search", _ -> {200, %{"unexpected" => true}}
        "/tavily/search", _ -> {200, %{"results" => []}}
      end)

    tool = tool(base, ~w(brave tavily))
    assert {:ok, empty} = Driver.execute(tool, "web_search", %{"query" => "empty"})
    refute empty.raw["isError"]
    assert length(empty.raw["attempts"]) == 1
    assert {:ok, malformed} = Driver.execute(tool, "web_search", %{"query" => "malformed"})
    refute malformed.raw["isError"]
    assert length(malformed.raw["attempts"]) == 2
  end

  test "filters are not silently dropped and invalid arguments make no requests" do
    base =
      server(fn "/brave/web/search", params ->
        assert params["offset"] == "2"
        assert params["safesearch"] == "strict"
        {200, %{"web" => %{"results" => []}}}
      end)

    tool = tool(base, ~w(tavily brave))
    assert {:error, _} = Driver.execute(tool, "web_search", %{"query" => %{"bad" => true}})
    assert {:error, _} = Driver.execute(tool, "web_fetch", %{"urls" => ["file:///tmp/private"]})
    refute_receive {:web_request, _, _, _}

    assert {:ok, result} =
             Driver.execute(tool, "web_search", %{
               "query" => "q",
               "offset" => 2,
               "safesearch" => "strict"
             })

    assert hd(result.raw["attempts"])["code"] == "unsupported_parameters"
    refute result.raw["isError"]
  end

  test "fetch retries only failed URLs and preserves input order across providers" do
    urls = ["https://example.org/good", "https://example.org/bad"]

    base =
      server(fn
        "/tavily/extract",
        %{"urls" => [url], "extract_depth" => "advanced", "format" => "markdown"} ->
          if String.ends_with?(url, "/good"),
            do: {200, %{"results" => [%{"url" => url, "raw_content" => "First page"}]}},
            else:
              {200,
               %{"results" => [], "failed_results" => [%{"url" => url, "error" => "blocked"}]}}

        "/tinyfish-fetch", %{"urls" => [url], "format" => "markdown"} ->
          assert String.ends_with?(url, "/bad")
          {200, %{"results" => [%{"url" => url, "text" => "Second page"}]}}
      end)

    assert {:ok, result} =
             Driver.execute(tool(base, ~w(tavily tinyfish)), "web_fetch", %{
               "urls" => urls ++ [hd(urls)]
             })

    assert Enum.map(result.raw["results"], & &1["url"]) == urls
    assert Enum.map(result.raw["results"], & &1["provider"]) == ~w(tavily tinyfish)
    assert length(result.raw["attempts"]) == 3
    assert length(result.raw["warnings"]) == 1
    refute result.raw["isError"]
  end

  test "Brave fetch reads a complete cached document without credentials or exposing auth headers" do
    text = String.duplicate("Readable paragraph. ", 10_000) <> "FINAL_MARKER"
    base = server(fn "/document", _ -> {200, "text/plain", text} end)
    tool = tool(base, ["brave"], %{})

    for cached <- [false, true] do
      assert {:ok, result} = Driver.execute(tool, "web_fetch", %{"urls" => [base <> "/document"]})
      refute result.raw["isError"]
      assert result.text =~ "FINAL_MARKER"
      assert hd(result.raw["results"])["cached"] == cached
      assert hd(result.raw["attempts"])["backend"] == "web_reader"
      assert result.raw["warnings"] == []
    end

    assert_receive {:web_request, "/document", _, headers}

    refute Enum.any?(headers, fn {key, _} ->
             key in ["x-subscription-token", "authorization", "x-api-key"]
           end)

    refute_receive {:web_request, "/document", _, _}
  end

  test "local reader failures fall through to a remote reader and vice versa" do
    base =
      server(fn
        "/blocked", _ ->
          {403, "text/plain", "Blocked: private-error-body-marker"}

        "/readable", _ ->
          {200, "text/plain", "Local result"}

        "/tavily/extract", %{"urls" => [url]} ->
          if String.ends_with?(url, "/blocked"),
            do: {200, %{"results" => [%{"url" => url, "raw_content" => "Remote result"}]}},
            else: {500, %{}}
      end)

    assert {:ok, remote} =
             Driver.execute(tool(base, ~w(brave tavily)), "web_fetch", %{
               "urls" => [base <> "/blocked"]
             })

    assert hd(remote.raw["results"])["provider"] == "tavily"
    assert hd(remote.raw["attempts"])["http_status"] == 403
    refute remote.text =~ "private-error-body-marker"
    refute Jason.encode!(remote.raw) =~ "private-error-body-marker"

    assert {:ok, local} =
             Driver.execute(tool(base, ~w(tavily brave)), "web_fetch", %{
               "urls" => [base <> "/readable"]
             })

    assert hd(local.raw["results"])["backend"] == "web_reader"
  end

  test "attempt deadlines trigger fallback without retrying the stalled provider" do
    parent = self()

    base =
      server(fn
        "/brave/web/search", _ -> {:wait, parent}
        "/exa/search", _ -> {200, %{"results" => []}}
      end)

    tool = tool(base, ~w(brave exa))
    tool = %{tool | config: Map.put(tool.config, "timeout_seconds", 0.1)}
    assert {:ok, result} = Driver.execute(tool, "web_search", %{"query" => "q"})
    refute result.raw["isError"]
    assert hd(result.raw["attempts"])["code"] in ["timeout", "transport_error"]
    assert_receive {:waiting, handler}
    send(handler, :continue)
    assert length(result.raw["attempts"]) == 2
  end

  test "Exa and Firecrawl request maximum cleaning and preserve provider warnings" do
    base =
      server(fn
        "/exa/contents", payload ->
          assert payload["maxAgeHours"] == 0
          assert payload["text"] == %{"verbosity" => "compact", "includeHtmlTags" => false}

          {200,
           %{
             "results" => [
               %{
                 "id" => hd(payload["urls"]),
                 "url" => "https://example.org/final",
                 "text" => "Exa content"
               }
             ]
           }}

        "/firecrawl/scrape", payload ->
          assert payload["onlyCleanContent"] and payload["onlyMainContent"]
          assert payload["formats"] == ["markdown"]

          {200,
           %{
             "data" => %{"markdown" => "Clean content", "metadata" => %{"title" => "Title"}},
             "warning" => "Cleaning limit reached"
           }}
      end)

    for provider <- ~w(exa firecrawl) do
      assert {:ok, result} =
               Driver.execute(tool(base, [provider]), "web_fetch", %{
                 "urls" => ["https://example.org"]
               })

      refute result.raw["isError"]
      if provider == "firecrawl", do: assert(result.text =~ "Cleaning limit reached")
    end
  end

  test "all errors and partial results are distinguished" do
    base =
      server(fn
        "/good", _ -> {200, "text/plain", "Good content"}
        _, _ -> {500, %{}}
      end)

    tool = tool(base, ["brave"], %{})
    assert {:ok, failed} = Driver.execute(tool, "web_fetch", %{"urls" => [base <> "/bad"]})
    assert failed.raw["isError"]

    assert {:ok, partial} =
             Driver.execute(tool, "web_fetch", %{"urls" => [base <> "/bad", base <> "/good"]})

    refute partial.raw["isError"]
    assert length(partial.raw["errors"]) == 1
    assert length(partial.raw["results"]) == 1
  end

  test "validates chain length, uniqueness, endpoints and numeric settings" do
    for config <- [
          %{"providers" => []},
          %{"providers" => ~w(brave brave)},
          %{"providers" => ~w(brave tavily tinyfish exa)},
          %{"providers" => ["unknown"]},
          %{"timeout_seconds" => 0},
          %{
            "provider_options" => %{
              "brave" => %{"api_base_url" => "https://secret:password@example.org"}
            }
          }
        ] do
      assert {:error, _} = Driver.validate_config(%ToolInstance{}, config, nil)
    end

    assert :ok = Driver.validate_config(%ToolInstance{}, %{}, nil)
  end

  defp tool(base, providers, secrets \\ nil) do
    secrets = secrets || Map.new(providers, &{&1 <> "_api_key", "secret-" <> &1})
    options = Map.new(providers, &{&1, %{"api_base_url" => base <> "/" <> &1}})

    options =
      if "tinyfish" in providers,
        do: put_in(options, ["tinyfish", "fetch_api_base_url"], base <> "/tinyfish-fetch"),
        else: options

    tool = %ToolInstance{
      id: System.unique_integer([:positive, :monotonic]),
      type: Driver.type(),
      config: %{"providers" => providers, "provider_options" => options},
      secrets: secrets
    }

    on_exit(fn ->
      File.rm_rf(Path.join([System.tmp_dir!(), "club_web_reader_cache", "tool_#{tool.id}"]))
    end)

    tool
  end

  defp server(handler) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    start_supervised!(
      {Bandit,
       plug: {WebSearchServer, handler: handler, test_pid: self()}, scheme: :http, port: port}
    )

    "http://127.0.0.1:#{port}"
  end
end
