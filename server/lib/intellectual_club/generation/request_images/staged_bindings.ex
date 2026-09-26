defmodule IntellectualClub.Generation.RequestImages.StagedBindings do
  @moduledoc """
  Opaque logical files prepared before immutable request publication or copying.

  A staged value must be attached to a new step or discarded by the caller after
  rollback. Preparation never attaches files to an existing request snapshot.
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
