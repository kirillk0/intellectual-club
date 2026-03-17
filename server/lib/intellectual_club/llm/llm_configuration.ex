defmodule IntellectualClub.Llm.LlmConfiguration do
  @moduledoc """
  A model configuration that can be selected by chats and generation workers.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Llm,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Llm.Changes.DeleteLlmConfigurationDependents
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmConfigurationTagBinding
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  require Ash.Query

  defp maybe_manage_knowledge_block_bindings(changeset, _context) do
    case Ash.Changeset.fetch_argument(changeset, :knowledge_block_bindings) do
      {:ok, nil} ->
        changeset

      {:ok, bindings} ->
        Ash.Changeset.manage_relationship(
          changeset,
          :knowledge_block_bindings,
          bindings,
          type: :direct_control,
          order_is_key: :sequence,
          on_no_match: {:create, :create},
          on_match: {:update, :update},
          on_missing: {:destroy, :destroy}
        )

      :error ->
        changeset
    end
  end

  defp maybe_manage_tag_bindings(changeset, _context) do
    case Ash.Changeset.fetch_argument(changeset, :tag_bindings) do
      {:ok, nil} ->
        changeset

      {:ok, bindings} ->
        Ash.Changeset.manage_relationship(
          changeset,
          :tag_bindings,
          bindings,
          type: :direct_control,
          on_lookup: :ignore,
          on_no_match: {:create, :create},
          on_match: :ignore,
          on_missing: {:destroy, :destroy}
        )

      :error ->
        changeset
    end
  end

  sqlite do
    table("llm_configurations")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("llm_configurations")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :external_id, :uuid do
      allow_nil?(false)
      public?(true)
      default(&Ash.UUID.generate/0)
    end

    attribute :model_name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :note, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :parameters, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :enabled, :boolean do
      allow_nil?(false)
      public?(true)
      default(true)
    end

    attribute :timeout_seconds, :integer do
      allow_nil?(false)
      public?(true)
      default(300)
      constraints(min: 1)
    end

    attribute :context_length, :integer do
      allow_nil?(true)
      public?(true)
      constraints(min: 1)
    end

    attribute :supports_cache_control, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :supports_image_input, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :provider, IntellectualClub.Llm.LlmProvider,
      allow_nil?: false,
      public?: true,
      attribute_type: :integer

    has_many :knowledge_block_bindings, IntellectualClub.Llm.LlmConfigurationKnowledgeBlock do
      destination_attribute(:llm_configuration_id)
      public?(true)
    end

    has_many :shares, IntellectualClub.Llm.LlmConfigurationShare do
      destination_attribute(:llm_configuration_id)
    end

    has_many :tag_bindings, IntellectualClub.Llm.LlmConfigurationTagBinding do
      destination_attribute(:llm_configuration_id)
      public?(true)
    end

    many_to_many :shared_groups, IntellectualClub.Accounts.UserGroup do
      through(IntellectualClub.Llm.LlmConfigurationShare)
      source_attribute_on_join_resource(:llm_configuration_id)
      destination_attribute_on_join_resource(:user_group_id)
    end

    many_to_many :tags, IntellectualClub.Llm.LlmConfigurationTag do
      through(IntellectualClub.Llm.LlmConfigurationTagBinding)
      source_attribute_on_join_resource(:llm_configuration_id)
      destination_attribute_on_join_resource(:llm_configuration_tag_id)
    end
  end

  calculations do
    calculate :can_edit, :boolean, expr(owner_id == ^actor(:id)) do
      public?(true)
    end

    calculate :shared_incoming,
              :boolean,
              expr(
                owner_id != ^actor(:id) and
                  exists(shares.user_group.memberships, user_id == ^actor(:id))
              ) do
      public?(true)
    end

    calculate :shared_outgoing, :boolean, expr(exists(shares)) do
      public?(true)
    end
  end

  identities do
    identity(:unique_external_id, [:external_id])
  end

  json_api do
    type "llm-configurations"

    includes([
      :provider,
      {:knowledge_block_bindings, [:knowledge_block]},
      {:tag_bindings, [:llm_configuration_tag]}
    ])
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change(cascade_destroy(:tag_bindings, after_action?: false))
      change({DeleteLlmConfigurationDependents, []})
    end

    create :create do
      accept([
        :provider_id,
        :model_name,
        :note,
        :parameters,
        :enabled,
        :timeout_seconds,
        :context_length,
        :supports_cache_control,
        :supports_image_input
      ])

      argument :knowledge_block_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :tag_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:provider], access: :writable})
      change(&maybe_manage_tag_bindings/2)
      change(&maybe_manage_knowledge_block_bindings/2)
    end

    create :duplicate do
      argument :id, :integer do
        allow_nil?(false)
      end

      change(relate_actor(:owner))

      change fn changeset, _context ->
        actor = changeset.context[:private][:actor]
        source_id = Ash.Changeset.get_argument(changeset, :id)

        source =
          __MODULE__
          |> Ash.get!(source_id, actor: actor)

        bindings =
          LlmConfigurationKnowledgeBlock
          |> Ash.Query.filter(llm_configuration_id == ^source.id)
          |> Ash.Query.sort(sequence: :asc, id: :asc)
          |> Ash.read!(actor: actor)

        binding_specs =
          Enum.map(bindings, fn b ->
            %{
              knowledge_block_id: b.knowledge_block_id,
              selection: b.selection,
              enabled: b.enabled,
              sequence: b.sequence
            }
          end)

        tag_binding_specs =
          LlmConfigurationTagBinding
          |> Ash.Query.filter(llm_configuration_id == ^source.id)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(actor: actor)
          |> Enum.map(fn b ->
            %{llm_configuration_tag_id: b.llm_configuration_tag_id}
          end)

        changeset
        |> Ash.Changeset.change_attributes(%{
          provider_id: source.provider_id,
          model_name: source.model_name,
          note: source.note,
          parameters: source.parameters,
          enabled: source.enabled,
          timeout_seconds: source.timeout_seconds,
          context_length: source.context_length,
          supports_cache_control: source.supports_cache_control,
          supports_image_input: source.supports_image_input
        })
        |> Ash.Changeset.manage_relationship(
          :tag_bindings,
          tag_binding_specs,
          type: :direct_control,
          on_lookup: :ignore,
          on_no_match: {:create, :create},
          on_match: :ignore,
          on_missing: {:destroy, :destroy}
        )
        |> Ash.Changeset.manage_relationship(
          :knowledge_block_bindings,
          binding_specs,
          type: :direct_control,
          order_is_key: :sequence,
          on_no_match: {:create, :create},
          on_match: {:update, :update},
          on_missing: {:destroy, :destroy}
        )
      end

      change({RequireRelatedAccessByActor, relationships: [:provider], access: :writable})
    end

    update :update do
      accept([
        :provider_id,
        :model_name,
        :note,
        :parameters,
        :enabled,
        :timeout_seconds,
        :context_length,
        :supports_cache_control,
        :supports_image_input
      ])

      require_atomic?(false)
      change({RequireRelatedAccessByActor, relationships: [:provider], access: :writable})

      argument :knowledge_block_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :tag_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(&maybe_manage_tag_bindings/2)
      change(&maybe_manage_knowledge_block_bindings/2)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
      authorize_if expr(exists(shares.user_group.memberships, user_id == ^actor(:id)))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
