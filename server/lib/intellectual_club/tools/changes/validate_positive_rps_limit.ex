defmodule IntellectualClub.Tools.Changes.ValidatePositiveRpsLimit do
  @moduledoc """
  Validates optional tool instance RPS limits.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      case Changeset.get_attribute(changeset, :rps_limit) do
        nil ->
          changeset

        value when is_number(value) and value > 0 ->
          changeset

        _other ->
          Changeset.add_error(changeset,
            field: :rps_limit,
            message: "must be greater than 0"
          )
      end
    end)
  end
end
