defmodule IntellectualClub.Outlets.Auth do
  @moduledoc """
  Outlet runner authentication helpers.

  Runners authenticate with a bearer token stored as a managed driver secret.
  """

  alias IntellectualClub.Secrets.DriverSecrets
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
      |> Ash.Query.load(
        driver_secret_bindings: [
          :env_name,
          :enabled,
          secret: [:encrypted_value]
        ]
      )
      |> Ash.read(actor: nil, authorize?: false)
      |> case do
        {:ok, items} -> find_verified_match(items, token)
        _other -> nil
      end
    end
  end

  defp find_verified_match(items, token) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, verified} ->
      case DriverSecrets.values(item) do
        {:ok, secrets} -> {:cont, {:ok, [{item, outlet_token(secrets)} | verified]}}
        {:error, _message} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, verified} ->
        case Enum.filter(verified, fn {_item, stored_token} -> stored_token == token end) do
          [{item, _token}] -> item
          _none_or_ambiguous -> nil
        end

      :error ->
        nil
    end
  end

  defp outlet_token(secrets) do
    value =
      Map.get(secrets, "token") ||
        Map.get(secrets, "bearer_token") ||
        ""

    if is_binary(value), do: String.trim(value), else: ""
  end
end
