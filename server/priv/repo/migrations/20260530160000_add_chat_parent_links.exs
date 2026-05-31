defmodule IntellectualClub.Repo.Migrations.AddChatParentLinks do
  use Ecto.Migration

  def change do
    alter table(:chats) do
      add :parent_chat_id,
          references(:chats,
            column: :id,
            name: "chats_parent_chat_id_fkey",
            type: :bigint,
            on_delete: :nilify_all
          )

      add :parent_message_id,
          references(:chat_messages,
            column: :id,
            name: "chats_parent_message_id_fkey",
            type: :bigint,
            on_delete: :nilify_all
          )

      add :parent_relation_kind, :text
    end

    create index(:chats, [:parent_chat_id], name: "chats_parent_chat_id_index")
    create index(:chats, [:parent_message_id], name: "chats_parent_message_id_index")

    create index(:chats, [:parent_relation_kind], name: "chats_parent_relation_kind_index")
  end
end
