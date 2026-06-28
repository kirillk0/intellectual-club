defmodule IntellectualClub.Bots.Bot do
  @moduledoc """
  A bot configuration (system prompt, attached knowledge blocks, etc).
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Bots,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Bots.BotCompatibleConfigurationTag
  alias IntellectualClub.Bots.Changes.DeleteBotDependents
  alias IntellectualClub.Duplication
  alias IntellectualClub.Files
  alias IntellectualClub.Files.Changes.{DeleteAssociatedFile, SetImageFile}
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor
  alias IntellectualClub.Tools.{BotToolBinding, BotUserToolBinding}

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

  defp maybe_manage_compatible_configuration_tag_bindings(changeset, _context) do
    case Ash.Changeset.fetch_argument(changeset, :compatible_configuration_tag_bindings) do
      {:ok, nil} ->
        changeset

      {:ok, bindings} ->
        Ash.Changeset.manage_relationship(
          changeset,
          :compatible_configuration_tag_bindings,
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

  defp maybe_manage_tool_bindings(changeset, _context) do
    case Ash.Changeset.fetch_argument(changeset, :tool_bindings) do
      {:ok, nil} ->
        changeset

      {:ok, bindings} ->
        Ash.Changeset.manage_relationship(
          changeset,
          :tool_bindings,
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

  defp maybe_attach_duplicated_image(duplicated, nil, _actor), do: {:ok, duplicated}

  defp maybe_attach_duplicated_image(duplicated, image_file_id, actor)
       when is_integer(image_file_id) do
    with {:ok, duplicated_file} <- Files.duplicate_file(image_file_id),
         {:ok, updated} <-
           duplicated
           |> Ash.Changeset.for_update(
             :attach_image_file,
             %{image_file_id: duplicated_file.id},
             actor: actor
           )
           |> Ash.update(actor: actor) do
      {:ok, updated}
    end
  end

  defp maybe_attach_duplicated_image(duplicated, _image_file_id, _actor), do: {:ok, duplicated}

  postgres do
    table("bots")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:image_file_id], name: "bots_image_file_id_index")
      index([:default_llm_configuration_id], name: "bots_default_llm_configuration_id_index")
      index([:handoff_message_block_id], name: "bots_handoff_message_block_id_index")
    end

    custom_statements do
      statement :bots_name_trgm_index do
        up(
          "CREATE INDEX IF NOT EXISTS bots_name_trgm_index ON bots USING gin (name gin_trgm_ops)"
        )

        down("DROP INDEX IF EXISTS bots_name_trgm_index")
      end
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
    end

    attribute :first_messages, {:array, :string} do
      allow_nil?(false)
      public?(true)
      default([])
    end

    attribute :max_tool_rounds, :integer do
      allow_nil?(false)
      public?(true)
      default(300)
    end

    attribute :context_soft_limit_percent, :integer do
      allow_nil?(false)
      public?(true)
      default(80)
      constraints(min: 1, max: 100)
    end

    attribute :max_file_size_bytes, :integer do
      allow_nil?(false)
      public?(true)
      default(500 * 1024 * 1024)
      constraints(min: 1)
    end

    attribute :history_mode, :atom do
      allow_nil?(false)
      public?(true)
      default(:chat)
      constraints(one_of: [:chat, :agent])
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :image_file, IntellectualClub.Files.File,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :default_llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true

    belongs_to :handoff_message_block, KnowledgeBlock,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true

    has_many :knowledge_block_bindings, IntellectualClub.Bots.BotKnowledgeBlock do
      destination_attribute(:bot_id)
      public?(true)
    end

    has_many :tool_bindings, IntellectualClub.Tools.BotToolBinding do
      destination_attribute(:bot_id)
      public?(true)
    end

    has_many :user_tool_bindings, IntellectualClub.Tools.BotUserToolBinding do
      destination_attribute(:bot_id)
      public?(true)
    end

    has_many :shares, IntellectualClub.Bots.BotShare do
      destination_attribute(:bot_id)
    end

    has_many :compatible_configuration_tag_bindings,
             IntellectualClub.Bots.BotCompatibleConfigurationTag do
      destination_attribute(:bot_id)
      public?(true)
    end

    many_to_many :shared_groups, IntellectualClub.Accounts.UserGroup do
      through(IntellectualClub.Bots.BotShare)
      source_attribute_on_join_resource(:bot_id)
      destination_attribute_on_join_resource(:user_group_id)
    end

    many_to_many :compatible_configuration_tags, IntellectualClub.Llm.LlmConfigurationTag do
      through(IntellectualClub.Bots.BotCompatibleConfigurationTag)
      source_attribute_on_join_resource(:bot_id)
      destination_attribute_on_join_resource(:llm_configuration_tag_id)
    end
  end

  calculations do
    calculate :sort_activity_at,
              :utc_datetime_usec,
              {IntellectualClub.Bots.Calculations.SortActivityAt, []} do
      public?(true)
    end

    calculate :blocks_count,
              :integer,
              {IntellectualClub.Bots.Calculations.BlocksCount, []} do
      public?(true)
    end

    calculate :tools_count,
              :integer,
              {IntellectualClub.Bots.Calculations.ToolsCount, []} do
      public?(true)
    end

    calculate :image,
              :map,
              {IntellectualClub.Files.Calculations.PublicImage, route_prefix: "/api/bff/bots"} do
      public?(true)
    end

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
    type "bots"

    includes([
      {:knowledge_block_bindings, [:knowledge_block]},
      {:compatible_configuration_tag_bindings, [:llm_configuration_tag]},
      :default_llm_configuration,
      :handoff_message_block,
      {:tool_bindings, [:tool_instance]},
      {:user_tool_bindings, [:tool_instance]}
    ])
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({DeleteBotDependents, []})
      change(cascade_destroy(:compatible_configuration_tag_bindings, after_action?: false))
      change({DeleteAssociatedFile, field: :image_file_id})
    end

    create :create do
      accept([
        :name,
        :first_messages,
        :max_tool_rounds,
        :context_soft_limit_percent,
        :max_file_size_bytes,
        :history_mode,
        :default_llm_configuration_id,
        :handoff_message_block_id
      ])

      argument :knowledge_block_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :compatible_configuration_tag_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :tool_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))

      change(
        {RequireRelatedAccessByActor,
         relationships: [:default_llm_configuration], access: :readable, required?: false}
      )

      change(
        {RequireRelatedAccessByActor,
         relationships: [:handoff_message_block], access: :readable, required?: false}
      )

      change(&maybe_manage_knowledge_block_bindings/2)
      change(&maybe_manage_compatible_configuration_tag_bindings/2)
      change(&maybe_manage_tool_bindings/2)
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
          BotKnowledgeBlock
          |> Ash.Query.filter(bot_id == ^source.id)
          |> Ash.Query.sort(sequence: :asc, id: :asc)
          |> Ash.read!(actor: actor)

        binding_specs =
          Enum.map(bindings, fn b ->
            %{
              knowledge_block_id: b.knowledge_block_id,
              enabled: b.enabled,
              sequence: b.sequence
            }
          end)

        tool_bindings =
          BotToolBinding
          |> Ash.Query.filter(bot_id == ^source.id)
          |> Ash.Query.sort(sequence: :asc, id: :asc)
          |> Ash.read!(actor: actor)

        tool_binding_specs =
          Enum.map(tool_bindings, fn b ->
            %{
              tool_instance_id: b.tool_instance_id,
              sharing_mode: b.sharing_mode,
              enabled: b.enabled,
              sequence: b.sequence
            }
          end)

        user_tool_bindings =
          BotUserToolBinding
          |> Ash.Query.filter(bot_id == ^source.id)
          |> Ash.Query.sort(sequence: :asc, id: :asc)
          |> Ash.read!(actor: actor)

        user_tool_binding_specs =
          Enum.map(user_tool_bindings, fn b ->
            %{
              tool_instance_id: b.tool_instance_id,
              enabled: b.enabled,
              sequence: b.sequence
            }
          end)

        compatible_tag_binding_specs =
          BotCompatibleConfigurationTag
          |> Ash.Query.filter(bot_id == ^source.id)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(actor: actor)
          |> Enum.map(fn b ->
            %{llm_configuration_tag_id: b.llm_configuration_tag_id}
          end)

        changeset
        |> Ash.Changeset.change_attributes(%{
          name: Duplication.next_copy_label(source.name),
          first_messages: source.first_messages,
          max_tool_rounds: source.max_tool_rounds,
          context_soft_limit_percent: source.context_soft_limit_percent,
          max_file_size_bytes: source.max_file_size_bytes,
          history_mode: source.history_mode,
          default_llm_configuration_id: source.default_llm_configuration_id,
          handoff_message_block_id: source.handoff_message_block_id
        })
        |> Ash.Changeset.manage_relationship(
          :compatible_configuration_tag_bindings,
          compatible_tag_binding_specs,
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
        |> Ash.Changeset.put_context(:duplicate_tool_binding_specs, tool_binding_specs)
        |> Ash.Changeset.put_context(:duplicate_user_tool_binding_specs, user_tool_binding_specs)
        |> Ash.Changeset.put_context(:duplicate_image_file_id, source.image_file_id)
        |> Ash.Changeset.after_action(fn changeset, duplicated ->
          actor = changeset.context[:private][:actor]
          tool_binding_specs = List.wrap(changeset.context[:duplicate_tool_binding_specs])

          user_tool_binding_specs =
            List.wrap(changeset.context[:duplicate_user_tool_binding_specs])

          Enum.reduce_while(tool_binding_specs, {:ok, duplicated}, fn spec, {:ok, duplicated} ->
            BotToolBinding
            |> Ash.Changeset.for_create(
              :create,
              %{
                bot_id: duplicated.id,
                tool_instance_id: spec.tool_instance_id,
                sharing_mode: spec.sharing_mode,
                enabled: spec.enabled,
                sequence: spec.sequence
              },
              actor: actor
            )
            |> Ash.create(actor: actor)
            |> case do
              {:ok, _binding} -> {:cont, {:ok, duplicated}}
              {:error, error} -> {:halt, {:error, error}}
            end
          end)
          |> case do
            {:ok, duplicated} ->
              Enum.reduce_while(user_tool_binding_specs, {:ok, duplicated}, fn spec,
                                                                               {:ok, duplicated} ->
                BotUserToolBinding
                |> Ash.Changeset.for_create(
                  :create,
                  %{
                    bot_id: duplicated.id,
                    tool_instance_id: spec.tool_instance_id,
                    enabled: spec.enabled,
                    sequence: spec.sequence
                  },
                  actor: actor
                )
                |> Ash.create(actor: actor)
                |> case do
                  {:ok, _binding} -> {:cont, {:ok, duplicated}}
                  {:error, error} -> {:halt, {:error, error}}
                end
              end)

            {:error, error} ->
              {:error, error}
          end
          |> case do
            {:ok, duplicated} ->
              maybe_attach_duplicated_image(
                duplicated,
                changeset.context[:duplicate_image_file_id],
                actor
              )

            {:error, error} ->
              {:error, error}
          end
        end)
      end
    end

    update :update do
      accept([
        :name,
        :first_messages,
        :max_tool_rounds,
        :context_soft_limit_percent,
        :max_file_size_bytes,
        :history_mode,
        :default_llm_configuration_id,
        :handoff_message_block_id
      ])

      require_atomic?(false)

      argument :knowledge_block_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :compatible_configuration_tag_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :tool_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(&maybe_manage_knowledge_block_bindings/2)
      change(&maybe_manage_compatible_configuration_tag_bindings/2)
      change(&maybe_manage_tool_bindings/2)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:default_llm_configuration], access: :readable, required?: false}
      )

      change(
        {RequireRelatedAccessByActor,
         relationships: [:handoff_message_block], access: :readable, required?: false}
      )
    end

    update :set_image do
      require_atomic?(false)

      argument :filename, :string do
        allow_nil?(false)
      end

      argument :mime_type, :string do
        allow_nil?(false)
      end

      argument :payload, :binary do
        allow_nil?(false)
      end

      change({SetImageFile, field: :image_file_id})
    end

    update :clear_image do
      require_atomic?(false)
      change({IntellectualClub.Files.Changes.ClearImageFile, field: :image_file_id})
    end

    update :attach_image_file do
      accept([:image_file_id])
      require_atomic?(false)
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
