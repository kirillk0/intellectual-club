defmodule IntellectualClub.Generation.Context.Preparation do
  @moduledoc """
  An authorized, read-only generation draft and its expected publication state.

  Content and settings may become stale; publication rechecks actor, branch and
  intent, not the draft's input contents. This internal, short-lived value is not
  a capability or a serialized API. Queue and lease checks belong to the caller.
  """

  @enforce_keys [:context, :actor_id, :chat_id, :parent_id, :last_message_id, :intent, :opts]
  defstruct [:context, :actor_id, :chat_id, :parent_id, :last_message_id, :intent, :opts]
end
