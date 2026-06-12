defmodule IntellectualClub.Repo.Migrations.AddWebPushNotifications do
  use Ecto.Migration

  def change do
    create table(:web_push_settings, primary_key: false) do
      add :singleton_key, :text, null: false, default: "default"
      add :enabled, :boolean, null: false, default: false
      add :public_origin, :text
      add :vapid_subject, :text
      add :vapid_public_key, :text, null: false
      add :vapid_private_key, :text, null: false
      add :key_revision, :bigint, null: false, default: 1
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:web_push_settings, [:singleton_key],
             name: "web_push_settings_singleton_key_index"
           )

    create table(:web_push_subscriptions, primary_key: false) do
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :user_agent, :text
      add :key_revision, :bigint, null: false
      add :expiration_time, :bigint
      add :last_seen_at, :utc_datetime_usec, null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "web_push_subscriptions_owner_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:web_push_subscriptions, [:endpoint],
             name: "web_push_subscriptions_endpoint_index"
           )

    create index(:web_push_subscriptions, [:owner_id],
             name: "web_push_subscriptions_owner_id_index"
           )

    create table(:web_push_generation_events, primary_key: false) do
      add :status, :text, null: false
      add :suppressed, :boolean, null: false, default: false
      add :delivered_count, :bigint, null: false, default: 0

      add :chat_message_id,
          references(:chat_messages,
            column: :id,
            name: "web_push_generation_events_chat_message_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "web_push_generation_events_owner_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:web_push_generation_events, [:chat_message_id, :status],
             name: "web_push_generation_events_message_status_index"
           )

    create index(:web_push_generation_events, [:owner_id],
             name: "web_push_generation_events_owner_id_index"
           )
  end
end
