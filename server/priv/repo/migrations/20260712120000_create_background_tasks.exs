defmodule IntellectualClub.Repo.Migrations.CreateBackgroundTasks do
  use Ecto.Migration

  def change do
    create table(:background_tasks, primary_key: false) do
      add :id, :uuid,
        primary_key: true,
        null: false,
        default: fragment("gen_random_uuid()")

      add :kind, :text, null: false
      add :adapter, :text, null: false
      add :status, :text, null: false, default: "queued"
      add :function_name, :text, null: false
      add :arguments, :map, null: false, default: %{}
      add :execution_context, :map, null: false, default: %{}
      add :runner_ref, :map, null: false, default: %{}
      add :result, :map
      add :error, :map
      add :cancel_requested, :boolean, null: false, default: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      add :owner_id, references(:users, on_delete: :delete_all), null: false

      add :tool_instance_id,
          references(:tool_instances, on_delete: :nilify_all),
          null: true

      add :source_chat_id, references(:chats, on_delete: :nilify_all), null: true

      add :source_message_id,
          references(:chat_messages, on_delete: :nilify_all),
          null: true

      add :source_step_id,
          references(:chat_message_steps, on_delete: :nilify_all),
          null: true

      add :source_tool_call_item_id,
          references(:chat_message_items, on_delete: :nilify_all),
          null: true

      add :target_chat_id, references(:chats, on_delete: :nilify_all), null: true

      timestamps(
        type: :utc_datetime_usec,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create constraint(:background_tasks, :background_tasks_status_check,
             check: "status IN ('queued', 'running', 'completed', 'failed', 'canceled')"
           )

    create index(:background_tasks, [:owner_id, :status, :inserted_at],
             name: "background_tasks_owner_status_inserted_index"
           )

    create index(:background_tasks, [:source_chat_id, :status],
             name: "background_tasks_source_chat_status_index"
           )

    create index(:background_tasks, [:target_chat_id],
             name: "background_tasks_target_chat_id_index"
           )

    create unique_index(:background_tasks, [:source_tool_call_item_id],
             name: "background_tasks_unique_source_tool_call_item_id_index",
             where: "source_tool_call_item_id IS NOT NULL"
           )

    create table(:background_task_events) do
      add :background_task_id,
          references(:background_tasks, type: :uuid, on_delete: :delete_all),
          null: false

      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :stream, :text, null: false
      add :data, :text, null: false
      add :byte_size, :bigint, null: false, default: 0

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create constraint(:background_task_events, :background_task_events_stream_check,
             check: "stream IN ('stdout', 'stderr')"
           )

    create index(:background_task_events, [:background_task_id, :id],
             name: "background_task_events_task_id_index"
           )
  end
end
