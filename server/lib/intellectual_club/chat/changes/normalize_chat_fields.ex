defmodule IntellectualClub.Chat.Changes.NormalizeChatFields do
  @moduledoc """
  Normalizes optional chat fields to stable defaults.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    note = Ash.Changeset.get_attribute(changeset, :note)

    Ash.Changeset.change_attribute(changeset, :note, normalize_note(note))
  end

  defp normalize_note(nil), do: ""
  defp normalize_note(note), do: to_string(note)
end
