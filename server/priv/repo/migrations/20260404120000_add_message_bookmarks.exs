defmodule IntellectualClub.Repo.Migrations.AddMessageBookmarks do
  use Ecto.Migration

  def change do
    create table(:message_bookmarks, primary_key: false) do
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false

      add :chat_message_id,
          references(:chat_messages,
            column: :id,
            name: "message_bookmarks_chat_message_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "message_bookmarks_owner_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:message_bookmarks, [:owner_id, :chat_message_id],
             name: "message_bookmarks_owner_message_index"
           )

    create index(:message_bookmarks, [:owner_id], name: "message_bookmarks_owner_id_index")

    create index(:message_bookmarks, [:chat_message_id],
             name: "message_bookmarks_chat_message_id_index"
           )
  end
end
