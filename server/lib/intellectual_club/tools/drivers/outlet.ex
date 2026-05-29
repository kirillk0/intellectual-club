defmodule IntellectualClub.Tools.Drivers.Outlet do
  @moduledoc """
  Outlet runner driver (HTTP long polling).

  The runner connects to the server and executes tool calls on behalf of a
  `ToolInstance` of type `outlet`. The server-side transport is implemented in
  `IntellectualClub.Outlets.Runtime` and is intentionally in-memory (non-durable).
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  @impl true
  def type, do: "outlet"

  @impl true
  def title, do: "Outlet"

  @impl true
  def description, do: "Execute tools via an outlet runner using HTTP long polling."

  @impl true
  def functions_mode, do: :stored

  @impl true
  def supports_discovery?, do: true

  @impl true
  def supports_artifacts?, do: true

  @impl true
  def instance_prompt_context(%ToolInstance{} = tool_instance) do
    metadata = Runtime.runner_metadata(tool_instance)

    [
      metadata_line("Runner hostname", metadata_value(metadata, "hostname")),
      metadata_line("Runner platform", platform_summary(metadata)),
      metadata_line("Runner shell", shell_summary(metadata))
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      context -> context
    end
  end

  @impl true
  def default_config do
    %{
      "max_concurrency" => 20,
      "poll_max_wait_seconds" => 25.0,
      "runner_online_timeout_seconds" => 60.0,
      "disconnect_grace_seconds" => 300.0
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "max_concurrency" => %{
          "type" => "integer",
          "title" => "Max concurrency",
          "description" => "Maximum concurrent calls per runner.",
          "minimum" => 1
        },
        "poll_max_wait_seconds" => %{
          "type" => "number",
          "title" => "Poll max wait (seconds)",
          "description" => "Maximum long-poll wait time in seconds.",
          "minimum" => 0
        },
        "runner_online_timeout_seconds" => %{
          "type" => "number",
          "title" => "Runner online timeout (seconds)",
          "description" => "How long the runner can stay silent before considered offline.",
          "minimum" => 0
        },
        "disconnect_grace_seconds" => %{
          "type" => "number",
          "title" => "Disconnect grace (seconds)",
          "description" => "How long to wait for a runner after it goes offline.",
          "minimum" => 0
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
          "title" => "Runner token",
          "description" => "Outlet runner token.",
          "x-aliases" => ["bearer_token"],
          "x-ui" => %{"placeholder" => "Outlet runner token"}
        }
      }
    }
  end

  @impl true
  def discover(%ToolInstance{} = tool_instance) do
    with {:ok, {_text, %{} = raw}} <-
           normalize_discovery_result(
             Runtime.enqueue_and_wait(tool_instance, "outlet.list_tools", %{})
           ) do
      discovered_tools_from_raw(raw)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "Outlet discovery returned an invalid payload."}
    end
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, function_name, args, execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    case Runtime.enqueue_and_wait(tool_instance, function_name, args || %{}, execution_context) do
      {:ok, result} ->
        {:ok, ExecutionResult.normalize(result)}

      {:error, reason} ->
        {:error, to_string(reason || "Outlet call failed.")}
    end
  end

  defp normalize_discovery_result({:ok, {text, %{} = raw}}) do
    {:ok, {to_string(text || ""), raw}}
  end

  defp normalize_discovery_result({:ok, %ExecutionResult{} = result}) do
    normalize_discovery_payload(%{text: result.text, raw: result.raw})
  end

  defp normalize_discovery_result({:ok, %{} = result}) do
    normalize_discovery_payload(result)
  end

  defp normalize_discovery_result({:error, reason}), do: {:error, reason}

  defp normalize_discovery_result(other),
    do: {:error, "Unexpected outlet response: #{inspect(other)}"}

  defp normalize_discovery_payload(%{} = result) do
    text =
      result
      |> Map.get("text", Map.get(result, :text, ""))
      |> to_string()

    raw =
      case Map.get(result, "raw", Map.get(result, :raw)) do
        %{} = raw -> raw
        _other -> result
      end

    {:ok, {text, raw}}
  end

  defp metadata_line(_label, ""), do: ""
  defp metadata_line(label, value), do: "#{label}: #{value}"

  defp metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    (Map.get(metadata, key) || Map.get(metadata, String.to_atom(key)) || "")
    |> to_string()
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp metadata_value(_metadata, _key), do: ""

  defp platform_summary(metadata) when is_map(metadata) do
    platform = metadata_value(metadata, "platform")
    sys_platform = metadata_value(metadata, "sys_platform")
    os_name = metadata_value(metadata, "os_name")

    details =
      []
      |> maybe_append_detail("sys.platform", sys_platform)
      |> maybe_append_detail("os.name", os_name)
      |> Enum.join(", ")

    cond do
      platform != "" and details != "" -> "#{platform} (#{details})"
      platform != "" -> platform
      details != "" -> details
      true -> ""
    end
  end

  defp platform_summary(_metadata), do: ""

  defp shell_summary(metadata) when is_map(metadata) do
    shell_display = metadata_value(metadata, "shell_display")
    shell_kind = metadata_value(metadata, "shell_kind")

    cond do
      shell_display != "" and shell_kind != "" -> "#{shell_display} (kind: #{shell_kind})"
      shell_display != "" -> shell_display
      shell_kind != "" -> shell_kind
      true -> ""
    end
  end

  defp shell_summary(_metadata), do: ""

  defp maybe_append_detail(parts, _label, ""), do: parts
  defp maybe_append_detail(parts, label, value), do: parts ++ ["#{label}=#{value}"]

  @spec discovered_tools_from_raw(map()) :: {:ok, list(map())} | {:error, String.t()}
  def discovered_tools_from_raw(%{} = raw) do
    case Map.get(raw, "tools", Map.get(raw, :tools)) do
      tools when is_list(tools) ->
        discovered =
          Enum.flat_map(tools, fn item ->
            if is_map(item) do
              name =
                item |> Map.get("name", Map.get(item, :name, "")) |> to_string() |> String.trim()

              if name != "" do
                description =
                  item
                  |> Map.get("description", Map.get(item, :description, ""))
                  |> to_string()

                schema =
                  cond do
                    is_map(Map.get(item, "input_schema")) -> Map.get(item, "input_schema")
                    is_map(Map.get(item, :input_schema)) -> Map.get(item, :input_schema)
                    is_map(Map.get(item, "schema")) -> Map.get(item, "schema")
                    is_map(Map.get(item, :schema)) -> Map.get(item, :schema)
                    true -> %{"type" => "object", "properties" => %{}}
                  end

                schema =
                  if description != "" and is_map(schema) and
                       Map.get(schema, "description") in [nil, ""] do
                    Map.put(schema, "description", description)
                  else
                    schema
                  end

                [
                  %{
                    "name" => name,
                    "description" => description,
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

        if discovered == [] do
          {:error, "Outlet discovery returned no tools."}
        else
          {:ok, discovered}
        end

      _other ->
        {:error, "Outlet discovery returned an invalid payload."}
    end
  end
end
