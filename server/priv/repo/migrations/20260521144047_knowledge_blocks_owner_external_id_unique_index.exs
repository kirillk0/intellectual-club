defmodule IntellectualClub.Repo.Migrations.KnowledgeBlocksOwnerExternalIdUniqueIndex do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:knowledge_blocks, [:external_id],
                     name: "knowledge_blocks_unique_external_id_index"
                   )

    create unique_index(:knowledge_blocks, [:owner_id, :external_id],
             name: "knowledge_blocks_unique_owner_external_id_index"
           )
  end

  def down do
    drop_if_exists unique_index(:knowledge_blocks, [:owner_id, :external_id],
                     name: "knowledge_blocks_unique_owner_external_id_index"
                   )

    create unique_index(:knowledge_blocks, [:external_id],
             name: "knowledge_blocks_unique_external_id_index"
           )
  end
end
