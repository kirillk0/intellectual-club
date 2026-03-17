defmodule IntellectualClub.Tools.Changes.MergeSecretsPatch do
  @moduledoc """
  Applies patch semantics to `secrets` without exposing existing values.

  Rules:
  - Keys not present in the patch remain unchanged.
  - `nil` or empty string values unset the key.
  - Tool-specific aliases are normalized to canonical keys.
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @canonical_key "bearer_token"
  @alias_keys ["token"]

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      if Changeset.changing_attribute?(changeset, :secrets) do
        patch = Changeset.get_attribute(changeset, :secrets)

        current =
          case changeset.data do
            %{secrets: secrets} when is_map(secrets) -> secrets
            _ -> %{}
          end

        merged = apply_patch(current, patch)
        Changeset.force_change_attribute(changeset, :secrets, merged)
      else
        changeset
      end
    end)
  end

  defp apply_patch(current, patch) when is_map(current) do
    patch = if is_map(patch), do: patch, else: %{}

    Enum.reduce(patch, Map.new(current), fn {raw_key, value}, merged ->
      key = normalize_secret_key(raw_key)

      cond do
        key == nil ->
          merged

        empty_secret?(value) ->
          merged =
            merged
            |> Map.delete(key)
            |> delete_aliases_for(key)

          if key in @alias_keys do
            merged
            |> Map.delete(@canonical_key)
            |> delete_aliases_for(@canonical_key)
          else
            merged
          end

        key == @canonical_key ->
          merged
          |> Map.put(key, value)
          |> delete_aliases_for(key)

        key in @alias_keys ->
          merged
          |> Map.put(@canonical_key, value)
          |> Map.delete(key)

        true ->
          Map.put(merged, key, value)
      end
    end)
  end

  defp apply_patch(_current, _patch), do: %{}

  defp normalize_secret_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_secret_key()

  defp normalize_secret_key(key) when is_binary(key) do
    key = String.trim(key)
    if key == "", do: nil, else: key
  end

  defp normalize_secret_key(_other), do: nil

  defp empty_secret?(nil), do: true
  defp empty_secret?(value) when is_binary(value), do: String.trim(value) == ""
  defp empty_secret?(_other), do: false

  defp delete_aliases_for(map, @canonical_key) when is_map(map) do
    Enum.reduce(@alias_keys, map, fn alias_key, acc -> Map.delete(acc, alias_key) end)
  end

  defp delete_aliases_for(map, _key) when is_map(map), do: map
end
