defmodule IntellectualClub.Tools.Changes.ValidateBotToolAlias do
  @moduledoc """
  Validates bot tool binding aliases.

  The alias becomes a prefix for model-visible tool names: `alias__function`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @alias_re ~r/^[A-Za-z][A-Za-z0-9_-]{0,63}$/

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      alias_value =
        changeset
        |> Changeset.get_attribute(:alias)
        |> to_string()
        |> String.trim()

      cond do
        alias_value == "" ->
          Changeset.add_error(changeset, field: :alias, message: "is required")

        String.contains?(alias_value, "__") ->
          Changeset.add_error(changeset,
            field: :alias,
            message: "must not contain \"__\""
          )

        not Regex.match?(@alias_re, alias_value) ->
          Changeset.add_error(changeset,
            field: :alias,
            message: "must match /^[A-Za-z][A-Za-z0-9_-]{0,63}$/"
          )

        true ->
          Changeset.force_change_attribute(changeset, :alias, alias_value)
      end
    end)
  end
end
