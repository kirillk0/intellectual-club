defmodule IntellectualClub.Repo.Migrations.AddEnabledToKnowledgeBlockFiles do
  use Ecto.Migration

  def change do
    alter table(:knowledge_block_files) do
      add :enabled, :boolean, null: false, default: true
    end
  end
end
