defmodule IntellectualClub.Repo.Migrations.DropTypeFromKnowledgeBlocks do
  use Ecto.Migration

  def change do
    alter table(:knowledge_blocks) do
      remove :type, :text
    end
  end
end
