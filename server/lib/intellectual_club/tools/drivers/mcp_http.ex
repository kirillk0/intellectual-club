defmodule IntellectualClub.Tools.Drivers.McpHttp do
  @moduledoc """
  MCP server driver over HTTP (JSON-RPC with SSE responses).

  This matches the `mcp-http` tool type.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Tools.ToolInstance

  @protocol_version "2024-11-05"

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
  def default_config do
    %{"server_url" => ""}
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
          "x-ui" => %{"placeholder" => "https://mcp.example.com"}
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
          "x-ui" => %{"placeholder" => "Bearer …"}
        }
      }
    }
  end

  @impl true
  def discover(%ToolInstance{} = tool_instance) do
    with {:ok, server_url} <- server_url(tool_instance),
         bearer_token <- bearer_token(tool_instance),
         {:ok, {session_id, init_result}} <- initialize(server_url, bearer_token: bearer_token) do
      case discover_tools_from_init(init_result) do
        {:ok, tools} ->
          {:ok, tools}

        {:fallback, :list_tools} ->
          list_tools(server_url, session_id, bearer_token: bearer_token)

        other ->
          {:error, other}
      end
    end
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, function_name, args, _execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    with {:ok, server_url} <- server_url(tool_instance),
         bearer_token <- bearer_token(tool_instance),
         {:ok, {session_id, _init_result}} <- initialize(server_url, bearer_token: bearer_token),
         {:ok, result} <-
           call_tool(server_url, session_id, function_name, args, bearer_token: bearer_token) do
      {:ok, result}
    end
  end

  defp server_url(%ToolInstance{} = tool_instance) do
    server_url =
      tool_instance
      |> Map.get(:config)
      |> case do
        %{} = cfg -> Map.get(cfg, "server_url") || Map.get(cfg, :server_url)
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
       Map.get(secrets, :bearer_token) ||
       Map.get(secrets, "token") ||
       Map.get(secrets, :token) ||
       "")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
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

    case post_jsonrpc(server_url, payload, bearer_token: bearer_token) do
      {:ok, %{session_id: session_id, messages: [%{"result" => %{} = result} | _]}} ->
        {:ok, {session_id, result}}

      {:ok, %{messages: []}} ->
        {:error, "MCP server returned no SSE messages for initialize()."}

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

    with {:ok, %{messages: [%{"result" => %{} = result} | _]}} <-
           post_jsonrpc(server_url, payload, bearer_token: bearer_token, session_id: session_id),
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
        {:error, "MCP server returned no SSE messages for tools/list."}
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

    case post_jsonrpc(server_url, payload,
           bearer_token: bearer_token,
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
        {:error, "MCP server returned no SSE messages for tools/call."}

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
    session_id = Keyword.get(opts, :session_id)
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    headers =
      []
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
      body_text = body_to_string(resp.body)
      messages = extract_sse_messages(body_text)

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

  defp body_to_string(nil), do: ""
  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_to_string(other), do: to_string(other)

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

  defp extract_sse_messages(_other), do: []

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
