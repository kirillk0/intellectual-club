defmodule IntellectualClub.Chat.ChatMessage do
  @moduledoc """
  A message inside a chat.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.MessageContentFts
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Chat.Changes.SetFinishedAtFromStatus
  alias IntellectualClub.Chat.Changes.SetChatLastMessage
  alias IntellectualClub.Chat.Changes.SetDefaultParentFromChatLastMessage
  alias IntellectualClub.Chat.Changes.ValidateParentMessage
  alias IntellectualClub.Chat.Validations.PreventDestroyWithChildren
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor
  alias IntellectualClub.TokenCounter

  defp prepare_user_message_contents(changeset, _context) do
    contents =
      changeset
      |> Ash.Changeset.get_argument(:contents)
      |> List.wrap()
      |> Threads.normalize_content_specs()

    if contents == [] do
      Ash.Changeset.add_error(changeset, field: :contents, message: "must not be empty")
    else
      changeset
      |> Ash.Changeset.change_attribute(
        :token_count,
        TokenCounter.estimate(Threads.text_from_contents(contents))
      )
      |> Ash.Changeset.put_context(:normalized_contents, contents)
    end
  end

  defp maybe_set_active_leaf_parent(changeset, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      use_active_leaf_parent? =
        Ash.Changeset.get_argument(changeset, :use_active_leaf_parent) != false

      parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)
      chat_id = Ash.Changeset.get_attribute(changeset, :chat_id)
      actor = changeset.context[:private][:actor]

      cond do
        not use_active_leaf_parent? ->
          changeset

        not is_nil(parent_id) ->
          changeset

        not is_integer(chat_id) ->
          changeset

        true ->
          chat = Ash.get!(IntellectualClub.Chat.Chat, chat_id, actor: actor)
          Ash.Changeset.force_change_attribute(changeset, :parent_id, chat.last_message_id)
      end
    end)
  end

  defp persist_user_message_contents(changeset, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, message ->
      actor = changeset.context[:private][:actor]
      contents = List.wrap(changeset.context[:normalized_contents])

      case Threads.persist_message_trace!(message, :user, contents, actor) do
        {:ok, _item} -> {:ok, message}
        {:error, error} -> {:error, error}
      end
    end)
  end

  sqlite do
    table("chat_messages")
    repo(IntellectualClub.Repo)
  end

  postgres do
    table("chat_messages")
    repo(IntellectualClub.PostgresRepo)
  end

  attributes do
    integer_primary_key(:id)

    attribute :role, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:user, :assistant])
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:done)
      constraints(one_of: [:generating, :done, :canceled, :error])
    end

    attribute :error_detail, :string do
      allow_nil?(true)
      public?(true)
    end

    attribute :token_count, :integer do
      allow_nil?(false)
      public?(true)
      default(0)
    end

    attribute :finished_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :chat, IntellectualClub.Chat.Chat,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :parent, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :llm_configuration, IntellectualClub.Llm.LlmConfiguration,
      allow_nil?: true,
      attribute_type: :integer

    has_many :steps, IntellectualClub.Chat.ChatMessageStep do
      destination_attribute(:chat_message_id)
    end

    has_many :children, __MODULE__ do
      destination_attribute(:parent_id)
    end
  end

  json_api do
    type "chat-messages"
  end

  actions do
    defaults([:read])

    read :fts_search do
      argument :fts_match, :string do
        allow_nil?(false)
      end

      modify_query({MessageContentFts, :modify_message_query, []})
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      validate(PreventDestroyWithChildren)
      change(cascade_destroy(:steps, after_action?: false))
    end

    destroy :destroy_with_children do
      require_atomic?(false)
      change(cascade_destroy(:children, action: :destroy_with_children, after_action?: false))
      change(cascade_destroy(:steps, after_action?: false))
    end

    create :add_message do
      accept([
        :chat_id,
        :role,
        :parent_id,
        :llm_configuration_id,
        :status,
        :error_detail,
        :token_count
      ])

      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent, :llm_configuration], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
      change({SetFinishedAtFromStatus, []})
      change({SetChatLastMessage, []})
    end

    create :add_user_message do
      accept([:chat_id, :parent_id, :token_count])
      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})
      change({SetDefaultParentFromChatLastMessage, []})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
      change(set_attribute(:role, :user))
      change(set_attribute(:status, :done))
      change({SetFinishedAtFromStatus, []})
      change({SetChatLastMessage, []})
    end

    create :add_user_message_with_contents do
      accept([:chat_id, :parent_id])

      argument :contents, {:array, :map} do
        allow_nil?(true)
        public?(true)
      end

      argument :use_active_leaf_parent, :boolean do
        allow_nil?(false)
        public?(true)
        default(true)
      end

      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})
      change(&prepare_user_message_contents/2)
      change(&maybe_set_active_leaf_parent/2)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
      change(set_attribute(:role, :user))
      change(set_attribute(:status, :done))
      change({SetFinishedAtFromStatus, []})
      change({SetChatLastMessage, []})
      change(&persist_user_message_contents/2)
    end

    create :create_generating_assistant do
      accept([:chat_id, :parent_id, :llm_configuration_id, :token_count])
      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent, :llm_configuration], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
      change(set_attribute(:role, :assistant))
      change(set_attribute(:status, :generating))
      change({SetFinishedAtFromStatus, []})
      change({SetChatLastMessage, []})
    end

    update :reparent do
      accept([:parent_id])
      require_atomic?(false)

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
    end

    update :move_to_chat do
      accept([:chat_id, :parent_id])
      require_atomic?(false)

      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:parent], access: :readable, required?: false}
      )

      change({ValidateParentMessage, []})
    end

    update :update_token_count do
      accept([:token_count])
      require_atomic?(false)
    end

    update :set_generation_state do
      accept([:status, :error_detail, :token_count, :finished_at])
      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)

      authorize_if expr(chat.shared_incoming == true)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:update) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
