defmodule IntellectualClub.Tools.Drivers.NativeBraveSearch do
  @moduledoc """
  Native Brave Search API driver.

  This is a fixed-function tool that exposes `web_search`.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Tools.ToolInstance

  @default_api_base_url "https://api.search.brave.com/res/v1"
  @default_timeout_seconds 30.0
  @default_user_agent "IntellectualClubBraveSearch/0.1"
  @default_default_count 5
  @default_max_count 20

  @impl true
  def type, do: "native-brave-search"

  @impl true
  def title, do: "Brave Search"

  @impl true
  def description, do: "Search the web via Brave Search API."

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def supports_artifacts?, do: false

  @impl true
  def default_config do
    %{
      "api_base_url" => @default_api_base_url,
      "timeout_seconds" => @default_timeout_seconds,
      "user_agent" => @default_user_agent,
      "default_count" => @default_default_count,
      "max_count" => @default_max_count
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "api_base_url" => %{
          "type" => "string",
          "title" => "API base URL",
          "description" => "Brave Search REST API base URL.",
          "format" => "uri",
          "x-ui" => %{"placeholder" => @default_api_base_url}
        },
        "timeout_seconds" => %{
          "type" => "number",
          "title" => "Timeout (seconds)",
          "description" => "HTTP receive timeout in seconds.",
          "minimum" => 0
        },
        "user_agent" => %{
          "type" => "string",
          "title" => "User agent",
          "description" => "HTTP User-Agent header value."
        },
        "default_count" => %{
          "type" => "integer",
          "title" => "Default results count",
          "description" => "Default number of results when the `count` argument is omitted.",
          "minimum" => 1
        },
        "max_count" => %{
          "type" => "integer",
          "title" => "Maximum results count",
          "description" => "Hard upper bound for the `count` argument.",
          "minimum" => 1
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema do
    %{
      "type" => "object",
      "properties" => %{
        "token" => %{
          "type" => "string",
          "title" => "API token",
          "description" => "Brave Search API subscription token.",
          "x-aliases" => ["api_token", "bearer_token"],
          "x-ui" => %{"placeholder" => "Brave API token"}
        }
      }
    }
  end

  @impl true
  def fixed_functions(%ToolInstance{} = _tool_instance) do
    [
      %{
        "name" => "web_search",
        "description" =>
          "Search the web using Brave Search and return a compact list of results.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query text."},
            "count" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" => "Number of results to return (bounded by tool configuration)."
            },
            "offset" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" => "Result offset for pagination."
            },
            "country" => %{
              "type" => "string",
              "description" => "Country code (e.g. US, GB). Influences ranking."
            },
            "search_lang" => %{
              "type" => "string",
              "description" => "Search language code (e.g. en, ru)."
            },
            "safesearch" => %{
              "type" => "string",
              "description" =>
                "Safe search mode. Typical values: \\\"off\\\", \\\"moderate\\\", \\\"strict\\\"."
            }
          },
          "required" => ["query"]
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
      "web_search" -> web_search(tool_instance, args || %{})
      _other -> {:error, "Unknown function: #{function_name}"}
    end
  end

  defp web_search(%ToolInstance{} = tool_instance, args) when is_map(args) do
    cfg = config_from_tool(tool_instance)

    with {:ok, token} <- token_from_tool(tool_instance),
         {:ok, query} <- required_query(args),
         {:ok, count} <- parse_count(args, cfg),
         {:ok, offset} <- parse_offset(args) do
      country = normalize_optional_string(Map.get(args, "country", Map.get(args, :country)))

      search_lang =
        normalize_optional_string(Map.get(args, "search_lang", Map.get(args, :search_lang)))

      safesearch =
        normalize_optional_string(Map.get(args, "safesearch", Map.get(args, :safesearch)))

      params =
        %{"q" => query, "count" => count, "offset" => offset}
        |> maybe_put("country", country)
        |> maybe_put("search_lang", search_lang)
        |> maybe_put("safesearch", safesearch)

      endpoint = cfg.api_base_url <> "/web/search"

      headers = [
        {"accept", "application/json"},
        {"user-agent", cfg.user_agent},
        {"x-subscription-token", token}
      ]

      case request_json(endpoint, params, headers, cfg.timeout_seconds) do
        {:ok, payload} ->
          if is_map(payload) do
            results = extract_web_results(payload)

            text =
              format_output_text(query, count, offset, country, search_lang, safesearch, results)

            {:ok,
             {text,
              %{
                "endpoint" => endpoint,
                "params" => params,
                "results" => results,
                "raw" => payload
              }}}
          else
            {:error, "Brave Search API returned unexpected JSON shape."}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp config_from_tool(%ToolInstance{} = tool_instance) do
    cfg = Map.get(tool_instance, :config) || %{}
    cfg = if is_map(cfg), do: cfg, else: %{}

    %{
      api_base_url:
        cfg
        |> read_string("api_base_url", @default_api_base_url)
        |> String.trim()
        |> String.trim_trailing("/"),
      timeout_seconds: read_float(cfg, "timeout_seconds", @default_timeout_seconds),
      user_agent: read_string(cfg, "user_agent", @default_user_agent),
      default_count: max(1, read_integer(cfg, "default_count", @default_default_count)),
      max_count: max(1, read_integer(cfg, "max_count", @default_max_count))
    }
  end

  defp token_from_tool(%ToolInstance{} = tool_instance) do
    secrets = Map.get(tool_instance, :secrets) || %{}
    secrets = if is_map(secrets), do: secrets, else: %{}

    token =
      (Map.get(secrets, "token") ||
         Map.get(secrets, :token) ||
         Map.get(secrets, "api_token") ||
         Map.get(secrets, :api_token) ||
         Map.get(secrets, "bearer_token") ||
         Map.get(secrets, :bearer_token) ||
         "")
      |> to_string()
      |> String.trim()

    if token == "" do
      {:error, "Brave Search token is not configured for this tool."}
    else
      {:ok, token}
    end
  end

  defp required_query(args) when is_map(args) do
    query =
      args
      |> Map.get("query", Map.get(args, :query))
      |> to_string()
      |> String.trim()

    if query == "" do
      {:error, "Argument `query` is required."}
    else
      {:ok, query}
    end
  end

  defp parse_count(args, cfg) when is_map(args) and is_map(cfg) do
    case coerce_optional_integer(Map.get(args, "count", Map.get(args, :count)), cfg.default_count) do
      {:ok, count} ->
        {:ok, count |> max(1) |> min(cfg.max_count)}

      {:error, _reason} ->
        {:error, "Argument `count` must be an integer."}
    end
  end

  defp parse_offset(args) when is_map(args) do
    case coerce_optional_integer(Map.get(args, "offset", Map.get(args, :offset)), 0) do
      {:ok, offset} when offset < 0 ->
        {:error, "Argument `offset` must be a non-negative integer."}

      {:ok, offset} ->
        {:ok, offset}

      {:error, _reason} ->
        {:error, "Argument `offset` must be an integer."}
    end
  end

  defp request_json(endpoint, params, headers, timeout_seconds)
       when is_binary(endpoint) and is_map(params) and is_list(headers) and
              is_number(timeout_seconds) do
    timeout_ms = timeout_seconds |> Kernel.*(1000) |> trunc() |> max(1)

    resp =
      Req.request!(
        method: :get,
        url: endpoint,
        params: params,
        headers: headers,
        receive_timeout: timeout_ms
      )

    if resp.status >= 400 do
      body_text = body_to_string(resp.body)
      message = "Brave Search API error: HTTP #{resp.status}."

      if String.trim(body_text) == "" do
        {:error, message}
      else
        {:error, message <> " Body: " <> String.slice(body_text, 0, 2000)}
      end
    else
      case decode_json_body(resp.body) do
        {:ok, %{} = payload} -> {:ok, payload}
        {:ok, _other} -> {:error, "Brave Search API returned unexpected JSON shape."}
        {:error, _reason} -> {:error, "Brave Search API returned invalid JSON."}
      end
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    :exit, reason ->
      {:error, Exception.format_exit(reason)}
  end

  defp decode_json_body(%{} = body), do: {:ok, body}

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json_body(body) when is_list(body) do
    body
    |> IO.iodata_to_binary()
    |> decode_json_body()
  end

  defp decode_json_body(_other), do: {:error, :invalid}

  defp extract_web_results(payload) when is_map(payload) do
    web = Map.get(payload, "web")

    results =
      if is_map(web) do
        Map.get(web, "results")
      else
        nil
      end

    if is_list(results) do
      Enum.flat_map(results, fn item ->
        if is_map(item) do
          title =
            item |> Map.get("title", Map.get(item, :title, "")) |> to_string() |> String.trim()

          url = item |> Map.get("url", Map.get(item, :url, "")) |> to_string() |> String.trim()

          description =
            item
            |> Map.get("description", Map.get(item, :description, ""))
            |> to_string()
            |> String.trim()

          if title == "" and url == "" and description == "" do
            []
          else
            [
              %{
                "title" => title,
                "url" => url,
                "description" => description
              }
            ]
          end
        else
          []
        end
      end)
    else
      []
    end
  end

  defp extract_web_results(_other), do: []

  defp format_output_text(query, count, offset, country, search_lang, safesearch, results)
       when is_binary(query) and is_integer(count) and is_integer(offset) and is_list(results) do
    header_lines =
      [
        "Source: Brave Search",
        "Query: #{query}",
        "Count: #{count}",
        "Offset: #{offset}"
      ]
      |> maybe_append_line("Country", country)
      |> maybe_append_line("Language", search_lang)
      |> maybe_append_line("SafeSearch", safesearch)

    body_lines =
      if results == [] do
        ["(no results)"]
      else
        Enum.with_index(results, 1)
        |> Enum.flat_map(fn {item, idx} ->
          title =
            item |> Map.get("title", Map.get(item, :title, "")) |> to_string() |> String.trim()

          url = item |> Map.get("url", Map.get(item, :url, "")) |> to_string() |> String.trim()

          snippet =
            item
            |> Map.get("description", Map.get(item, :description, ""))
            |> to_string()
            |> String.trim()

          [
            if(title == "", do: "#{idx}. (no title)", else: "#{idx}. #{title}"),
            if(url == "", do: nil, else: "   URL: #{url}"),
            if(snippet == "", do: nil, else: "   Snippet: #{snippet}")
          ]
          |> Enum.reject(&is_nil/1)
        end)
      end

    Enum.join(header_lines, "\n") <>
      "\n\n---\n\n" <> Enum.join(body_lines, "\n") <> "\n"
  end

  defp maybe_append_line(lines, _name, nil), do: lines
  defp maybe_append_line(lines, _name, ""), do: lines

  defp maybe_append_line(lines, name, value) when is_list(lines) and is_binary(name) do
    lines ++ ["#{name}: #{value}"]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) do
    value = value |> to_string() |> String.trim()
    if value == "", do: nil, else: value
  end

  defp read_string(cfg, key, default)
       when is_map(cfg) and is_binary(key) and is_binary(default) do
    case get_config_value(cfg, key) do
      nil -> default
      value -> to_string(value)
    end
  end

  defp read_integer(cfg, key, default)
       when is_map(cfg) and is_binary(key) and is_integer(default) do
    case coerce_optional_integer(get_config_value(cfg, key), default) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  defp read_float(cfg, key, default) when is_map(cfg) and is_binary(key) and is_number(default) do
    raw = get_config_value(cfg, key)

    cond do
      raw == nil ->
        default

      is_number(raw) ->
        raw * 1.0

      true ->
        case Float.parse(to_string(raw)) do
          {value, ""} -> value
          _ -> default
        end
    end
  end

  defp coerce_optional_integer(nil, default) when is_integer(default), do: {:ok, default}
  defp coerce_optional_integer(value, _default) when is_integer(value), do: {:ok, value}

  defp coerce_optional_integer(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp coerce_optional_integer(value, _default) when is_float(value), do: {:ok, trunc(value)}
  defp coerce_optional_integer(_value, _default), do: {:error, :invalid_integer}

  defp get_config_value(cfg, key) when is_map(cfg) and is_binary(key) do
    case Map.get(cfg, key) do
      nil ->
        case key do
          "api_base_url" -> Map.get(cfg, :api_base_url)
          "timeout_seconds" -> Map.get(cfg, :timeout_seconds)
          "user_agent" -> Map.get(cfg, :user_agent)
          "default_count" -> Map.get(cfg, :default_count)
          "max_count" -> Map.get(cfg, :max_count)
          _ -> nil
        end

      value ->
        value
    end
  end

  defp body_to_string(nil), do: ""
  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_to_string(body) when is_map(body), do: Jason.encode!(body)
  defp body_to_string(other), do: to_string(other)
end
