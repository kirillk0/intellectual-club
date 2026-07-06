defmodule IntellectualClub.Repo.Migrations.AddParentToolCallItemToChats do
  use Ecto.Migration

  def change do
    alter table(:chats) do
      add :parent_tool_call_item_id,
          references(:chat_message_items, on_delete: :nilify_all),
          null: true
    end

    create index(:chats, [:parent_tool_call_item_id],
             name: "chats_parent_tool_call_item_id_index"
           )

    create unique_index(:chats, [:parent_tool_call_item_id],
             name: "chats_unique_parent_tool_call_item_id_index",
             where: "parent_tool_call_item_id IS NOT NULL"
           )
  end
end
