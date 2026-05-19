defmodule IntellectualClub.Repo.Migrations.AddChatShares do
  use Ecto.Migration

  def change do
    create table(:chat_shares, primary_key: false) do
      add :chat_id,
          references(:chats,
            column: :id,
            name: "chat_shares_chat_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :user_group_id,
          references(:user_groups,
            column: :id,
            name: "chat_shares_user_group_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :bot_id,
          references(:bots,
            column: :id,
            name: "chat_shares_bot_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :llm_configuration_id,
          references(:llm_configurations,
            column: :id,
            name: "chat_shares_llm_configuration_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:chat_shares, [:chat_id, :user_group_id],
             name: "chat_shares_unique_pair_index"
           )

    create index(:chat_shares, [:chat_id], name: "chat_shares_chat_id_index")
    create index(:chat_shares, [:user_group_id], name: "chat_shares_user_group_id_index")
    create index(:chat_shares, [:bot_id, :user_group_id], name: "chat_shares_bot_group_index")

    create index(:chat_shares, [:llm_configuration_id, :user_group_id],
             name: "chat_shares_llm_configuration_group_index"
           )
  end
end
