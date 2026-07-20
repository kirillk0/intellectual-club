defmodule IntellectualClub.Repo.Migrations.AddDirectKnowledgeBlockAndToolShares do
  use Ecto.Migration

  def change do
    create table(:knowledge_block_shares, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true

      add :knowledge_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "knowledge_block_shares_knowledge_block_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :user_group_id,
          references(:user_groups,
            column: :id,
            name: "knowledge_block_shares_user_group_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:knowledge_block_shares, [:knowledge_block_id],
             name: "knowledge_block_shares_knowledge_block_id_index"
           )

    create index(:knowledge_block_shares, [:user_group_id],
             name: "knowledge_block_shares_user_group_id_index"
           )

    create unique_index(:knowledge_block_shares, [:knowledge_block_id, :user_group_id],
             name: "knowledge_block_shares_unique_pair_index"
           )

    create table(:tool_instance_shares, primary_key: false) do
      add :id, :bigserial, null: false, primary_key: true

      add :tool_instance_id,
          references(:tool_instances,
            column: :id,
            name: "tool_instance_shares_tool_instance_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :user_group_id,
          references(:user_groups,
            column: :id,
            name: "tool_instance_shares_user_group_id_fkey",
            type: :bigint,
            on_delete: :delete_all
          ),
          null: false

      add :created_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:tool_instance_shares, [:tool_instance_id],
             name: "tool_instance_shares_tool_instance_id_index"
           )

    create index(:tool_instance_shares, [:user_group_id],
             name: "tool_instance_shares_user_group_id_index"
           )

    create unique_index(:tool_instance_shares, [:tool_instance_id, :user_group_id],
             name: "tool_instance_shares_unique_pair_index"
           )
  end
end
