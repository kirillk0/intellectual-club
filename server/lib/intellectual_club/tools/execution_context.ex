defmodule IntellectualClub.Tools.ExecutionContext do
  @moduledoc """
  Immutable per-call execution context passed to tool drivers.
  """

  defstruct [
    :owner_id,
    :chat_id,
    :message_id,
    :assistant_message_id,
    :provider_type,
    :available_file_external_ids,
    :tool_call_item_id,
    :tool_call_created_at
  ]
end
