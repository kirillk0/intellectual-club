defmodule IntellectualClub.Tools.Drivers.McpHttp do
  @moduledoc """
  MCP server driver over HTTP (JSON-RPC with JSON or SSE responses).

  This matches the `mcp-http` tool type.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Tools.ToolInstance

  @protocol_version "2024-11-05"
  @header_name_regex ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @impl true
  def type, do: "mcp-http"

  @impl true
  def title, do: "MCP HTTP"

  @impl true
  def description, do: "Connect to a remote MCP server over HTTP."

  @impl true
  def functions_mode, do: :stored

  @impl true
  def supports_discovery?, do: true

  @impl true
  def supports_artifacts?, do: false

  @impl true
  def default_config do
    %{
      "server_url" => "",
      "open_headers" => %{},
      "secret_header_names" => []
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "server_url" => %{
          "type" => "string",
          "title" => "Server URL",
          "description" => "MCP server URL.",
          "format" => "uri",
          "x-ui" => %{"order" => 10, "placeholder" => "https://mcp.example.com"}
        },
        "open_headers" => %{
          "type" => "object",
          "title" => "Open headers",
          "description" => "HTTP headers whose names and values may be displayed.",
          "additionalProperties" => %{"type" => "string"},
          "x-ui" => %{"widget" => "hidden"}
        },
        "secret_header_names" => %{
          "type" => "array",
          "title" => "Secret header names",
          "items" => %{"type" => "string"},
          "x-ui" => %{"widget" => "hidden"}
        }
      },
      "required" => ["server_url"],
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema do
    %{
      "type" => "object",
      "properties" => %{
        "bearer_token" => %{
          "type" => "string",
          "title" => "Bearer token",
          "description" => "Bearer token (optional).",
          "x-aliases" => ["token"],
          "x-ui" => %{"order" => 10, "placeholder" => "Bearer …"}
        },
        "secret_headers" => %{
          "type" => "object",
          "title" => "Secret headers",
          "description" => "HTTP header names are displayed, while values remain write-only.",
          "additionalProperties" => %{"type" => "string"},
          "x-ui" => %{"widget" => "hidden"}
        }
      }
    }
  end

  @impl true
  def validate_config(%ToolInstance{} = tool_instance, _config, _actor) do
    case configured_headers(tool_instance) do
      {:ok, _headers} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  @impl true
  def discover(%ToolInstance{} = tool_instance) do
    with {:ok, server_url} <- server_url(tool_instance),
         bearer_token <- bearer_token(tool_instance),
         {:ok, configured_headers} <- configured_headers(tool_instance),
         {:ok, {session_id, init_result}} <-
           initialize(server_url,
             bearer_token: bearer_token,
             configured_headers: configured_headers
           ) do
      case discover_tools_from_init(init_result) do
        {:ok, tools} ->
          {:ok, tools}

        {:fallback, :list_tools} ->
          list_tools(server_url, session_id,
            bearer_token: bearer_token,
            configured_headers: configured_headers
          )
      end
    end
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, function_name, args, _execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    with {:ok, server_url} <- server_url(tool_instance),
         bearer_token <- bearer_token(tool_instance),
         {:ok, configured_headers} <- configured_headers(tool_instance),
         {:ok, {session_id, _init_result}} <-
           initialize(server_url,
             bearer_token: bearer_token,
             configured_headers: configured_headers
           ),
         {:ok, result} <-
           call_tool(server_url, session_id, function_name, args,
             bearer_token: bearer_token,
             configured_headers: configured_headers
           ) do
      {:ok, result}
    end
  end

  defp server_url(%ToolInstance{} = tool_instance) do
    server_url =
      tool_instance
      |> Map.get(:config)
      |> case do
        %{} = cfg -> Map.get(cfg, "server_url")
        _ -> nil
      end
      |> to_string()
      |> String.trim()

    if server_url == "" do
      {:error, "Tool instance config.server_url is required."}
    else
      {:ok, server_url}
    end
  end

  defp bearer_token(%ToolInstance{} = tool_instance) do
    secrets = Map.get(tool_instance, :secrets) || %{}
    secrets = if is_map(secrets), do: secrets, else: %{}

    (Map.get(secrets, "bearer_token") ||
       Map.get(secrets, "token") ||
       "")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp configured_headers(%ToolInstance{} = tool_instance) do
    config = Map.get(tool_instance, :config) || %{}
    config = if is_map(config), do: config, else: %{}
    secrets = Map.get(tool_instance, :secrets) || %{}
    secrets = if is_map(secrets), do: secrets, else: %{}

    with {:ok, open_headers} <-
           parse_header_map(Map.get(config, "open_headers"), "Open headers", allow_empty?: true),
         {:ok, secret_header_names} <-
           parse_header_names(Map.get(config, "secret_header_names")),
         {:ok, stored_secret_headers} <-
           parse_header_map(Map.get(secrets, "secret_headers"), "Secret headers",
             allow_empty?: false
           ),
         {:ok, secret_headers} <-
           select_secret_headers(secret_header_names, stored_secret_headers),
         :ok <- reject_header_name_conflicts(open_headers, secret_headers) do
      headers =
        Enum.reduce(open_headers ++ secret_headers, [], fn {name, value}, headers ->
          put_header(headers, name, value)
        end)

      {:ok, headers}
    end
  end

  defp parse_header_map(nil, _label, _opts), do: {:ok, []}

  defp parse_header_map(value, label, opts) when is_map(value) do
    allow_empty? = Keyword.fetch!(opts, :allow_empty?)

    value
    |> Enum.reduce_while({:ok, []}, fn {raw_name, raw_value}, {:ok, headers} ->
      with {:ok, name} <- validate_header_name(raw_name, label),
           {:ok, header_value} <- validate_header_value(raw_value, name, label, allow_empty?) do
        {:cont, {:ok, [{name, header_value} | headers]}}
      else
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, headers} -> reject_duplicate_header_names(Enum.reverse(headers), label)
      {:error, _message} = error -> error
    end
  end

  defp parse_header_map(_value, label, _opts),
    do: {:error, "#{label} must be a JSON object with header-name keys and string values."}

  defp parse_header_names(nil), do: {:ok, []}

  defp parse_header_names(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn raw_name, {:ok, names} ->
      case validate_header_name(raw_name, "Secret headers") do
        {:ok, name} -> {:cont, {:ok, [name | names]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, names} -> reject_duplicate_names(Enum.reverse(names), "Secret headers")
      {:error, _message} = error -> error
    end
  end

  defp parse_header_names(_value),
    do: {:error, "Secret header names must be a JSON array of strings."}

  defp validate_header_name(raw_name, label) when is_binary(raw_name) do
    name = String.trim(raw_name)

    if Regex.match?(@header_name_regex, name) do
      {:ok, name}
    else
      {:error, "#{label} contains an invalid header name: #{inspect(raw_name)}."}
    end
  end

  defp validate_header_name(raw_name, label),
    do: {:error, "#{label} contains a non-string header name: #{inspect(raw_name)}."}

  defp validate_header_value(raw_value, name, label, allow_empty?) when is_binary(raw_value) do
    value = String.trim(raw_value)

    cond do
      not valid_header_value?(value) ->
        {:error, "#{label} contains an invalid value for #{name}."}

      value == "" and not allow_empty? ->
        {:error, "#{label} is missing a value for #{name}."}

      true ->
        {:ok, value}
    end
  end

  defp validate_header_value(_raw_value, name, label, _allow_empty?),
    do: {:error, "#{label} value for #{name} must be a string."}

  defp reject_duplicate_header_names(headers, label) do
    case duplicate_name(Enum.map(headers, &elem(&1, 0))) do
      nil -> {:ok, headers}
      name -> {:error, "#{label} contains the duplicate header name #{name}."}
    end
  end

  defp reject_duplicate_names(names, label) do
    case duplicate_name(names) do
      nil -> {:ok, names}
      name -> {:error, "#{label} contains the duplicate header name #{name}."}
    end
  end

  defp duplicate_name(names) do
    names
    |> Enum.reduce_while(MapSet.new(), fn name, seen ->
      normalized = String.downcase(name)

      if MapSet.member?(seen, normalized) do
        {:halt, name}
      else
        {:cont, MapSet.put(seen, normalized)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      name -> name
    end
  end

  defp select_secret_headers(names, stored_headers) do
    stored_by_name = Map.new(stored_headers)

    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, selected} ->
      case Map.fetch(stored_by_name, name) do
        {:ok, value} -> {:cont, {:ok, [{name, value} | selected]}}
        :error -> {:halt, {:error, "Secret headers is missing a stored value for #{name}."}}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      {:error, _message} = error -> error
    end
  end

  defp reject_header_name_conflicts(open_headers, secret_headers) do
    open_names = MapSet.new(open_headers, fn {name, _value} -> String.downcase(name) end)

    case Enum.find(secret_headers, fn {name, _value} ->
           MapSet.member?(open_names, String.downcase(name))
         end) do
      nil -> :ok
      {name, _value} -> {:error, "Header #{name} cannot be both open and secret."}
    end
  end

  defp valid_header_value?(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte == 9 or (byte >= 32 and byte != 127) end)
  end

  defp initialize(server_url, opts) when is_binary(server_url) and is_list(opts) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "intellectual_club", "version" => "0.1"}
      }
    }

    bearer_token = Keyword.get(opts, :bearer_token)
    configured_headers = Keyword.get(opts, :configured_headers, [])

    case post_jsonrpc(server_url, payload,
           bearer_token: bearer_token,
           configured_headers: configured_headers
         ) do
      {:ok, %{session_id: session_id, messages: [%{"result" => %{} = result} | _]}} ->
        {:ok, {session_id, result}}

      {:ok, %{messages: []}} ->
        {:error, "MCP server returned no messages for initialize()."}

      {:ok, %{messages: [%{} = first | _]}} ->
        {:error, "MCP initialize() response missing result (first=#{inspect(first)})."}

      {:error, _} = error ->
        error
    end
  end

  defp discover_tools_from_init(%{} = init_result) do
    capabilities = Map.get(init_result, "capabilities")
    tools_obj = if is_map(capabilities), do: Map.get(capabilities, "tools"), else: nil

    tools =
      if is_map(tools_obj) do
        tools_obj
        |> Enum.flat_map(fn {name, spec} ->
          if is_binary(name) and name != "" and is_map(spec) do
            [
              %{
                "name" => name,
                "description" => to_string(Map.get(spec, "description") || ""),
                "schema" =>
                  case Map.get(spec, "schema") do
                    %{} = schema -> schema
                    _ -> %{}
                  end
              }
            ]
          else
            []
          end
        end)
      else
        []
      end

    if tools == [] do
      {:fallback, :list_tools}
    else
      {:ok, tools}
    end
  end

  defp list_tools(server_url, session_id, opts)
       when is_binary(server_url) and is_binary(session_id) and is_list(opts) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/list",
      "params" => %{}
    }

    bearer_token = Keyword.get(opts, :bearer_token)
    configured_headers = Keyword.get(opts, :configured_headers, [])

    with {:ok, %{messages: [%{"result" => %{} = result} | _]}} <-
           post_jsonrpc(server_url, payload,
             bearer_token: bearer_token,
             configured_headers: configured_headers,
             session_id: session_id
           ),
         %{"tools" => tools} <- result,
         true <- is_list(tools) do
      parsed =
        Enum.flat_map(tools, fn item ->
          if is_map(item) do
            name = Map.get(item, "name")

            if is_binary(name) and name != "" do
              schema =
                cond do
                  is_map(Map.get(item, "inputSchema")) -> Map.get(item, "inputSchema")
                  is_map(Map.get(item, "schema")) -> Map.get(item, "schema")
                  true -> %{}
                end

              [
                %{
                  "name" => name,
                  "description" => to_string(Map.get(item, "description") || ""),
                  "schema" => schema
                }
              ]
            else
              []
            end
          else
            []
          end
        end)

      if parsed == [] do
        {:error, "MCP tools/list response missing tools."}
      else
        {:ok, parsed}
      end
    else
      _ ->
        {:error, "MCP server returned no messages for tools/list."}
    end
  end

  defp call_tool(server_url, session_id, tool_name, arguments, opts)
       when is_binary(server_url) and is_binary(session_id) and is_binary(tool_name) and
              is_map(arguments) and is_list(opts) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => arguments}
    }

    bearer_token = Keyword.get(opts, :bearer_token)
    configured_headers = Keyword.get(opts, :configured_headers, [])

    case post_jsonrpc(server_url, payload,
           bearer_token: bearer_token,
           configured_headers: configured_headers,
           session_id: session_id,
           timeout_ms: 60_000
         ) do
      {:ok, %{messages: [%{"result" => result} | _]}} ->
        raw_result = if is_map(result), do: result, else: %{"result" => result}
        text = extract_text_content(raw_result)

        text =
          if String.trim(text) == "" do
            Jason.encode!(raw_result)
          else
            text
          end

        {:ok, {text, raw_result}}

      {:ok, %{messages: []}} ->
        {:error, "MCP server returned no messages for tools/call."}

      {:error, _} = error ->
        error
    end
  end

  defp extract_text_content(%{} = raw_result) do
    content = Map.get(raw_result, "content")

    text_parts =
      if is_list(content) do
        Enum.flat_map(content, fn item ->
          if is_map(item) and Map.get(item, "type") == "text" do
            [to_string(Map.get(item, "text") || "")]
          else
            []
          end
        end)
      else
        []
      end

    Enum.join(text_parts, "")
  end

  defp post_jsonrpc(server_url, payload, opts)
       when is_binary(server_url) and is_map(payload) and is_list(opts) do
    bearer_token = Keyword.get(opts, :bearer_token)
    configured_headers = Keyword.get(opts, :configured_headers, [])
    session_id = Keyword.get(opts, :session_id)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    headers =
      configured_headers
      |> put_header("content-type", "application/json")
      |> put_header("accept", "application/json, text/event-stream")
      |> maybe_put_bearer(bearer_token)
      |> maybe_put_header("mcp-session-id", session_id)

    request_opts = [
      url: server_url,
      method: :post,
      headers: headers,
      json: payload,
      receive_timeout: timeout_ms
    ]

    resp = Req.request!(request_opts)

    if resp.status >= 400 do
      {:error, "MCP HTTP error (status=#{resp.status})"}
    else
      messages = extract_messages(resp.body)

      {:ok,
       %{
         status: resp.status,
         session_id: get_header(resp.headers, "mcp-session-id") || "",
         messages: messages
       }}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    :exit, reason ->
      {:error, Exception.format_exit(reason)}
  end

  defp extract_messages(%{} = message), do: [message]
  defp extract_messages([]), do: []

  defp extract_messages([%{} | _] = messages) do
    Enum.filter(messages, &is_map/1)
  end

  defp extract_messages(body) when is_list(body) do
    body
    |> IO.iodata_to_binary()
    |> extract_messages()
  rescue
    ArgumentError -> []
  end

  defp extract_messages(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = message} -> [message]
      {:ok, messages} when is_list(messages) -> Enum.filter(messages, &is_map/1)
      _ -> extract_sse_messages(body)
    end
  end

  defp extract_messages(_other), do: []

  defp extract_sse_messages(body_text) when is_binary(body_text) do
    body_text
    |> String.split(["\r\n", "\n"], trim: false)
    |> Enum.flat_map(fn line ->
      line = String.trim(line)

      if String.starts_with?(line, "data:") do
        payload = line |> String.trim_leading("data:") |> String.trim()

        case Jason.decode(payload) do
          {:ok, %{} = obj} -> [obj]
          _ -> []
        end
      else
        []
      end
    end)
  end

  defp get_header(headers, key) when is_binary(key) do
    wanted = String.downcase(key)

    cond do
      is_map(headers) ->
        case Map.get(headers, wanted) || Map.get(headers, key) do
          [value | _] when is_binary(value) -> value
          value when is_binary(value) -> value
          _ -> nil
        end

      is_list(headers) ->
        Enum.find_value(headers, fn
          {name, value} when is_binary(name) and is_binary(value) ->
            if String.downcase(name) == wanted, do: value, else: nil

          {name, [value | _]} when is_binary(name) and is_binary(value) ->
            if String.downcase(name) == wanted, do: value, else: nil

          _ ->
            nil
        end)

      true ->
        nil
    end
  end

  defp put_header(headers, name, value) when is_list(headers) do
    normalized_name = String.downcase(name)

    headers =
      Enum.reject(headers, fn
        {existing_name, _existing_value} when is_binary(existing_name) ->
          String.downcase(existing_name) == normalized_name

        _other ->
          false
      end)

    [{name, value} | headers]
  end

  defp maybe_put_header(headers, _name, nil), do: headers
  defp maybe_put_header(headers, _name, ""), do: headers

  defp maybe_put_header(headers, name, value) when is_list(headers) and is_binary(value) do
    put_header(headers, name, value)
  end

  defp maybe_put_bearer(headers, nil), do: headers
  defp maybe_put_bearer(headers, ""), do: headers

  defp maybe_put_bearer(headers, token) when is_binary(token) do
    put_header(headers, "authorization", "Bearer " <> token)
  end
end
