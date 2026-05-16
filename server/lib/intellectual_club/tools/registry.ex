defmodule IntellectualClub.Tools.Registry do
  @moduledoc """
  Tool driver registry.

  For MVP we keep it simple and register a small fixed set of tool types.
  """

  alias IntellectualClub.Tools.Drivers.McpHttp
  alias IntellectualClub.Tools.Drivers.NativeArtifactReader
  alias IntellectualClub.Tools.Drivers.NativeBraveSearch
  alias IntellectualClub.Tools.Drivers.NativeWebReader
  alias IntellectualClub.Tools.Drivers.Outlet
  alias IntellectualClub.Tools.Drivers.Ssh

  @spec driver_for_type!(String.t()) :: module()
  def driver_for_type!(tool_type) when is_binary(tool_type) do
    case String.trim(tool_type) do
      "mcp-http" -> McpHttp
      "mcp_http" -> McpHttp
      "native-artifact-reader" -> NativeArtifactReader
      "native-brave-search" -> NativeBraveSearch
      "native-web-reader" -> NativeWebReader
      "outlet" -> Outlet
      "ssh" -> Ssh
      other -> raise ArgumentError, "Unsupported tool type: #{inspect(other)}"
    end
  end

  @spec list_types() :: list(String.t())
  def list_types do
    [
      "mcp-http",
      "native-artifact-reader",
      "native-brave-search",
      "native-web-reader",
      "outlet",
      "ssh"
    ]
  end
end
