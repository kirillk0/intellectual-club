defmodule IntellectualClub.Tools.Registry do
  @moduledoc """
  Tool driver registry.

  For MVP we keep it simple and register a small fixed set of tool types.
  """

  alias IntellectualClub.Tools.Drivers.McpHttp
  alias IntellectualClub.Tools.Drivers.NativeAgentManagement
  alias IntellectualClub.Tools.Drivers.NativeArtifactReader
  alias IntellectualClub.Tools.Drivers.NativeBraveSearch
  alias IntellectualClub.Tools.Drivers.NativeKnowledgeLibrary
  alias IntellectualClub.Tools.Drivers.NativeWebReader
  alias IntellectualClub.Tools.Drivers.Outlet
  alias IntellectualClub.Tools.Drivers.Ssh

  @spec driver_for_type!(String.t()) :: module()
  def driver_for_type!(tool_type) when is_binary(tool_type) do
    case String.trim(tool_type) do
      "mcp-http" -> McpHttp
      "mcp_http" -> McpHttp
      "native-agent-management" -> NativeAgentManagement
      "native-artifact-reader" -> NativeArtifactReader
      "native-brave-search" -> NativeBraveSearch
      "native-knowledge-library" -> NativeKnowledgeLibrary
      "native-web-reader" -> NativeWebReader
      "outlet" -> Outlet
      "ssh" -> Ssh
      other -> raise ArgumentError, "Unsupported tool type: #{inspect(other)}"
    end
  end

  @spec supports_artifacts?(String.t() | map() | nil) :: boolean()
  def supports_artifacts?(%{type: type}), do: supports_artifacts?(type)

  def supports_artifacts?(tool_type) when is_binary(tool_type) do
    tool_type
    |> driver_for_type!()
    |> apply(:supports_artifacts?, [])
    |> case do
      true -> true
      _other -> false
    end
  rescue
    _exception -> false
  end

  def supports_artifacts?(_other), do: false

  @spec supports_handoff?(String.t() | map() | nil) :: boolean()
  def supports_handoff?(%{type: type}), do: supports_handoff?(type)
  def supports_handoff?(%{"type" => type}), do: supports_handoff?(type)

  def supports_handoff?(tool_type) when is_binary(tool_type) do
    driver = driver_for_type!(tool_type)

    if function_exported?(driver, :supports_handoff?, 0) do
      case apply(driver, :supports_handoff?, []) do
        true -> true
        _other -> false
      end
    else
      false
    end
  rescue
    _exception -> false
  end

  def supports_handoff?(_other), do: false

  @spec list_types() :: list(String.t())
  def list_types do
    [
      "mcp-http",
      "native-agent-management",
      "native-artifact-reader",
      "native-brave-search",
      "native-knowledge-library",
      "native-web-reader",
      "outlet",
      "ssh"
    ]
  end
end
