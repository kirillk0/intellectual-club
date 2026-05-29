defmodule IntellectualClub.Repo.Migrations.AddToolCallItemIdToChatMessageItems do
  use Ecto.Migration

  def change do
    alter table(:chat_message_items) do
      add :tool_call_item_id,
          references(:chat_message_items,
            column: :id,
            name: "chat_message_items_tool_call_item_id_fkey",
            on_delete: :nilify_all,
            type: :bigint
          )
    end

    create index(:chat_message_items, [:tool_call_item_id],
             name: "chat_message_items_tool_call_item_id_index"
           )
  end
end
