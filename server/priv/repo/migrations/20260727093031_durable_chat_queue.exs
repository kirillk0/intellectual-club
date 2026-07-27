defmodule IntellectualClub.Repo.Migrations.DurableChatQueue do
  @moduledoc """
  Creates durable follow-up and steering queues for chats.
  """

  use Ecto.Migration

  def up do
    create table(:chat_queued_messages, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :kind, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :blocked_reason, :text
      add :attempt_count, :bigint, null: false, default: 0
      add :finished_at, :utc_datetime_usec

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_queued_messages_owner_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :chat_id,
          references(:chats,
            column: :id,
            name: "chat_queued_messages_chat_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :anchor_message_id,
          references(:chat_messages,
            column: :id,
            name: "chat_queued_messages_anchor_message_id_fkey",
            type: :bigint,
            prefix: "public",
            on_delete: :nilify_all
          )

      add :target_generation_message_id,
          references(:chat_messages,
            column: :id,
            name: "chat_queued_messages_target_generation_message_id_fkey",
            type: :bigint,
            prefix: "public",
            on_delete: :nilify_all
          )

      add :user_message_id,
          references(:chat_messages,
            column: :id,
            name: "chat_queued_messages_user_message_id_fkey",
            type: :bigint,
            prefix: "public",
            on_delete: :nilify_all
          )

      add :assistant_message_id,
          references(:chat_messages,
            column: :id,
            name: "chat_queued_messages_assistant_message_id_fkey",
            type: :bigint,
            prefix: "public",
            on_delete: :nilify_all
          )

      add :steering_item_id,
          references(:chat_message_items,
            column: :id,
            name: "chat_queued_messages_steering_item_id_fkey",
            type: :bigint,
            prefix: "public",
            on_delete: :nilify_all
          )
    end

    create constraint(:chat_queued_messages, :chat_queued_messages_kind_check,
             check: "kind IN ('follow_up', 'steer')"
           )

    create constraint(:chat_queued_messages, :chat_queued_messages_status_check,
             check: "status IN ('pending', 'blocked', 'delivered', 'canceled')"
           )

    create constraint(:chat_queued_messages, :chat_queued_messages_kind_target_check,
             check:
               "(kind = 'follow_up' AND target_generation_message_id IS NULL) OR " <>
                 "(kind = 'steer' AND anchor_message_id IS NULL AND " <>
                 "target_generation_message_id IS NOT NULL)"
           )

    create index(:chat_queued_messages, [:steering_item_id],
             name: "chat_queued_messages_unique_steering_item_index",
             unique: true,
             where: "steering_item_id IS NOT NULL"
           )

    create index(:chat_queued_messages, [:assistant_message_id],
             name: "chat_queued_messages_unique_assistant_message_index",
             unique: true,
             where: "assistant_message_id IS NOT NULL"
           )

    create index(:chat_queued_messages, [:user_message_id],
             name: "chat_queued_messages_unique_user_message_index",
             unique: true,
             where: "user_message_id IS NOT NULL"
           )

    create index(:chat_queued_messages, [:target_generation_message_id, :status, :id],
             name: "chat_queued_messages_target_generation_status_id_index"
           )

    create index(:chat_queued_messages, [:chat_id, :kind, :status, :id],
             name: "chat_queued_messages_chat_kind_status_id_index"
           )

    create table(:chat_queued_message_contents, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true
      add :sequence, :bigint, null: false
      add :kind, :text, null: false
      add :content_text, :text, null: false, default: ""

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_queued_message_contents_owner_id_fkey",
            type: :bigint,
            prefix: "public"
          ),
          null: false

      add :queued_message_id,
          references(:chat_queued_messages,
            column: :id,
            name: "chat_queued_message_contents_queued_message_id_fkey",
            type: :bigint,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :file_id,
          references(:files,
            column: :id,
            name: "chat_queued_message_contents_file_id_fkey",
            type: :bigint,
            prefix: "public"
          )
    end

    create constraint(:chat_queued_message_contents, :chat_queued_message_contents_kind_check,
             check: "kind IN ('text', 'media')"
           )

    create constraint(
             :chat_queued_message_contents,
             :chat_queued_message_contents_kind_file_check,
             check:
               "(kind = 'text' AND file_id IS NULL) OR " <>
                 "(kind = 'media' AND file_id IS NOT NULL)"
           )

    create index(:chat_queued_message_contents, [:file_id],
             name: "chat_queued_message_contents_file_id_index"
           )

    create unique_index(:chat_queued_message_contents, [:queued_message_id, :sequence],
             name: "chat_queued_message_contents_unique_message_sequence_index"
           )
  end

  def down do
    drop table(:chat_queued_message_contents)
    drop table(:chat_queued_messages)
  end
end
