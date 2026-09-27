defmodule IntellectualClub.Generation.StepRequests.Snapshot do
  @moduledoc """
  A normalized JSON object and its canonical hash and byte size.

  This is a computation cache, not an authorization credential. Ash actions must
  build it from logical input themselves; caller-supplied structs are not proof.
  """

  @enforce_keys [:request, :hash, :size]
  defstruct [:request, :hash, :size]
end
