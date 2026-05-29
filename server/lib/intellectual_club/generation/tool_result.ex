defmodule IntellectualClub.Generation.ToolResult do
  @moduledoc """
  Canonical persisted tool result linked to a tool call item.
  """

  @type t :: %__MODULE__{
          item_id: integer() | nil,
          step_id: integer() | nil,
          tool_call_item_id: integer() | nil,
          sequence: integer() | nil,
          call_id: String.t(),
          name: String.t(),
          args: map(),
          text: String.t(),
          raw: map(),
          result_raw: map(),
          responses_item: map() | nil,
          media_contents: list(map()),
          artifact_contents: list(map())
        }

  defstruct item_id: nil,
            step_id: nil,
            tool_call_item_id: nil,
            sequence: nil,
            call_id: "",
            name: "",
            args: %{},
            text: "",
            raw: %{},
            result_raw: %{},
            responses_item: nil,
            media_contents: [],
            artifact_contents: []
end
