defmodule IntellectualClub.Chat.Chat do
  @moduledoc """
  A chat thread.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.Changes.ClearLastMessageReference
  alias IntellectualClub.Chat.Changes.CreateFirstMessages
  alias IntellectualClub.Chat.Changes.DeleteChatSharesOnAccessBoundaryChange
  alias IntellectualClub.Chat.Changes.NormalizeChatFields
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

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

  sqlite do
    table("chats")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chats")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :title, :string do
      allow_nil?(false)
      public?(true)
      default("Untitled chat")
    end

    attribute :note, :string do
      allow_nil?(true)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :variables, :map do
      allow_nil?(true)
      public?(true)
      default(%{})
    end

    attribute :parent_relation_kind, :atom do
      allow_nil?(true)
      public?(true)
      constraints(one_of: [:handoff])
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :bot, IntellectualClub.Bots.Bot,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :last_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :parent_chat, __MODULE__,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :parent_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer

    has_many :child_chats, __MODULE__ do
      destination_attribute(:parent_chat_id)
    end

    has_many :messages, IntellectualClub.Chat.ChatMessage

    has_many :root_messages, IntellectualClub.Chat.ChatMessage do
      destination_attribute(:chat_id)
      filter expr(is_nil(parent_id))
    end

    has_many :knowledge_block_bindings, IntellectualClub.Chat.ChatKnowledgeBlock do
      destination_attribute(:chat_id)
    end

    has_many :tool_bindings, IntellectualClub.Tools.ChatToolBinding do
      destination_attribute(:chat_id)
      public?(true)
    end

    has_many :shares, IntellectualClub.Chat.ChatShare do
      destination_attribute(:chat_id)
    end
  end

  calculations do
    calculate :can_edit, :boolean, expr(owner_id == ^actor(:id)) do
      public?(true)
    end

    calculate :shared_incoming,
              :boolean,
              expr(
                owner_id != ^actor(:id) and not exists(knowledge_block_bindings) and
                  not exists(tool_bindings) and
                  exists(shares.user_group.memberships, user_id == ^actor(:id))
              ) do
      public?(true)
    end

    calculate :shared_outgoing, :boolean, expr(exists(shares)) do
      public?(true)
    end

    calculate :last_activity_at,
              :utc_datetime_usec,
              expr(last_message.created_at || created_at) do
      public?(false)
    end

    calculate :message_count, :integer, {IntellectualClub.Chat.Calculations.MessageCount, []} do
      public?(true)
    end

    calculate :active_root_message_id,
              :integer,
              {IntellectualClub.Chat.Calculations.ActiveRootMessageId, []} do
      public?(false)
    end
  end

  json_api do
    type "chats"
  end

  actions do
    defaults([:read])

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change({ClearLastMessageReference, []})
      change(cascade_destroy(:shares, after_action?: false))
      change(cascade_destroy(:knowledge_block_bindings, after_action?: false))
      change(cascade_destroy(:tool_bindings, after_action?: false))

      change(
        cascade_destroy(:root_messages, action: :destroy_with_children, after_action?: false)
      )
    end

    create :create do
      accept([
        :title,
        :bot_id,
        :llm_configuration_id,
        :note,
        :variables,
        :parent_chat_id,
        :parent_message_id,
        :parent_relation_kind
      ])

      argument :knowledge_block_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :tool_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))
      change({NormalizeChatFields, []})
      change(&maybe_manage_knowledge_block_bindings/2)
      change(&maybe_manage_tool_bindings/2)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:bot, :llm_configuration, :parent_chat, :parent_message],
         access: :readable,
         required?: false}
      )

      change({CreateFirstMessages, []})
    end

    create :create_empty do
      accept([
        :title,
        :bot_id,
        :llm_configuration_id,
        :note,
        :variables,
        :parent_chat_id,
        :parent_message_id,
        :parent_relation_kind
      ])

      argument :knowledge_block_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :tool_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))
      change({NormalizeChatFields, []})
      change(&maybe_manage_knowledge_block_bindings/2)
      change(&maybe_manage_tool_bindings/2)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:bot, :llm_configuration, :parent_chat, :parent_message],
         access: :readable,
         required?: false}
      )
    end

    update :update do
      accept([
        :title,
        :bot_id,
        :llm_configuration_id,
        :note,
        :variables,
        :parent_chat_id,
        :parent_message_id,
        :parent_relation_kind
      ])

      require_atomic?(false)

      argument :knowledge_block_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :tool_bindings, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change({NormalizeChatFields, []})
      change(&maybe_manage_knowledge_block_bindings/2)
      change(&maybe_manage_tool_bindings/2)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:bot, :llm_configuration, :parent_chat, :parent_message],
         access: :readable,
         required?: false}
      )

      change({DeleteChatSharesOnAccessBoundaryChange, []})
    end

    update :set_last_message do
      accept([:last_message_id])
      require_atomic?(false)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:last_message], access: :writable, required?: false}
      )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(
                     not exists(knowledge_block_bindings) and not exists(tool_bindings) and
                       exists(shares.user_group.memberships, user_id == ^actor(:id))
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
