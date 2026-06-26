defmodule IntellectualClub.Accounts.UserGroup do
  @moduledoc """
  Administrative group that can be assigned to multiple users.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Accounts,
    extensions: [AshAdmin.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table("user_groups")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("user_groups")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 1, max_length: 128, trim?: true, allow_empty?: false)
    end

    create_timestamp(:created_at, public?: true)
    update_timestamp(:updated_at, public?: true)
  end

  relationships do
    has_many :memberships, IntellectualClub.Accounts.UserGroupMembership do
      destination_attribute(:user_group_id)
    end

    has_many :bot_shares, IntellectualClub.Bots.BotShare do
      destination_attribute(:user_group_id)
    end

    has_many :llm_configuration_shares, IntellectualClub.Llm.LlmConfigurationShare do
      destination_attribute(:user_group_id)
    end

    has_many :chat_shares, IntellectualClub.Chat.ChatShare do
      destination_attribute(:user_group_id)
    end

    many_to_many :users, IntellectualClub.Accounts.User do
      through(IntellectualClub.Accounts.UserGroupMembership)
      source_attribute_on_join_resource(:user_group_id)
      destination_attribute_on_join_resource(:user_id)
      public?(true)
    end
  end

  identities do
    identity(:unique_name, [:name])
  end

  json_api do
    type "user-groups"
    includes([:users])
  end

  admin do
    name("User Group")
    label_field(:name)
    relationship_display_fields([:name])
    table_columns([:id, :name, :created_at, :updated_at])
    read_actions([:read])
    create_actions([:create])
    update_actions([:update])
    destroy_actions([:destroy])
  end

  actions do
    defaults([:read])

    read :admin_read do
      description("Read user groups as an admin")
    end

    create :create do
      accept([:name])

      argument :users, {:array, :integer} do
        allow_nil?(true)
        public?(true)
      end

      change(manage_relationship(:users, type: :append_and_remove, value_is_key: :id))
      change(load(:users))
    end

    update :update do
      accept([:name])
      require_atomic?(false)

      argument :users, {:array, :integer} do
        allow_nil?(true)
        public?(true)
      end

      change(manage_relationship(:users, type: :append_and_remove, value_is_key: :id))
      change(load(:users))
    end

    destroy :destroy do
      primary?(true)
    end
  end

  policies do
    policy action(:admin_read) do
      authorize_if actor_attribute_equals(:is_admin, true)
      forbid_if always()
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:is_admin, true)
      authorize_if expr(exists(memberships, user_id == ^actor(:id)))
      forbid_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if actor_attribute_equals(:is_admin, true)
      forbid_if always()
    end
  end
end
