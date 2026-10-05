defmodule IntellectualClub.Chat.ForkHistoryCorruptFixture do
  @moduledoc """
  Test-only Ash access to corrupt legacy anchors that current Chat actions reject.

  This resource has no public routes or application domain registration. It deliberately omits
  anchor validation, but retains owner authorization and database foreign keys so
  reader fail-closed behavior can be exercised with real persisted records.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat.ForkHistoryFixtureDomain,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("chats")
    repo(IntellectualClub.Repo)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:owner_id, :integer, allow_nil?: false)
    attribute(:fork_source_step_id, :integer)
    attribute(:fork_task, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:parent_chat_id, :integer)
    attribute(:parent_message_id, :integer)
    attribute(:parent_tool_call_item_id, :integer)
    attribute(:parent_relation_kind, :atom, constraints: [one_of: [:fork, :handoff, :spawn]])
    attribute(:subagent, :boolean)
  end

  actions do
    defaults([:read])

    update :corrupt_anchor do
      accept([
        :fork_source_step_id,
        :fork_task,
        :parent_chat_id,
        :parent_message_id,
        :parent_tool_call_item_id,
        :parent_relation_kind,
        :subagent
      ])
    end
  end

  policies do
    policy action_type([:read, :update]) do
      authorize_if expr(owner_id == ^actor(:id))
    end
  end
end
