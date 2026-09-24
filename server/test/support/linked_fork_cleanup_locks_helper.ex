defmodule IntellectualClub.Chat.LinkedForkCleanupLocksHelper do
  @moduledoc """
  Test-only adapter from a resource record to a cleanup plan scope.

  Message preflight historically included the entire physical subtree; tests
  written against that API map to `:message_tree`. Production code must call
  `LinkedForkCleanupLocks.prepare!/2` with its exact operation scope instead.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.LinkedForkCleanupLocks

  @scopes %{Chat => :chat, ChatMessage => :message_tree, ChatMessageStep => :step}

  def lock!(resource, %{id: id, owner_id: owner_id}, %{id: owner_id} = actor)
      when is_map_key(@scopes, resource) do
    case LinkedForkCleanupLocks.prepare!({Map.fetch!(@scopes, resource), id}, actor) do
      nil -> nil
      plan -> plan.root_record
    end
  end

  def lock!(_resource, _record, _actor) do
    raise ArgumentError, "Only the owner can lock linked fork cleanup dependencies"
  end
end
