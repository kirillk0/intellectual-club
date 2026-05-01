defmodule IntellectualClub.Tools.Changes.ValidateToolAlias do
  @moduledoc """
  Validates tool instance aliases.

  The alias becomes a prefix for model-visible tool names: `alias__function`.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  require Ash.Query

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
        |> generated_alias(changeset)
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

  defp generated_alias(name, changeset) do
    name
    |> normalize_base()
    |> unique_alias(changeset)
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

  defp unique_alias(base, changeset) do
    owner_id = Changeset.get_attribute(changeset, :owner_id)
    actor = changeset.context[:private][:actor]
    existing_aliases = existing_aliases(changeset.resource, owner_id, actor)

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate =
        case index do
          0 -> base
          n -> with_suffix(base, "_#{n + 1}")
        end

      if MapSet.member?(existing_aliases, candidate), do: nil, else: candidate
    end)
  end

  defp existing_aliases(resource, owner_id, actor) when is_integer(owner_id) do
    resource
    |> Ash.Query.filter(owner_id == ^owner_id)
    |> Ash.Query.select([:alias])
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.alias)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  defp existing_aliases(_resource, _owner_id, _actor), do: MapSet.new()

  defp with_suffix(base, suffix) do
    suffix_length = String.length(suffix)

    base
    |> String.slice(0, @max_alias_length - suffix_length)
    |> Kernel.<>(suffix)
  end
end
