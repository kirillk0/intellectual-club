defmodule IntellectualClub.Tools.Changes.ValidateToolType do
  @moduledoc """
  Validates supported tool instance types.

  For MVP we support a small fixed set of tool types.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Tools.Registry

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      raw =
        Changeset.get_attribute(changeset, :type) ||
          case changeset.data do
            %{type: type} -> type
            _ -> nil
          end

      type = raw |> to_string() |> String.trim()
      supported_types = Registry.list_types()

      cond do
        type == "" ->
          Changeset.add_error(changeset, field: :type, message: "is required")

        type not in supported_types ->
          Changeset.add_error(changeset,
            field: :type,
            message: "unsupported tool type"
          )

        true ->
          Changeset.force_change_attribute(changeset, :type, type)
      end
    end)
  end
end
