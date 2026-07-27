defmodule IntellectualClub.Chat.QueuedMessage do
  @moduledoc """
  A durable user-authored message waiting for a chat generation boundary.

  Follow-up messages become regular user messages after the preceding generation
  completes. Steering messages remain outside the canonical trace until a
  generation worker consumes them.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor

  postgres do
    table("chat_queued_messages")
    repo(IntellectualClub.Repo)

    references do
      reference(:anchor_message, on_delete: :nilify)
      reference(:target_generation_message, on_delete: :delete)
      reference(:user_message, on_delete: :nilify)
      reference(:assistant_message, on_delete: :nilify)
      reference(:steering_item, on_delete: :nilify)
    end

    check_constraints do
      check_constraint(:kind, "chat_queued_messages_kind_check",
        check: "kind IN ('follow_up', 'steer')"
      )

      check_constraint(:status, "chat_queued_messages_status_check",
        check: "status IN ('pending', 'blocked', 'delivered', 'canceled')"
      )

      check_constraint(
        [:kind, :anchor_message_id, :target_generation_message_id],
        "chat_queued_messages_kind_target_check",
        check:
          "(kind = 'follow_up' AND target_generation_message_id IS NULL) OR " <>
            "(kind = 'steer' AND anchor_message_id IS NULL AND " <>
            "target_generation_message_id IS NOT NULL)"
      )
    end

    custom_indexes do
      index([:chat_id, :kind, :status, :id],
        name: "chat_queued_messages_chat_kind_status_id_index"
      )

      index([:target_generation_message_id, :status, :id],
        name: "chat_queued_messages_target_generation_status_id_index"
      )

      index([:user_message_id],
        name: "chat_queued_messages_unique_user_message_index",
        unique: true,
        where: "user_message_id IS NOT NULL"
      )

      index([:assistant_message_id],
        name: "chat_queued_messages_unique_assistant_message_index",
        unique: true,
        where: "assistant_message_id IS NOT NULL"
      )

      index([:steering_item_id],
        name: "chat_queued_messages_unique_steering_item_index",
        unique: true,
        where: "steering_item_id IS NOT NULL"
      )
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:follow_up, :steer])
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:pending)
      constraints(one_of: [:pending, :blocked, :delivered, :canceled])
    end

    attribute :blocked_reason, :string do
      allow_nil?(true)
      public?(true)
      constraints(trim?: false, allow_empty?: true)
    end

    attribute :attempt_count, :integer do
      allow_nil?(false)
      default(0)
      constraints(min: 0)
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

    belongs_to :anchor_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true

    belongs_to :target_generation_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true

    belongs_to :user_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true

    belongs_to :assistant_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true

    belongs_to :steering_item, IntellectualClub.Chat.ChatMessageItem,
      allow_nil?: true,
      attribute_type: :integer,
      public?: true

    has_many :contents, IntellectualClub.Chat.QueuedMessageContent do
      destination_attribute(:queued_message_id)
    end
  end

  actions do
    defaults([:read])

    create :enqueue do
      accept([:chat_id, :kind, :anchor_message_id, :target_generation_message_id])
      change(relate_actor(:owner))
      change({RequireRelatedAccessByActor, relationships: [:chat], access: :writable})

      change(
        {RequireRelatedAccessByActor,
         relationships: [:anchor_message, :target_generation_message],
         access: :readable,
         required?: false}
      )
    end

    update :update_state do
      public?(false)

      accept([
        :chat_id,
        :kind,
        :status,
        :blocked_reason,
        :attempt_count,
        :finished_at,
        :anchor_message_id,
        :target_generation_message_id,
        :user_message_id,
        :assistant_message_id,
        :steering_item_id
      ])

      require_atomic?(false)
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      change(cascade_destroy(:contents, after_action?: false))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
