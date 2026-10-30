defmodule IntellectualClub.Chat.Calculations.ReadState do
  @moduledoc "Batch-load personal state without per-chat queries."
  use Ash.Resource.Calculation

  def calculate(records, _opts, context) do
    states = IntellectualClub.Chat.ReadState.load_many(records, context.actor)
    Enum.map(records, &Map.fetch!(states, &1.id))
  end
end
