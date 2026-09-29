defmodule IntellectualClub.Chat.ForkHistoryStepCorruptFixture do
  @moduledoc """
  Test-only legacy step identity corruption, retaining owner checks and database FKs.

  No application domain or public route exposes this resource. Production step
  actions deliberately reject these changes; reader fail-closed tests need them.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat.ForkHistoryFixtureDomain,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("chat_message_steps")
    repo(IntellectualClub.Repo)
  end

  attributes do
    integer_primary_key(:id)
    attribute(:owner_id, :integer, allow_nil?: false)
    attribute(:chat_message_id, :integer, allow_nil?: false)
    attribute(:sequence, :integer, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    update :corrupt_identity do
      accept([:owner_id, :chat_message_id, :sequence, :updated_at])
    end
  end

  policies do
    policy action_type([:read, :update]) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end
  end
end
