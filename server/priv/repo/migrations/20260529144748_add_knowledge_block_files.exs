defmodule IntellectualClub.Repo.Migrations.AddKnowledgeBlockFiles do
  use Ecto.Migration

  def change do
    create table(:knowledge_block_files, primary_key: false) do
      add :knowledge_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "knowledge_block_files_knowledge_block_id_fkey",
            type: :bigint
          ),
          null: false

      add :file_id,
          references(:files,
            column: :id,
            name: "knowledge_block_files_file_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "knowledge_block_files_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :external_id, :uuid, null: false
      add :sequence, :bigint, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create index(:knowledge_block_files, [:knowledge_block_id],
             name: "knowledge_block_files_knowledge_block_id_index"
           )

    create index(:knowledge_block_files, [:file_id], name: "knowledge_block_files_file_id_index")

    create unique_index(:knowledge_block_files, [:external_id],
             name: "knowledge_block_files_external_id_index"
           )
  end
end
