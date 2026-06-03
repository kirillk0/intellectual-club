defmodule IntellectualClub.Accounts.User do
  @moduledoc """
  Application user account.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Accounts,
    extensions: [AshAuthentication, AshAdmin.Resource, AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Accounts.Changes.ValidatePasswordChange

  alias IntellectualClub.Accounts.Validations.{
    PreventSelfAdminDemotion,
    PreventSelfDestroy
  }

  sqlite do
    table("users")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("users")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :username, :string do
      allow_nil?(false)
      public?(true)
      constraints(min_length: 3, max_length: 64, trim?: true, allow_empty?: false)
    end

    attribute :hashed_password, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :is_admin, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :preferred_locale, :string do
      allow_nil?(true)
      public?(true)
      constraints(trim?: true, allow_empty?: false)
    end

    attribute :preferred_theme, :string do
      allow_nil?(false)
      public?(true)
      default("system")
      constraints(trim?: true, allow_empty?: false)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :user_knowledge_block_bindings, IntellectualClub.Accounts.UserKnowledgeBlock do
      destination_attribute(:owner_id)
    end

    has_many :user_group_memberships, IntellectualClub.Accounts.UserGroupMembership do
      destination_attribute(:user_id)
    end

    many_to_many :groups, IntellectualClub.Accounts.UserGroup do
      through(IntellectualClub.Accounts.UserGroupMembership)
      source_attribute_on_join_resource(:user_id)
      destination_attribute_on_join_resource(:user_group_id)
    end
  end

  identities do
    identity(:unique_username, [:username])
  end

  json_api do
    type "users"
  end

  admin do
    name("User")
    label_field(:username)
    relationship_display_fields([:username])
    table_columns([:id, :username, :is_admin, :created_at, :updated_at])
    read_actions([:read])
    create_actions([:create])
    update_actions([:update, :reset_password])
    destroy_actions([:destroy])
  end

  actions do
    defaults([:read])

    read :get_by_subject do
      description("Get a user by the subject claim in a JWT")
      argument(:subject, :string, allow_nil?: false)
      get?(true)
      prepare(AshAuthentication.Preparations.FilterBySubject)
    end

    read :get_current do
      description("Get the current user by actor id")
      argument(:id, :integer, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    create :create do
      description("Create a user as an admin")
      accept([:username, :is_admin])

      argument :groups, {:array, :integer} do
        allow_nil?(true)
        public?(true)
      end

      argument :password, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
      end

      argument :password_confirmation, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
      end

      validate {AshAuthentication.Strategy.Password.PasswordConfirmationValidation,
                strategy_name: :password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
      change(manage_relationship(:groups, type: :append_and_remove, value_is_key: :id))
      change(load(:groups))
    end

    update :update do
      accept([:username, :is_admin])
      require_atomic?(false)

      argument :groups, {:array, :integer} do
        allow_nil?(true)
        public?(true)
      end

      validate(PreventSelfAdminDemotion)
      change(manage_relationship(:groups, type: :append_and_remove, value_is_key: :id))
      change(load(:groups))
    end

    update :reset_password do
      description("Reset user password as an admin")
      accept([])
      require_atomic?(false)

      argument :password, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
      end

      argument :password_confirmation, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
      end

      validate {AshAuthentication.Strategy.Password.PasswordConfirmationValidation,
                strategy_name: :password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    update :change_password do
      description("Change password for the current user")
      accept([])
      require_atomic?(false)

      argument :current_password, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
      end

      argument :password, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
        constraints(min_length: 8)
      end

      argument :password_confirmation, :string do
        allow_nil?(false)
        public?(true)
        sensitive?(true)
      end

      validate {AshAuthentication.Strategy.Password.PasswordConfirmationValidation,
                strategy_name: :password}

      change({ValidatePasswordChange, strategy_name: :password})
      change({AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password})
    end

    update :update_settings do
      description("Update settings for the current user")
      accept([:preferred_locale, :preferred_theme])
      require_atomic?(false)

      validate(attribute_in(:preferred_locale, [nil, "en", "ru"]))
      validate(attribute_in(:preferred_theme, ["system", "light", "dark"]))
    end

    destroy :destroy do
      description("Delete a user as an admin")
      require_atomic?(false)

      validate(PreventSelfDestroy)
    end
  end

  authentication do
    tokens do
      enabled?(true)
      token_resource(IntellectualClub.Accounts.Token)
      store_all_tokens?(true)
      require_token_presence_for_authentication?(true)
      token_lifetime({30, :days})

      signing_secret fn _, _ ->
        {:ok, Application.fetch_env!(:intellectual_club, :token_signing_secret)}
      end
    end

    strategies do
      password :password do
        identity_field(:username)
        hashed_password_field(:hashed_password)
        confirmation_required?(true)
        registration_enabled?(false)
        sign_in_tokens_enabled?(true)
      end
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action(:change_password) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action([:get_current, :update_settings]) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action([:read, :create, :update, :reset_password, :destroy]) do
      authorize_if actor_attribute_equals(:is_admin, true)
      forbid_if always()
    end
  end
end
