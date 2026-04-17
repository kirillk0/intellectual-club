defmodule IntellectualClub.Repo.Migrations.AddChatUploadSessions do
  use Ecto.Migration

  def change do
    create table(:chat_upload_sessions, primary_key: false) do
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :status, :text, null: false
      add :chunk_size_bytes, :bigint, null: false
      add :uploaded_bytes, :bigint, null: false
      add :size_bytes, :bigint, null: false
      add :mime_type, :text, null: false
      add :filename, :text, null: false
      add :external_id, :uuid, null: false

      add :chat_id,
          references(:chats,
            column: :id,
            name: "chat_upload_sessions_chat_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_upload_sessions_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:chat_upload_sessions, [:external_id],
             name: "chat_upload_sessions_external_id_index"
           )

    create index(:chat_upload_sessions, [:chat_id], name: "chat_upload_sessions_chat_id_index")
    create index(:chat_upload_sessions, [:owner_id], name: "chat_upload_sessions_owner_id_index")
    create index(:chat_upload_sessions, [:status], name: "chat_upload_sessions_status_index")

    create index(:chat_upload_sessions, [:expires_at],
             name: "chat_upload_sessions_expires_at_index"
           )
  end
end
