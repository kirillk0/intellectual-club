defmodule IntellectualClub.Secrets.Secret do
  @moduledoc """
  A user-owned encrypted value. Its plaintext is write-only at the resource boundary.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Secrets,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Secrets.Changes.EncryptValue

  postgres do
    table("managed_secrets")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:owner_id], name: "managed_secrets_owner_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(trim?: true, allow_empty?: false, max_length: 200)
    end

    attribute :description, :string do
      allow_nil?(false)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true, max_length: 2_000)
    end

    attribute :encrypted_value, :binary do
      allow_nil?(false)
      sensitive?(true)
    end

    create_timestamp(:created_at, public?: true)
    update_timestamp(:updated_at, public?: true)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    has_one :knowledge_block_attachment, IntellectualClub.Secrets.KnowledgeBlockSecret do
      destination_attribute(:secret_id)
    end

    has_one :tool_instance_attachment, IntellectualClub.Secrets.ToolInstanceSecret do
      destination_attribute(:secret_id)
    end
  end

  identities do
    identity(:unique_owner_external_id, [:owner_id, :external_id])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
    end

    create :create do
      accept([:name, :description])

      argument :value, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
        constraints(allow_empty?: false)
      end

      change(relate_actor(:owner))
      change({EncryptValue, []})
    end

    create :create_encrypted do
      accept([:name, :description, :encrypted_value])
      change(relate_actor(:owner))
    end

    update :update do
      primary?(true)
      accept([:name, :description])
      require_atomic?(false)

      argument :value, :string do
        allow_nil?(true)
        public?(true)
        sensitive?(true)
        constraints(allow_empty?: false)
      end

      change({EncryptValue, []})
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(
                       knowledge_block_attachment,
                       enabled == true and
                         (knowledge_block.owner_id == ^actor(:id) or
                            exists(
                              knowledge_block.shares.user_group.memberships,
                              user_id == ^actor(:id)
                            ) or
                            exists(
                              knowledge_block.bot_bindings,
                              enabled == true and
                                exists(
                                  bot.shares.user_group.memberships,
                                  user_id == ^actor(:id)
                                )
                            ) or
                            exists(
                              knowledge_block.llm_configuration_bindings,
                              enabled == true and
                                exists(
                                  llm_configuration.shares.user_group.memberships,
                                  user_id == ^actor(:id)
                                )
                            ))
                     )
                   )

      authorize_if expr(
                     exists(
                       tool_instance_attachment,
                       enabled == true and
                         (tool_instance.owner_id == ^actor(:id) or
                            exists(
                              tool_instance.shares.user_group.memberships,
                              user_id == ^actor(:id)
                            ) or
                            exists(
                              tool_instance.bot_bindings,
                              enabled == true and sharing_mode == :shared and
                                exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
                            ))
                     )
                   )
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
