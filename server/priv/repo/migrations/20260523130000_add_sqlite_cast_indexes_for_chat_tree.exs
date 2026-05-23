defmodule IntellectualClub.Repo.Migrations.AddSqliteCastIndexesForChatTree do
  @moduledoc """
  Adds SQLite expression indexes matching AshSqlite casted relationship filters.
  """

  use Ecto.Migration

  def up do
    if sqlite?() do
      execute("""
      CREATE INDEX IF NOT EXISTS chat_message_steps_cast_message_sequence_index
      ON chat_message_steps (CAST(chat_message_id AS INTEGER), sequence)
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS chat_message_items_cast_step_sequence_index
      ON chat_message_items (CAST(chat_message_step_id AS INTEGER), sequence)
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS chat_message_contents_cast_item_sequence_index
      ON chat_message_contents (CAST(chat_message_item_id AS INTEGER), sequence)
      """)
    end
  end

  def down do
    if sqlite?() do
      execute("DROP INDEX IF EXISTS chat_message_contents_cast_item_sequence_index")
      execute("DROP INDEX IF EXISTS chat_message_items_cast_step_sequence_index")
      execute("DROP INDEX IF EXISTS chat_message_steps_cast_message_sequence_index")
    end
  end

  defp sqlite? do
    repo().__adapter__() == Ecto.Adapters.SQLite3
  end
end
