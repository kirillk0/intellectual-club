defmodule IntellectualClub.Tools.ToolFunction do
  @moduledoc """
  A discovered or user-managed tool function definition for stored-mode tools.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Tools,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  postgres do
    table("tool_functions")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:owner_id], name: "tool_functions_owner_id_index")
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :description, :string do
      allow_nil?(false)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :parameters_schema, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
    end

    attribute :discovery_available, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
    end

    attribute :execution_mode, :atom do
      allow_nil?(false)
      default(:direct)
      constraints(one_of: [:direct, :background])
    end

    attribute :target_function_name, :string do
      allow_nil?(true)
    end

    attribute :discovered_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      default(&DateTime.utc_now/0)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :tool_instance, IntellectualClub.Tools.ToolInstance,
      allow_nil?: false,
      attribute_type: :integer
  end

  identities do
    identity(:unique_instance_name, [:tool_instance_id, :name])
  end

  json_api do
    type "tool-functions"
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :tool_instance_id,
        :name,
        :description,
        :parameters_schema,
        :enabled,
        :discovery_available,
        :execution_mode,
        :target_function_name,
        :discovered_at
      ])

      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:tool_instance], access: :writable})
      change(&validate_background_metadata/2)
    end

    update :update do
      accept([
        :description,
        :parameters_schema,
        :enabled,
        :discovery_available,
        :execution_mode,
        :target_function_name
      ])

      require_atomic?(false)
      change(&validate_background_metadata/2)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(
                       tool_instance.shares.user_group.memberships,
                       user_id == ^actor(:id)
                     )
                   )

      authorize_if expr(
                     exists(
                       tool_instance.bot_bindings,
                       enabled == true and sharing_mode == :shared and
                         exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
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

  defp validate_background_metadata(changeset, _context) do
    execution_mode = Ash.Changeset.get_attribute(changeset, :execution_mode)
    target_function_name = Ash.Changeset.get_attribute(changeset, :target_function_name)

    if execution_mode == :background and
         (not is_binary(target_function_name) or String.trim(target_function_name) == "") do
      Ash.Changeset.add_error(changeset,
        field: :target_function_name,
        message: "is required for background execution"
      )
    else
      changeset
    end
  end
end
