defmodule IntellectualClub.Generation.Context.StalePreparationError do
  @moduledoc "An optimistic generation preparation no longer matches its inputs."
  defexception [:chat_id, message: "Generation preparation is stale"]
end
