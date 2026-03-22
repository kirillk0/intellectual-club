defmodule IntellectualClub.Repo.Migrations.AddChatToolBindings do
  @moduledoc """
  Adds chat-level tool bindings for one-off tool usage without creating bots.
  """

  use Ecto.Migration

  def up do
    create table(:chat_tool_bindings, primary_key: false) do
      add :tool_instance_id,
          references(:tool_instances,
            column: :id,
            name: "chat_tool_bindings_tool_instance_id_fkey",
            type: :bigint
          ),
          null: false

      add :chat_id,
          references(:chats, column: :id, name: "chat_tool_bindings_chat_id_fkey", type: :bigint),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false
      add :enabled, :boolean, null: false
      add :alias, :text, null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_tool_bindings_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:chat_tool_bindings, [:chat_id, :alias],
             name: "chat_tool_bindings_unique_chat_alias_index"
           )

    create index(:chat_tool_bindings, [:owner_id], name: "chat_tool_bindings_owner_id_index")

    create index(:chat_tool_bindings, [:chat_id, :enabled],
             name: "chat_tool_bindings_chat_enabled_index"
           )
  end

  def down do
    drop_if_exists index(:chat_tool_bindings, [:chat_id, :enabled],
                     name: "chat_tool_bindings_chat_enabled_index"
                   )

    drop_if_exists index(:chat_tool_bindings, [:owner_id],
                     name: "chat_tool_bindings_owner_id_index"
                   )

    drop_if_exists unique_index(:chat_tool_bindings, [:chat_id, :alias],
                     name: "chat_tool_bindings_unique_chat_alias_index"
                   )

    drop table(:chat_tool_bindings)
  end
end
