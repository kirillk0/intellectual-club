defmodule IntellectualClub.Repo.Migrations.AddSubagentToChats do
  use Ecto.Migration

  def change do
    alter table(:chats) do
      add :subagent, :boolean, null: false, default: false
    end

    create index(:chats, [:owner_id, :subagent, :updated_at, :id],
             name: "chats_owner_subagent_updated_id_index"
           )
  end
end
