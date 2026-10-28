defmodule IntellectualClub.Chat.Calculations.MessageText do
  @moduledoc "Batched user-facing text projection for messages."
  use Ash.Resource.Calculation
  alias IntellectualClub.Chat.MessageText

  @impl true
  def load(_query, _opts, _context), do: [:id, :role]

  @impl true
  def calculate(records, _opts, context) do
    texts = MessageText.load_texts(records, context.actor)
    Enum.map(records, &Map.get(texts, &1.id, ""))
  end
end
