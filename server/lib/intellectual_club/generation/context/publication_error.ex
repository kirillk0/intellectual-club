defmodule IntellectualClub.Generation.Context.PublicationError do
  @moduledoc "Rolls back a publication callback that returned an error after mutation."
  defexception [:reason, message: "Generation publication was rejected"]
end
