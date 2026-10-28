defmodule IntellectualClub.Chat.Calculations.MessageActiveBranch do
  @moduledoc "Batched active-local-branch membership for stored messages."
  use Ash.Resource.Calculation
  alias IntellectualClub.Chat.Threads

  @impl true
  def load(_query, _opts, _context), do: [:id, :chat_id]

  @impl true
  def calculate(records, _opts, context) do
    ids = records |> Enum.map(& &1.chat_id) |> Enum.uniq()
    active = Threads.active_branch_ids_by_chat(ids, context.actor)
    Enum.map(records, &MapSet.member?(Map.get(active, &1.chat_id, MapSet.new()), &1.id))
  end
end
