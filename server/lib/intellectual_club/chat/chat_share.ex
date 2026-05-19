defmodule IntellectualClub.Chat.ChatShare do
  @moduledoc """
  Grants read-only access to a live chat for all members of a user group.

  The bot and configuration snapshots intentionally make shares dependent on
  the exact chat access boundary that was validated at sharing time.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Accounts.Changes.RequireActorMembershipInRelatedUserGroup
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  sqlite do
    table("chat_shares")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_shares")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :chat, IntellectualClub.Chat.Chat,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :user_group, IntellectualClub.Accounts.UserGroup,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :bot, IntellectualClub.Bots.Bot,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_pair, [:chat_id, :user_group_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:chat_id, :user_group_id, :bot_id, :llm_configuration_id])

      change(
        {RequireRelatedAccessByActor,
         relationships: [:chat, :bot, :llm_configuration],
         access: [chat: :writable, bot: :readable, llm_configuration: :readable]}
      )

      change({RequireActorMembershipInRelatedUserGroup, relationship: :user_group})
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(chat.owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if expr(chat.owner_id == ^actor(:id))
    end
  end
end
