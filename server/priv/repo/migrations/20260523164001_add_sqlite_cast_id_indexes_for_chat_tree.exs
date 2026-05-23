defmodule IntellectualClub.Repo.Migrations.AddSqliteCastIdIndexesForChatTree do
  @moduledoc """
  Adds SQLite expression indexes matching AshSqlite casted primary key filters.
  """

  use Ecto.Migration

  def up do
    if sqlite?() do
      execute("""
      CREATE INDEX IF NOT EXISTS chat_message_contents_cast_id_index
      ON chat_message_contents (CAST(id AS INTEGER))
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS chat_message_items_cast_id_index
      ON chat_message_items (CAST(id AS INTEGER))
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS chat_message_steps_cast_id_index
      ON chat_message_steps (CAST(id AS INTEGER))
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS chat_messages_cast_id_index
      ON chat_messages (CAST(id AS INTEGER))
      """)
    end
  end

  def down do
    if sqlite?() do
      execute("DROP INDEX IF EXISTS chat_messages_cast_id_index")
      execute("DROP INDEX IF EXISTS chat_message_steps_cast_id_index")
      execute("DROP INDEX IF EXISTS chat_message_items_cast_id_index")
      execute("DROP INDEX IF EXISTS chat_message_contents_cast_id_index")
    end
  end

  defp sqlite? do
    repo().__adapter__() == Ecto.Adapters.SQLite3
  end
end
