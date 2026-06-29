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
  alias IntellectualClub.Chat.Branching
  alias IntellectualClub.Chat.ChatSettingsCopy
  alias IntellectualClub.Chat.Continuation
  alias IntellectualClub.Chat.DefaultLlmConfiguration
  alias IntellectualClub.Chat.Threads
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

  defp maybe_apply_default_llm_configuration(changeset, _context) do
    DefaultLlmConfiguration.maybe_put_default_on_create(changeset)
  end

  defp maybe_adjust_llm_configuration_for_bot_change(changeset, _context) do
    DefaultLlmConfiguration.maybe_adjust_for_bot_change(changeset)
  end

  defp prepare_copy(changeset, _context) do
    actor = changeset.context[:private][:actor]
    source_id = Ash.Changeset.get_argument(changeset, :id)

    case Ash.get(__MODULE__, source_id, actor: actor) do
      {:ok, source} ->
        changeset
        |> Ash.Changeset.change_attributes(%{
          note: "",
          bot_id: source.bot_id,
          llm_configuration_id: source.llm_configuration_id
        })
        |> Ash.Changeset.put_context(:source_chat_id, source.id)

      {:error, error} ->
        add_action_error(changeset, :id, error)
    end
  end

  defp copy_settings_after_create(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, chat ->
      actor = changeset.context[:private][:actor]
      ChatSettingsCopy.copy_bindings!(changeset.context[:source_chat_id], chat.id, actor)
      {:ok, Ash.get!(__MODULE__, chat.id, actor: actor)}
    end)
  end

  defp prepare_continuation(changeset, _context) do
    actor = changeset.context[:private][:actor]
    source_id = Ash.Changeset.get_argument(changeset, :id)

    case Ash.get(__MODULE__, source_id, actor: actor) do
      {:ok, source} ->
        changeset
        |> Ash.Changeset.change_attributes(Continuation.target_attrs(source))
        |> Ash.Changeset.put_context(:source_chat_id, source.id)

      {:error, error} ->
        add_action_error(changeset, :id, error)
    end
  end

  defp copy_continuation_after_create(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, chat ->
      actor = changeset.context[:private][:actor]
      source = Ash.get!(__MODULE__, changeset.context[:source_chat_id], actor: actor)
      {:ok, Continuation.copy_active_branch_to_target!(source, chat, actor)}
    end)
  end

  defp prepare_branch(changeset, _context) do
    actor = changeset.context[:private][:actor]
    source_id = Ash.Changeset.get_argument(changeset, :id)
    message_id = Ash.Changeset.get_argument(changeset, :message_id)

    replacement_contents =
      changeset
      |> Ash.Changeset.get_argument(:replacement_contents)
      |> List.wrap()
      |> Threads.normalize_content_specs()

    with {:ok, selection} <- Branching.active_branch_selection(source_id, message_id, actor),
         :ok <- Branching.validate_replacement_contents(selection, replacement_contents) do
      changeset
      |> Ash.Changeset.change_attributes(Continuation.branch_target_attrs(selection.source))
      |> Ash.Changeset.put_context(:source_chat_id, selection.source.id)
      |> Ash.Changeset.put_context(:replacement_contents, replacement_contents)
    else
      {:error, :message_not_in_active_branch} ->
        Ash.Changeset.add_error(changeset,
          field: :message_id,
          message: "must be in the active branch"
        )

      {:error, :empty_user_message} ->
        Ash.Changeset.add_error(changeset,
          field: :replacement_contents,
          message: "must not be empty for user message branches"
        )

      {:error, error} ->
        add_action_error(changeset, :id, error)
    end
  end

  defp add_action_error(changeset, field, %Ash.Error.Forbidden{}) do
    Ash.Changeset.add_error(changeset, field: field, message: "is not accessible")
  end

  defp add_action_error(changeset, field, %Ash.Error.Invalid{errors: errors}) do
    message =
      if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
        "was not found"
      else
        Exception.message(%Ash.Error.Invalid{errors: errors})
      end

    Ash.Changeset.add_error(changeset, field: field, message: message)
  end

  defp add_action_error(changeset, field, error) do
    Ash.Changeset.add_error(changeset, field: field, message: Exception.message(error))
  end

  defp copy_branch_after_create(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, chat ->
      actor = changeset.context[:private][:actor]
      source = Ash.get!(__MODULE__, changeset.context[:source_chat_id], actor: actor)
      message_id = Ash.Changeset.get_argument(changeset, :message_id)

      Continuation.copy_branch_to_target(source, chat, message_id, actor,
        replacement_contents: List.wrap(changeset.context[:replacement_contents])
      )
    end)
  end

  defp activate_branch(changeset, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      actor = changeset.context[:private][:actor]
      message_id = Ash.Changeset.get_argument(changeset, :message_id)

      case message_id do
        value when is_integer(value) ->
          case Threads.activate_branch(changeset.data.id, value, actor) do
            {:ok, _meta} ->
              chat = Ash.get!(__MODULE__, changeset.data.id, actor: actor)

              Ash.Changeset.force_change_attribute(
                changeset,
                :last_message_id,
                chat.last_message_id
              )

            {:error, reason} ->
              Ash.Changeset.add_error(changeset,
                message: "Failed to activate branch: #{inspect(reason)}"
              )
          end

        _other ->
          Ash.Changeset.add_error(changeset, field: :message_id, message: "is required")
      end
    end)
  end

  defp switch_branch(changeset, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      actor = changeset.context[:private][:actor]
      message_id = Ash.Changeset.get_argument(changeset, :message_id)

      opts =
        []
        |> maybe_put_switch_direction(Ash.Changeset.get_argument(changeset, :direction))
        |> maybe_put_switch_target(Ash.Changeset.get_argument(changeset, :target_id))
        |> Keyword.put(:actor, actor)

      case message_id do
        value when is_integer(value) ->
          case Threads.switch_branch(changeset.data.id, value, opts) do
            {:ok, _meta} ->
              chat = Ash.get!(__MODULE__, changeset.data.id, actor: actor)

              Ash.Changeset.force_change_attribute(
                changeset,
                :last_message_id,
                chat.last_message_id
              )

            {:error, reason} ->
              Ash.Changeset.add_error(changeset,
                message: "Failed to switch branch: #{inspect(reason)}"
              )
          end

        _other ->
          Ash.Changeset.add_error(changeset, field: :message_id, message: "is required")
      end
    end)
  end

  defp maybe_put_switch_direction(opts, direction) when direction in [:prev, "prev"],
    do: Keyword.put(opts, :direction, :prev)

  defp maybe_put_switch_direction(opts, direction) when direction in [:next, "next"],
    do: Keyword.put(opts, :direction, :next)

  defp maybe_put_switch_direction(opts, _direction), do: opts

  defp maybe_put_switch_target(opts, target_id) when is_integer(target_id),
    do: Keyword.put(opts, :target_id, target_id)

  defp maybe_put_switch_target(opts, _target_id), do: opts

  postgres do
    table("chats")
    repo(IntellectualClub.Repo)

    custom_indexes do
      index([:owner_id, :updated_at, :id], name: "chats_owner_updated_id_index")
      index([:parent_chat_id], name: "chats_parent_chat_id_index")
      index([:parent_message_id], name: "chats_parent_message_id_index")
      index([:parent_relation_kind], name: "chats_parent_relation_kind_index")
    end

    custom_statements do
      statement :chats_note_trgm_index do
        up(
          "CREATE INDEX IF NOT EXISTS chats_note_trgm_index ON chats USING gin (note gin_trgm_ops) WHERE note <> ''"
        )

        down("DROP INDEX IF EXISTS chats_note_trgm_index")
      end
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :note, :string do
      allow_nil?(true)
      public?(true)
      default("")
      constraints(trim?: false, allow_empty?: true)
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

  aggregates do
    count :message_count, :messages do
      public?(true)
    end

    count :blocks_count, :knowledge_block_bindings do
      public?(true)
    end

    count :tools_count, :tool_bindings do
      public?(true)
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
              expr(
                last_message.finished_at || last_message.updated_at || last_message.created_at ||
                  created_at
              ) do
      public?(false)
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
        :bot_id,
        :llm_configuration_id,
        :note,
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
      change(&maybe_apply_default_llm_configuration/2)
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
        :bot_id,
        :llm_configuration_id,
        :note,
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

    create :copy do
      argument :id, :integer do
        allow_nil?(false)
        public?(true)
      end

      change(relate_actor(:owner))
      change(&prepare_copy/2)
      change({NormalizeChatFields, []})
      change(&copy_settings_after_create/2)
      change({CreateFirstMessages, []})
    end

    create :continue do
      argument :id, :integer do
        allow_nil?(false)
        public?(true)
      end

      change(relate_actor(:owner))
      change(&prepare_continuation/2)
      change({NormalizeChatFields, []})
      change(&copy_continuation_after_create/2)
    end

    create :create_branch do
      argument :id, :integer do
        allow_nil?(false)
        public?(true)
      end

      argument :message_id, :integer do
        allow_nil?(false)
        public?(true)
      end

      argument :replacement_contents, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      change(relate_actor(:owner))
      change(&prepare_branch/2)
      change({NormalizeChatFields, []})
      change(&copy_branch_after_create/2)
    end

    update :update do
      accept([
        :bot_id,
        :llm_configuration_id,
        :note,
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
      change(&maybe_adjust_llm_configuration_for_bot_change/2)
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

    update :activate_branch do
      require_atomic?(false)

      argument :message_id, :integer do
        allow_nil?(false)
        public?(true)
      end

      change(&activate_branch/2)
    end

    update :switch_branch do
      require_atomic?(false)

      argument :message_id, :integer do
        allow_nil?(false)
        public?(true)
      end

      argument :direction, :atom do
        allow_nil?(true)
        public?(true)
        constraints(one_of: [:prev, :next])
      end

      argument :target_id, :integer do
        allow_nil?(true)
        public?(true)
      end

      change(&switch_branch/2)
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
