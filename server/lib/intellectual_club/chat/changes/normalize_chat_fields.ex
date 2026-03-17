defmodule IntellectualClub.Chat.Changes.NormalizeChatFields do
  @moduledoc """
  Normalizes optional chat fields to stable defaults.
  """

  use Ash.Resource.Change

  alias IntellectualClub.PromptVariables

  @impl true
  def change(changeset, _opts, _context) do
    note = Ash.Changeset.get_attribute(changeset, :note)
    variables = Ash.Changeset.get_attribute(changeset, :variables)

    changeset
    |> Ash.Changeset.change_attribute(:note, normalize_note(note))
    |> Ash.Changeset.change_attribute(:variables, PromptVariables.normalize_map(variables))
  end

  defp normalize_note(nil), do: ""
  defp normalize_note(note), do: to_string(note)
end
