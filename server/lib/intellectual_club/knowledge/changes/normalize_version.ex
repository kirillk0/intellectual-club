defmodule IntellectualClub.Knowledge.Changes.NormalizeVersion do
  @moduledoc """
  Normalizes the optional version field to an empty string.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :version) do
      nil ->
        Ash.Changeset.change_attribute(changeset, :version, "")

      version when is_binary(version) ->
        Ash.Changeset.change_attribute(changeset, :version, String.trim(version))

      _other ->
        changeset
    end
  end
end
