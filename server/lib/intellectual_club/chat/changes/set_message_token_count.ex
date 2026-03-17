defmodule IntellectualClub.Chat.Changes.SetMessageTokenCount do
  @moduledoc """
  Stores an estimated token count based on the chat message content.
  """

  use Ash.Resource.Change

  alias IntellectualClub.TokenCounter

  @impl true
  def change(changeset, _opts, _context) do
    content = Ash.Changeset.get_attribute(changeset, :content) || ""
    Ash.Changeset.change_attribute(changeset, :token_count, TokenCounter.estimate(content))
  end
end
