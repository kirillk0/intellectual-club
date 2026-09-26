defmodule IntellectualClub.Generation.Lease.State do
  @moduledoc false

  defstruct [:connection, leases: %{}, cleanups: %{}, validation_failures: 0]
end
