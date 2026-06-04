defmodule IntellectualClub.Repo.Migrations.AddHandoffMessageBlockToBots do
  @moduledoc """
  Adds an optional knowledge block reference for custom handoff prompts.
  """

  use Ecto.Migration

  def change do
    alter table(:bots) do
      add :handoff_message_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "bots_handoff_message_block_id_fkey",
            type: :bigint,
            on_delete: :nilify_all
          ),
          null: true
    end

    create index(:bots, [:handoff_message_block_id], name: "bots_handoff_message_block_id_index")
  end
end
