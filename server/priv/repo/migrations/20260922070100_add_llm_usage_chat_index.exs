defmodule IntellectualClub.Repo.Migrations.AddLlmUsageChatIndex do
  @moduledoc """
  Indexes the authoritative ledger for authorized subchat cost aggregates.
  """

  use Ecto.Migration

  def up do
    # Performance-audit instances may already have this exact operational index.
    create_if_not_exists index(:llm_usage_records, [:chat_id],
                           name: "llm_usage_records_chat_id_index"
                         )
  end

  def down do
    drop_if_exists index(:llm_usage_records, [:chat_id], name: "llm_usage_records_chat_id_index")
  end
end
