defmodule IntellectualClub.BackgroundTasks.BackgroundTask do
  @moduledoc """
  Durable state for a tool or agent operation that continues after its launch call returns.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.BackgroundTasks,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("background_tasks")
    repo(IntellectualClub.Repo)

    references do
      reference(:lifecycle_message, on_delete: :nilify)
    end

    custom_indexes do
      index([:owner_id, :status, :inserted_at],
        name: "background_tasks_owner_status_inserted_index"
      )

      index([:source_chat_id, :status], name: "background_tasks_source_chat_status_index")
      index([:target_chat_id], name: "background_tasks_target_chat_id_index")

      index([:lifecycle_message_id, :id],
        name: "background_tasks_active_lifecycle_message_index",
        where: "status IN ('queued', 'running')"
      )

      index([:status, :inserted_at],
        name: "background_tasks_active_status_inserted_index",
        where: "status IN ('queued', 'running')"
      )

      index([:tool_instance_id, :adapter, :status, :inserted_at],
        name: "background_tasks_active_tool_adapter_index",
        where: "status IN ('queued', 'running')"
      )

      index([:source_tool_call_item_id],
        name: "background_tasks_unique_source_tool_call_item_id_index",
        unique: true,
        where: "source_tool_call_item_id IS NOT NULL"
      )
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :kind, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :adapter, :string do
      allow_nil?(false)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      default(:queued)
      constraints(one_of: [:queued, :running, :completed, :failed, :canceled])
    end

    attribute :function_name, :string do
      allow_nil?(false)
    end

    attribute :arguments, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute :execution_context, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute :runner_ref, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :result, :map do
      allow_nil?(true)
      public?(true)
    end

    attribute :error, :map do
      allow_nil?(true)
      public?(true)
    end

    attribute :cancel_requested, :boolean do
      allow_nil?(false)
      public?(true)
      default(false)
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    attribute :finished_at, :utc_datetime_usec do
      allow_nil?(true)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :owner, IntellectualClub.Accounts.User,
      allow_nil?: false,
      attribute_type: :integer

    belongs_to :tool_instance, IntellectualClub.Tools.ToolInstance,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :source_chat, IntellectualClub.Chat.Chat,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :source_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :lifecycle_message, IntellectualClub.Chat.ChatMessage,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :source_step, IntellectualClub.Chat.ChatMessageStep,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :source_tool_call_item, IntellectualClub.Chat.ChatMessageItem,
      allow_nil?: true,
      attribute_type: :integer

    belongs_to :target_chat, IntellectualClub.Chat.Chat,
      allow_nil?: true,
      attribute_type: :integer

    has_many :events, IntellectualClub.BackgroundTasks.BackgroundTaskEvent do
      destination_attribute(:background_task_id)
    end
  end

  actions do
    defaults([:read])

    create :create do
      public?(false)

      accept([
        :kind,
        :adapter,
        :status,
        :function_name,
        :arguments,
        :execution_context,
        :runner_ref,
        :tool_instance_id,
        :source_chat_id,
        :source_message_id,
        :lifecycle_message_id,
        :source_step_id,
        :source_tool_call_item_id,
        :target_chat_id,
        :started_at,
        :finished_at
      ])

      change(relate_actor(:owner))
    end

    update :update_state do
      public?(false)

      accept([
        :status,
        :runner_ref,
        :result,
        :error,
        :cancel_requested,
        :started_at,
        :finished_at,
        :target_chat_id,
        :lifecycle_message_id
      ])

      require_atomic?(false)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:owner)
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:update) do
      authorize_if relates_to_actor_via(:owner)
    end
  end
end
