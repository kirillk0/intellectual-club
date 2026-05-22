defmodule IntellectualClub.Knowledge.KnowledgeBlock do
  @moduledoc """
  A reusable knowledge block that can be attached to bots and LLM configurations.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Knowledge,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Knowledge.Changes.SetTokenCount
  alias IntellectualClub.Knowledge.Changes.NormalizeKnowledgeBlockFields
  alias IntellectualClub.Knowledge.Changes.NormalizeVersion
  alias IntellectualClub.Knowledge.TagTree
  alias IntellectualClub.Duplication
  alias IntellectualClub.Files
  alias IntellectualClub.Files.Changes.{DeleteAssociatedFile, SetImageFile}

  require Ash.Query

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

  sqlite do
    table("knowledge_blocks")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("knowledge_blocks")
    repo(IntellectualClub.PostgresRepo)
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

    attribute :version, :string do
      allow_nil?(true)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :content, :string do
      allow_nil?(false)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :variables, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :token_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
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

    has_many :tag_bindings, IntellectualClub.Knowledge.KnowledgeBlockTag do
      destination_attribute(:knowledge_block_id)
      public?(true)
    end

    has_many :bot_bindings, IntellectualClub.Bots.BotKnowledgeBlock do
      destination_attribute(:knowledge_block_id)
    end

    has_many :llm_configuration_bindings, IntellectualClub.Llm.LlmConfigurationKnowledgeBlock do
      destination_attribute(:knowledge_block_id)
    end

    has_many :chat_bindings, IntellectualClub.Chat.ChatKnowledgeBlock do
      destination_attribute(:knowledge_block_id)
    end

    many_to_many :tags, IntellectualClub.Knowledge.KnowledgeTag do
      through(IntellectualClub.Knowledge.KnowledgeBlockTag)
      source_attribute_on_join_resource(:knowledge_block_id)
      destination_attribute_on_join_resource(:knowledge_tag_id)
    end
  end

  identities do
    identity(:unique_owner_external_id, [:owner_id, :external_id])
  end

  calculations do
    calculate :image,
              :map,
              {IntellectualClub.Files.Calculations.PublicImage,
               route_prefix: "/api/bff/knowledge-blocks"} do
      public?(true)
    end

    calculate :can_edit, :boolean, expr(owner_id == ^actor(:id)) do
      public?(true)
    end

    calculate :shared_incoming,
              :boolean,
              expr(
                owner_id != ^actor(:id) and
                  (exists(
                     bot_bindings,
                     enabled == true and
                       exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
                   ) or
                     exists(
                       llm_configuration_bindings,
                       enabled == true and
                         exists(
                           llm_configuration.shares.user_group.memberships,
                           user_id == ^actor(:id)
                         )
                     ))
              ) do
      public?(true)
    end

    calculate :shared_outgoing,
              :boolean,
              expr(
                exists(bot_bindings, enabled == true and bot.exists(shares)) or
                  exists(
                    llm_configuration_bindings,
                    enabled == true and llm_configuration.exists(shares)
                  )
              ) do
      public?(true)
    end
  end

  json_api do
    type "knowledge-blocks"
    includes([{:tag_bindings, [:knowledge_tag]}])
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change(cascade_destroy(:tag_bindings, after_action?: false))
      change(cascade_destroy(:bot_bindings, after_action?: false))
      change(cascade_destroy(:llm_configuration_bindings, after_action?: false))
      change(cascade_destroy(:chat_bindings, after_action?: false))
      change({DeleteAssociatedFile, field: :image_file_id})
    end

    read :search do
      argument :q, :string do
        allow_nil?(true)
        public?(true)
      end

      argument :tag_id, :integer do
        allow_nil?(true)
        public?(true)
      end

      argument :no_tags, :boolean do
        allow_nil?(true)
        public?(true)
      end

      prepare fn query, context ->
        query
        |> maybe_filter_by_query()
        |> maybe_filter_by_tag(context)
      end
    end

    create :create do
      accept([:name, :version, :content, :variables])

      argument :tag_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))
      change({NormalizeVersion, []})
      change({NormalizeKnowledgeBlockFields, []})
      change({SetTokenCount, []})
      change(&maybe_manage_tag_bindings/2)
    end

    create :import_markdown do
      accept([:external_id, :name, :version, :content, :variables])

      argument :tag_bindings, {:array, :map} do
        allow_nil?(true)
      end

      change(relate_actor(:owner))
      change({NormalizeVersion, []})
      change({NormalizeKnowledgeBlockFields, []})
      change({SetTokenCount, []})
      change(&maybe_manage_tag_bindings/2)
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

        tag_ids =
          IntellectualClub.Knowledge.KnowledgeBlockTag
          |> Ash.Query.filter(knowledge_block_id == ^source.id)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(actor: actor)
          |> Enum.map(& &1.knowledge_tag_id)

        changeset
        |> Ash.Changeset.put_context(:duplicate_tag_ids, tag_ids)
        |> Ash.Changeset.put_context(:duplicate_image_file_id, source.image_file_id)
        |> Ash.Changeset.change_attributes(%{
          name: source.name,
          version: Duplication.next_copy_label(source.version),
          content: source.content,
          variables: source.variables
        })
        |> Ash.Changeset.after_action(fn changeset, duplicated ->
          actor = changeset.context[:private][:actor]
          tag_ids = List.wrap(changeset.context[:duplicate_tag_ids])

          Enum.reduce_while(tag_ids, {:ok, duplicated}, fn tag_id, {:ok, duplicated} ->
            IntellectualClub.Knowledge.KnowledgeBlockTag
            |> Ash.Changeset.for_create(
              :create,
              %{knowledge_block_id: duplicated.id, knowledge_tag_id: tag_id},
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

      change({NormalizeVersion, []})
      change({NormalizeKnowledgeBlockFields, []})
      change({SetTokenCount, []})
    end

    update :update do
      accept([:name, :version, :content, :variables])
      require_atomic?(false)

      argument :tag_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change({NormalizeVersion, []})
      change({NormalizeKnowledgeBlockFields, []})
      change({SetTokenCount, []})
      change(&maybe_manage_tag_bindings/2)
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

  defp maybe_filter_by_query(query) do
    q =
      case Ash.Query.get_argument(query, :q) do
        q when is_binary(q) -> String.trim(q)
        _ -> ""
      end

    if q == "" do
      query
    else
      Ash.Query.filter(query, contains(name, ^q) or contains(version, ^q))
    end
  end

  defp maybe_filter_by_tag(query, context) do
    if Ash.Query.get_argument(query, :no_tags) == true do
      Ash.Query.filter(query, not exists(tag_bindings, knowledge_tag_id > 0))
    else
      case Ash.Query.get_argument(query, :tag_id) do
        tag_id when is_integer(tag_id) ->
          tag_ids =
            TagTree.subtree_ids(tag_id, actor: context.actor, authorize?: context.authorize?)

          Ash.Query.filter(query, exists(tags, id in ^tag_ids))

        _ ->
          query
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     exists(
                       bot_bindings,
                       enabled == true and
                         exists(bot.shares.user_group.memberships, user_id == ^actor(:id))
                     )
                   )

      authorize_if expr(
                     exists(
                       llm_configuration_bindings,
                       enabled == true and
                         exists(
                           llm_configuration.shares.user_group.memberships,
                           user_id == ^actor(:id)
                         )
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
