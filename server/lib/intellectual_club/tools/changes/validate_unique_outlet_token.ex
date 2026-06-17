defmodule IntellectualClub.Tools.Changes.ValidateUniqueOutletToken do
  @moduledoc """
  Ensures that outlet runner tokens identify a single outlet tool instance.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      type = tool_type(changeset)
      token = outlet_token(tool_secrets(changeset))

      if type == "outlet" and token != "" and token_used_by_another_outlet?(changeset, token) do
        Changeset.add_error(changeset,
          field: :secrets,
          message: "Outlet token is already used by another outlet."
        )
      else
        changeset
      end
    end)
  end

  defp token_used_by_another_outlet?(changeset, token) when is_binary(token) do
    current_id = current_id(changeset)

    ToolInstance
    |> Ash.Query.filter(type == "outlet")
    |> Ash.read!(actor: nil, authorize?: false)
    |> Enum.any?(fn tool_instance ->
      tool_instance_id(tool_instance) != current_id and
        outlet_token(Map.get(tool_instance, :secrets)) == token
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

  defp tool_secrets(changeset) do
    Changeset.get_attribute(changeset, :secrets) ||
      case changeset.data do
        %{secrets: %{} = secrets} -> secrets
        _ -> %{}
      end
  end

  defp outlet_token(%{} = secrets) do
    (Map.get(secrets, "bearer_token") ||
       Map.get(secrets, :bearer_token) ||
       Map.get(secrets, "token") ||
       Map.get(secrets, :token) ||
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
