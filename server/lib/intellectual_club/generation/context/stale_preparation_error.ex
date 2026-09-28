defmodule IntellectualClub.Generation.Context.StalePreparationError do
  @moduledoc "A prepared generation no longer matches its publication state or intent."
  defexception [:chat_id, message: "Generation preparation is stale"]
end
