defmodule IntellectualClub.Generation.Context.Preparation do
  @moduledoc """
  An authorized, read-only generation draft and the revision of its input set.

  This is an internal, short-lived value, not a capability or a serialized API.
  Publication must authorize the actor again and compare the current revision.
  """

  @enforce_keys [:context, :actor_id, :chat_id, :parent_id, :revision, :opts]
  defstruct [:context, :actor_id, :chat_id, :parent_id, :revision, :opts]
end
