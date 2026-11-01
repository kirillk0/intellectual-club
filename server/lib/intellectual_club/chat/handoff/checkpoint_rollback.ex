defmodule IntellectualClub.Chat.Handoff.CheckpointRollback do
  @moduledoc false
  defexception [:reason]

  @impl true
  def message(_exception), do: "Context checkpoint publication rolled back"
end
