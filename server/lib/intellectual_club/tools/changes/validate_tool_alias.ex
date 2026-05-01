defmodule IntellectualClub.Tools.Changes.ValidateToolAlias do
  @moduledoc """
  Validates tool instance aliases.

  The alias becomes a prefix for model-visible tool names: `alias__function`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @alias_re ~r/^[A-Za-z][A-Za-z0-9_-]{0,63}$/
  @max_alias_length 64

  @impl true
  def change(changeset, _opts, _context) do
    alias_value =
      changeset
      |> Changeset.get_attribute(:alias)
      |> to_string()
      |> String.trim()

    alias_value =
      if alias_value == "" and changeset.action.type == :create do
        changeset
        |> Changeset.get_attribute(:name)
        |> generated_alias()
      else
        alias_value
      end

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
  end

  defp generated_alias(name) do
    name
    |> normalize_base()
  end

  defp normalize_base(value) do
    base =
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]+/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_-")
      |> String.slice(0, @max_alias_length)

    if Regex.match?(~r/^[a-z]/, base), do: base, else: "tool"
  end
end
