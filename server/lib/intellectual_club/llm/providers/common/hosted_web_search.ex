defmodule IntellectualClub.Llm.Providers.Common.HostedWebSearch do
  @moduledoc false

  alias IntellectualClub.Generation.RequestPayload

  @spec maybe_put_tool(map(), boolean(), map(), String.t()) :: map()
  def maybe_put_tool(parameters, enabled, default_tool, identity_key)
      when is_map(parameters) and is_map(default_tool) and is_binary(identity_key) do
    if enabled == true do
      parameters = RequestPayload.stringify_keys(parameters)
      default_tool = RequestPayload.stringify_keys(default_tool)
      configured_tools = configured_tools(parameters)
      identity = normalized_identity(default_tool, identity_key)

      if identity != "" and
           Enum.any?(configured_tools, &(normalized_identity(&1, identity_key) == identity)) do
        parameters
      else
        Map.put(parameters, "tools", configured_tools ++ [default_tool])
      end
    else
      parameters
    end
  end

  defp configured_tools(parameters) do
    case Map.get(parameters, "tools") do
      tools when is_list(tools) -> Enum.map(tools, &RequestPayload.stringify_keys/1)
      _other -> []
    end
  end

  defp normalized_identity(%{} = tool, key) do
    tool
    |> Map.get(key)
    |> to_string()
    |> String.trim()
  end

  defp normalized_identity(_tool, _key), do: ""
end
