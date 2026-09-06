defmodule IntellectualClub.Tools.Drivers.NativeWebSearch do
  @moduledoc "Provider-independent web search and fetch with an ordered fallback chain."
  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Tools.{ExecutionResult, ToolInstance, WebDocumentReader}
  alias IntellectualClub.Tools.WebSearch.{Http, Providers}

  @providers %{
    "brave" => {Providers.Brave, "Brave", "https://api.search.brave.com/res/v1"},
    "tavily" => {Providers.Tavily, "Tavily", "https://api.tavily.com"},
    "tinyfish" => {Providers.Tinyfish, "TinyFish", "https://api.search.tinyfish.ai"},
    "exa" => {Providers.Exa, "Exa", "https://api.exa.ai"},
    "firecrawl" => {Providers.Firecrawl, "Firecrawl", "https://api.firecrawl.dev/v2"}
  }
  @provider_ids ~w(brave tavily tinyfish exa firecrawl)

  @impl true
  def type, do: "native-web-search"
  @impl true
  def title, do: "Web Search & Fetch"
  @impl true
  def description,
    do: "Search and read web pages with up to three providers and automatic fallback."

  @impl true
  def functions_mode, do: :fixed
  @impl true
  def supports_discovery?, do: false
  @impl true
  def supports_artifacts?, do: false

  @impl true
  def default_config do
    %{
      "providers" => ["brave"],
      "provider_options" => %{},
      "timeout_seconds" => 30.0,
      "fetch_timeout_seconds" => 150.0,
      "user_agent" => "IntellectualClubWebSearch/0.1",
      "default_count" => 5,
      "max_count" => 20
    }
  end

  def provider_ids, do: @provider_ids

  @impl true
  def normalize_config(config) when is_map(config) do
    config =
      if Map.has_key?(config, "api_base_url") do
        options = Map.get(config, "provider_options", %{})
        options = if is_map(options), do: options, else: %{}

        config
        |> Map.delete("api_base_url")
        |> Map.put(
          "provider_options",
          Map.put(options, "brave", %{"api_base_url" => config["api_base_url"]})
        )
      else
        config
      end

    Map.merge(default_config(), config)
  end

  def normalize_config(_), do: default_config()

  @impl true
  def validate_config(_tool, config, _actor) do
    cfg = normalize_config(config)
    chain = cfg["providers"]

    cond do
      not is_list(chain) ->
        {:error, "Providers must be an ordered list."}

      length(chain) not in 1..3 ->
        {:error, "Select between one and three providers."}

      Enum.any?(chain, &(&1 not in @provider_ids)) ->
        {:error, "Unknown web provider."}

      length(Enum.uniq(chain)) != length(chain) ->
        {:error, "Each provider can appear only once."}

      Enum.any?(~w(timeout_seconds fetch_timeout_seconds), &(not positive_number?(cfg[&1]))) ->
        {:error, "Timeouts must be positive numbers."}

      Enum.any?(~w(default_count max_count), &(not is_integer(cfg[&1]) or cfg[&1] < 1)) ->
        {:error, "Result counts must be positive integers."}

      cfg["default_count"] > cfg["max_count"] ->
        {:error, "Default results count must not exceed maximum results count."}

      not is_binary(cfg["user_agent"]) ->
        {:error, "User agent must be a string."}

      not valid_options?(cfg["provider_options"]) ->
        {:error, "Provider options must contain valid HTTP(S) API URLs without credentials."}

      true ->
        :ok
    end
  end

  defp positive_number?(value), do: is_number(value) and value > 0 and value <= 3600

  defp valid_options?(options) when is_map(options) do
    Enum.all?(options, fn {provider, values} ->
      provider in @provider_ids and is_map(values) and
        Enum.all?(values, fn {key, value} ->
          key in ["api_base_url", "fetch_api_base_url"] and valid_endpoint?(value)
        end)
    end)
  end

  defp valid_options?(_), do: false

  defp valid_endpoint?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}} ->
        scheme in ["http", "https"] and is_binary(host) and host != ""

      _ ->
        false
    end
  end

  defp valid_endpoint?(_), do: false

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "providers" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 3,
          "uniqueItems" => true,
          "items" => %{"type" => "string", "enum" => @provider_ids},
          "x-ui" => %{"widget" => "hidden"}
        },
        "provider_options" => %{
          "type" => "object",
          "x-ui" => %{"widget" => "hidden"},
          "properties" =>
            Map.new(@providers, fn {id, {_, label, url}} ->
              fields = %{
                "api_base_url" => %{"type" => "string", "format" => "uri", "default" => url}
              }

              fields =
                if id == "tinyfish",
                  do:
                    Map.put(fields, "fetch_api_base_url", %{
                      "type" => "string",
                      "format" => "uri",
                      "default" => "https://api.fetch.tinyfish.ai"
                    }),
                  else: fields

              {id, %{"type" => "object", "title" => label, "properties" => fields}}
            end)
        },
        "timeout_seconds" => %{
          "type" => "number",
          "title" => "Search timeout (seconds)",
          "minimum" => 0.1,
          "maximum" => 3600
        },
        "fetch_timeout_seconds" => %{
          "type" => "number",
          "title" => "Fetch timeout (seconds)",
          "minimum" => 0.1,
          "maximum" => 3600
        },
        "user_agent" => %{"type" => "string", "title" => "User agent"},
        "default_count" => %{
          "type" => "integer",
          "title" => "Default results count",
          "minimum" => 1
        },
        "max_count" => %{"type" => "integer", "title" => "Maximum results count", "minimum" => 1}
      }
    }
  end

  @impl true
  def secrets_schema do
    %{
      "type" => "object",
      "properties" =>
        Map.new(@providers, fn {id, {_, title, _}} ->
          spec = %{"type" => "string", "title" => title <> " API key"}

          spec =
            if id == "brave",
              do: Map.put(spec, "x-aliases", ["token", "api_token", "bearer_token"]),
              else: spec

          {id <> "_api_key", spec}
        end)
    }
  end

  @impl true
  def fixed_functions(%ToolInstance{}) do
    [
      %{
        "name" => "web_search",
        "description" =>
          "Search the web and return ranked links and snippets. Provider failures are retried through the configured fallback chain; warnings report failed attempts.",
        "enabled" => true,
        "schema" => %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query text."},
            "count" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" => "Maximum number of results (bounded by tool configuration)."
            },
            "offset" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Brave pagination offset. Nonzero values require Brave."
            },
            "country" => %{
              "type" => "string",
              "description" =>
                "Country code preference, e.g. US. Providers without support are skipped."
            },
            "search_lang" => %{
              "type" => "string",
              "description" =>
                "Language preference, e.g. en or ru. Providers without support are skipped."
            },
            "safesearch" => %{
              "type" => "string",
              "description" => "Safe search mode: off, moderate, strict. Requires Brave."
            }
          }
        }
      },
      %{
        "name" => "web_fetch",
        "description" =>
          "Read the contents of 1–10 HTTP(S) URLs as clean text or Markdown. Failed URLs are retried with the configured fallback providers. Brave uses the built-in Web Reader. Does not follow links to crawl a site.",
        "enabled" => true,
        "schema" => %{
          "type" => "object",
          "required" => ["urls"],
          "properties" => %{
            "urls" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => 10,
              "items" => %{"type" => "string"}
            }
          }
        }
      }
    ]
  end

  @impl true
  def discover(_), do: {:error, "Discovery is not supported for this tool type."}

  @impl true
  def execute(tool, function, args, _context \\ nil) do
    cfg = normalize_config(tool.config || %{})

    with :ok <- validate_config(tool, cfg, nil) do
      case function do
        "web_search" -> with {:ok, args} <- search_args(args, cfg), do: search(tool, cfg, args)
        "web_fetch" -> with {:ok, urls} <- fetch_args(args), do: fetch(tool, cfg, urls)
        _ -> {:error, "Unknown function: #{function}"}
      end
    end
  end

  defp search_args(args, cfg) do
    query = args["query"]

    with true <-
           (is_binary(query) and String.trim(query) != "") or
             {:error, "Argument `query` is required."},
         {:ok, count} <- integer_arg(args["count"], cfg["default_count"], "count"),
         {:ok, offset} <- integer_arg(args["offset"], 0, "offset"),
         true <- offset >= 0 or {:error, "Argument `offset` must be a non-negative integer."},
         true <-
           Enum.all?(
             ~w(country search_lang safesearch),
             &(is_nil(args[&1]) or is_binary(args[&1]))
           ) or {:error, "Search filters must be strings."} do
      filters =
        Map.take(args, ~w(country search_lang safesearch))
        |> Enum.reject(fn {_, value} -> is_nil(value) or String.trim(value) == "" end)
        |> Map.new()

      {:ok,
       Map.merge(filters, %{
         "query" => String.trim(query),
         "count" => count |> max(1) |> min(cfg["max_count"]),
         "offset" => offset
       })}
    end
  end

  defp integer_arg(nil, default, _), do: {:ok, default}
  defp integer_arg(value, _, _) when is_integer(value), do: {:ok, value}

  defp integer_arg(value, default, name) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> integer_arg(:invalid, default, name)
    end
  end

  defp integer_arg(_, _, name), do: {:error, "Argument `#{name}` must be an integer."}

  defp fetch_args(%{"urls" => urls}) when is_list(urls) and length(urls) in 1..10 do
    Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, acc} ->
      case WebDocumentReader.normalize_url(url) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, urls} -> {:ok, urls |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp fetch_args(_),
    do: {:error, "Argument `urls` must contain between one and ten HTTP(S) URLs."}

  defp provider_config(tool, config, provider, operation) do
    {module, _, url} = Map.fetch!(@providers, provider)
    opts = Map.get(config["provider_options"], provider, %{})
    secrets = tool.secrets || %{}

    token =
      secrets[provider <> "_api_key"] ||
        if(provider == "brave",
          do: secrets["token"] || secrets["api_token"] || secrets["bearer_token"],
          else: nil
        )

    timeout =
      if operation == "web_search",
        do: config["timeout_seconds"],
        else: config["fetch_timeout_seconds"]

    %{
      module: module,
      api_base_url: Map.get(opts, "api_base_url", url),
      fetch_api_base_url: Map.get(opts, "fetch_api_base_url", "https://api.fetch.tinyfish.ai"),
      token: if(is_binary(token), do: String.trim(token), else: ""),
      user_agent: config["user_agent"],
      timeout_ms: max(1, trunc(timeout * 1000))
    }
  end

  defp search(tool, config, args) do
    state =
      Enum.reduce_while(
        config["providers"],
        %{results: [], attempts: [], warnings: [], success: false},
        fn provider, state ->
          cfg = provider_config(tool, config, provider, "web_search")
          started = System.monotonic_time(:millisecond)

          outcome =
            with :ok <- credentials(cfg, provider, "web_search"),
                 :ok <- supported_filters(provider, args) do
              timed(fn -> cfg.module.search(cfg, args) end, cfg.timeout_ms)
            end

          case outcome do
            {:ok, result} ->
              attempt = attempt(provider, "web_search", started, "success")
              warnings = state.warnings ++ provider_warnings(result.warnings, provider, tool)

              {:halt,
               %{
                 state
                 | success: true,
                   results: Enum.take(result.results, args["count"]),
                   attempts: state.attempts ++ [attempt],
                   warnings: warnings
               }}

            {:error, error} ->
              attempt = failed_attempt(provider, "web_search", started, error, tool)

              {:cont,
               %{
                 state
                 | attempts: state.attempts ++ [attempt],
                   warnings: state.warnings ++ [warning(attempt)]
               }}
          end
        end
      )

    finish(state, "web_search", args["query"])
  end

  defp fetch(tool, config, urls) do
    state =
      Enum.reduce_while(
        config["providers"],
        %{results: %{}, attempts: [], warnings: [], pending: urls},
        fn provider, state ->
          cfg = provider_config(tool, config, provider, "web_fetch")
          started = System.monotonic_time(:millisecond)

          outcomes =
            case credentials(cfg, provider, "web_fetch") do
              :ok ->
                tasks =
                  Enum.map(state.pending, fn url ->
                    {url,
                     Task.Supervisor.async_nolink(
                       IntellectualClub.Tools.WebSearchTaskSupervisor,
                       fn -> safe_run(fn -> cfg.module.fetch(cfg, [url], tool) end) end
                     )}
                  end)

                replies =
                  tasks
                  |> Enum.map(&elem(&1, 1))
                  |> Task.yield_many(cfg.timeout_ms)
                  |> Map.new(fn {task, reply} -> {task.ref, reply} end)

                Enum.map(tasks, fn {url, task} -> {url, task_reply(task, replies[task.ref])} end)

              {:error, error} ->
                Enum.map(state.pending, &{&1, {:error, error}})
            end

          state =
            Enum.reduce(outcomes, %{state | pending: []}, fn {url, outcome}, state ->
              case outcome do
                {:ok, %{results: [result | _]} = response} ->
                  attempt =
                    attempt(provider, "web_fetch", started, "success") |> Map.put("url", url)

                  result =
                    result
                    |> Map.put("provider", provider)
                    |> Map.put("backend", backend(provider, "web_fetch"))

                  warnings = provider_warnings(response.warnings, provider, tool)

                  warnings =
                    if result["truncated"],
                      do: warnings ++ ["#{provider}: #{url}: Extracted document was truncated."],
                      else: warnings

                  %{
                    state
                    | results: Map.put(state.results, url, result),
                      attempts: state.attempts ++ [attempt],
                      warnings: state.warnings ++ warnings
                  }

                other ->
                  error =
                    case other do
                      {:error, error} -> error
                      {:ok, %{errors: [error | _]}} -> error
                      _ -> Http.error("empty_content", "Page has no readable content.")
                    end

                  attempt =
                    failed_attempt(
                      provider,
                      "web_fetch",
                      started,
                      Map.put(error, :url, url),
                      tool
                    )

                  %{
                    state
                    | pending: state.pending ++ [url],
                      attempts: state.attempts ++ [attempt],
                      warnings: state.warnings ++ [warning(attempt)]
                  }
              end
            end)

          if state.pending == [], do: {:halt, state}, else: {:cont, state}
        end
      )

    results =
      Enum.flat_map(urls, fn url -> if state.results[url], do: [state.results[url]], else: [] end)

    state =
      Map.merge(state, %{
        results: results,
        success: results != [],
        errors:
          Enum.map(
            state.pending,
            &%{"url" => &1, "message" => "All configured providers failed."}
          )
      })

    finish(state, "web_fetch", nil)
  end

  defp credentials(%{token: ""}, "brave", "web_fetch"), do: :ok

  defp credentials(%{token: ""}, _, _),
    do:
      {:error, Http.error("missing_credentials", "API key is not configured for this provider.")}

  defp credentials(_, _, _), do: :ok

  defp supported_filters(provider, args) do
    supported =
      case provider do
        "brave" -> ~w(offset country search_lang safesearch)
        "tinyfish" -> ~w(country search_lang)
        p when p in ["exa", "firecrawl"] -> ~w(country)
        _ -> []
      end

    unsupported =
      Enum.filter(~w(offset country search_lang safesearch), fn key ->
        args[key] not in [nil, "", 0] and key not in supported
      end)

    if unsupported == [],
      do: :ok,
      else:
        {:error,
         Http.error(
           "unsupported_parameters",
           "Unsupported search parameters: #{Enum.join(unsupported, ", ")}."
         )}
  end

  defp timed(fun, timeout) do
    task =
      Task.Supervisor.async_nolink(IntellectualClub.Tools.WebSearchTaskSupervisor, fn ->
        safe_run(fun)
      end)

    task_reply(task, Task.yield(task, timeout))
  end

  defp safe_run(fun) do
    fun.()
  rescue
    _ -> {:error, Http.error("provider_error", "Provider attempt failed.")}
  catch
    _, _ -> {:error, Http.error("provider_error", "Provider attempt failed.")}
  end

  defp task_reply(_task, {:ok, result}), do: result

  defp task_reply(_task, {:exit, _}),
    do: {:error, Http.error("provider_error", "Provider attempt failed.")}

  defp task_reply(task, nil) do
    Task.shutdown(task, :brutal_kill)
    {:error, Http.error("timeout", "Provider attempt timed out.")}
  end

  defp backend("brave", "web_fetch"), do: "web_reader"
  defp backend(provider, _), do: provider

  defp attempt(provider, operation, started, status),
    do: %{
      "provider" => provider,
      "backend" => backend(provider, operation),
      "operation" => operation,
      "status" => status,
      "duration_ms" => max(0, System.monotonic_time(:millisecond) - started)
    }

  defp failed_attempt(provider, operation, started, error, tool) do
    attempt(provider, operation, started, "error")
    |> Map.merge(%{
      "code" => Http.redact(error.code, Map.values(tool.secrets || %{})),
      "message" => Http.redact(error.message, Map.values(tool.secrets || %{})),
      "http_status" => error.http_status
    })
    |> then(fn trace -> if error[:url], do: Map.put(trace, "url", error.url), else: trace end)
  end

  defp warning(attempt),
    do:
      "#{attempt["provider"]} (#{attempt["backend"]})#{if attempt["url"], do: " #{attempt["url"]}", else: ""}: #{attempt["message"]}"

  defp provider_warnings(warnings, provider, tool),
    do:
      Enum.map(warnings, &(provider <> ": " <> Http.redact(&1, Map.values(tool.secrets || %{}))))

  defp finish(state, operation, query) do
    header =
      if state.warnings == [],
        do: [],
        else: ["Warnings:"] ++ Enum.map(state.warnings, &("- " <> &1)) ++ [""]

    header = header ++ ["Operation: #{operation}"] ++ if(query, do: ["Query: #{query}"], else: [])

    body =
      Enum.with_index(state.results, 1)
      |> Enum.map(fn {result, index} ->
        if operation == "web_search" do
          "#{index}. #{result["title"]}\nURL: #{result["url"]}\n#{result["description"]}"
        else
          "Source: #{result["final_url"]}\nProvider: #{result["provider"]} (#{result["backend"]})\n#{result["title"] || ""}\n\n#{result["text"]}"
        end
      end)

    body =
      if body == [],
        do: [if(state.success, do: "(no results)", else: "All configured providers failed.")],
        else: body

    raw = %{
      "operation" => operation,
      "results" => state.results,
      "warnings" => state.warnings,
      "attempts" => state.attempts,
      "errors" => Map.get(state, :errors, []),
      "isError" => not state.success
    }

    {:ok, %ExecutionResult{text: Enum.join(header ++ [""] ++ body, "\n"), raw: raw}}
  end
end
