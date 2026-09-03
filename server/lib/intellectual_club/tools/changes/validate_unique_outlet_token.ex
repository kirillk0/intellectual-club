defmodule IntellectualClub.Tools.Changes.ValidateUniqueOutletToken do
  @moduledoc """
  Ensures that outlet runner tokens identify a single outlet tool instance.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Secrets.DriverSecrets
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      type = tool_type(changeset)

      with {:ok, secrets} <- DriverSecrets.values_for_changeset(changeset),
           token = outlet_token(secrets),
           {:ok, used?} <- token_used_by_another_outlet(changeset, type, token) do
        if used? do
          Changeset.add_error(changeset,
            field: :secrets,
            message: "Outlet token is already used by another outlet."
          )
        else
          changeset
        end
      else
        {:error, message} ->
          Changeset.add_error(changeset, field: :secrets, message: message)
      end
    end)
  end

  defp token_used_by_another_outlet(_changeset, type, token)
       when type != "outlet" or token == "",
       do: {:ok, false}

  defp token_used_by_another_outlet(changeset, "outlet", token) do
    current_id = current_id(changeset)

    ToolInstance
    |> Ash.Query.filter(type == "outlet")
    |> Ash.Query.load(
      driver_secret_bindings: [
        :env_name,
        :enabled,
        secret: [:encrypted_value]
      ]
    )
    |> Ash.read!(actor: nil, authorize?: false)
    |> Enum.reject(&(tool_instance_id(&1) == current_id))
    |> Enum.reduce_while({:ok, false}, fn tool_instance, {:ok, false} ->
      case DriverSecrets.values(tool_instance) do
        {:ok, secrets} ->
          if outlet_token(secrets) == token do
            {:halt, {:ok, true}}
          else
            {:cont, {:ok, false}}
          end

        {:error, _message} ->
          {:halt, {:error, "Existing outlet credentials could not be verified."}}
      end
    end)
  end

  defp tool_type(changeset) do
    raw =
      Changeset.get_attribute(changeset, :type) ||
        case changeset.data do
          %{type: type} -> type
          _ -> nil
        end

    raw
    |> to_string()
    |> String.trim()
  end

  defp outlet_token(%{} = secrets) do
    (Map.get(secrets, "bearer_token") ||
       Map.get(secrets, "token") ||
       "")
    |> to_string()
    |> String.trim()
  end

  defp outlet_token(_secrets), do: ""

  defp current_id(changeset) do
    case changeset.data do
      %{id: id} when is_integer(id) -> id
      _ -> nil
    end
  end

  defp tool_instance_id(%{id: id}) when is_integer(id), do: id
  defp tool_instance_id(_tool_instance), do: nil
end
