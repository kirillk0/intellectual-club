defmodule IntellectualClub.Generation.RequestImages.StagedBindings do
  @moduledoc """
  Opaque logical-file duplicates prepared before a destructive step replacement.

  A staged value must be attached to a replacement step or discarded by the caller.
  """

  @enforce_keys [:items]
  defstruct [:items]

  @type item :: %{
          required(:file_id) => integer(),
          required(:reference_key) => String.t(),
          required(:source_file_external_id) => String.t(),
          required(:variant_key) => String.t()
        }

  @type t :: %__MODULE__{items: [item()]}
end
