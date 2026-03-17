defmodule IntellectualClub.Duplication do
  @moduledoc """
  Small helpers for server-side duplication actions.
  """

  @copy_suffix_regex ~r/^(?<base>.*?)(?:\s+copy(?:\s+(?<num>\d+))?)$/i

  @doc """
  Produces a user-friendly next "copy" label.

  Examples:

    - "v1" -> "v1 copy"
    - "v1 copy" -> "v1 copy 2"
    - "v1 copy 2" -> "v1 copy 3"
    - "" / nil -> "copy"
  """
  @spec next_copy_label(String.t() | nil) :: String.t()
  def next_copy_label(value) do
    base = (value || "") |> to_string() |> String.trim()

    if base == "" do
      "copy"
    else
      case Regex.named_captures(@copy_suffix_regex, base) do
        nil ->
          "#{base} copy"

        %{"base" => prefix, "num" => raw_num} ->
          prefix = String.trim(prefix || "")

          next_num =
            case Integer.parse(to_string(raw_num || "")) do
              {num, ""} when num >= 1 -> num + 1
              _ -> 2
            end

          if prefix == "" do
            "copy #{next_num}"
          else
            "#{prefix} copy #{next_num}"
          end
      end
    end
  end

  @doc """
  Returns true when the duplicated source belongs to the current actor.
  """
  @spec owned_by_actor?(integer() | nil, map() | nil) :: boolean
  def owned_by_actor?(source_owner_id, actor) do
    source_owner_id == actor_id(actor)
  end

  defp actor_id(%{id: id}) when is_integer(id), do: id
  defp actor_id(_actor), do: nil
end
