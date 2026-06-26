defmodule IntellectualClub.Outlets.Auth do
  @moduledoc """
  Outlet runner authentication helpers.

  Runners authenticate with a bearer token stored in `tool_instances.secrets`.
  """

  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @spec tool_instance_for_token(String.t()) :: ToolInstance.t() | nil
  def tool_instance_for_token(token) when is_binary(token) do
    token = String.trim(token)

    if token == "" do
      nil
    else
      ToolInstance
      |> Ash.Query.filter(type == "outlet")
      |> Ash.read(actor: nil, authorize?: false)
      |> case do
        {:ok, items} ->
          Enum.find(items, fn item -> token_matches?(item, token) end)

        _ ->
          nil
      end
    end
  end

  defp token_matches?(tool_instance, token) when is_map(tool_instance) and is_binary(token) do
    secrets = Map.get(tool_instance, :secrets) || %{}
    secrets = if is_map(secrets), do: secrets, else: %{}

    value =
      Map.get(secrets, "token") ||
        Map.get(secrets, :token) ||
        Map.get(secrets, "bearer_token") ||
        Map.get(secrets, :bearer_token) ||
        ""

    is_binary(value) and String.trim(value) == token
  end
end
