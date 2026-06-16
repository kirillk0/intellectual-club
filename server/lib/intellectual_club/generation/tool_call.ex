defmodule IntellectualClub.Generation.ToolCall do
  @moduledoc """
  Canonical persisted tool call used by the generation worker.
  """

  @type t :: %__MODULE__{
          item_id: integer() | nil,
          step_id: integer() | nil,
          sequence: integer() | nil,
          created_at: DateTime.t() | nil,
          call_id: String.t(),
          name: String.t(),
          args: map(),
          raw: map()
        }

  defstruct item_id: nil,
            step_id: nil,
            sequence: nil,
            created_at: nil,
            call_id: "",
            name: "",
            args: %{},
            raw: %{}
end
