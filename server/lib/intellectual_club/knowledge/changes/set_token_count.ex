defmodule IntellectualClub.Knowledge.Changes.SetTokenCount do
  @moduledoc """
  Stores an estimated token count based on the resource content.
  """

  use Ash.Resource.Change

  alias IntellectualClub.Knowledge.PromptContent
  alias IntellectualClub.TokenCounter

  @impl true
  def change(changeset, _opts, _context) do
    content =
      changeset
      |> Ash.Changeset.get_attribute(:content)
      |> PromptContent.strip_comments()

    Ash.Changeset.change_attribute(changeset, :token_count, TokenCounter.estimate(content))
  end
end
