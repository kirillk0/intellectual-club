defmodule IntellectualClub.Knowledge.Changes.NormalizeKnowledgeBlockFields do
  @moduledoc """
  Normalizes optional knowledge block fields to stable defaults.
  """

  use Ash.Resource.Change

  alias IntellectualClub.PromptVariables

  @impl true
  def change(changeset, _opts, _context) do
    variables = Ash.Changeset.get_attribute(changeset, :variables)

    Ash.Changeset.change_attribute(
      changeset,
      :variables,
      PromptVariables.normalize_map(variables)
    )
  end
end
