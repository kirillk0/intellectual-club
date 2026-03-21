defmodule IntellectualClub.Repo.Migrations.AddFinishedAtToChatRecords do
  @moduledoc """
  Adds explicit completion timestamps for chat messages and steps.
  """

  use Ecto.Migration

  def up do
    alter table(:chat_messages) do
      add :finished_at, :utc_datetime_usec
    end

    alter table(:chat_message_steps) do
      add :finished_at, :utc_datetime_usec
    end

    execute("""
    UPDATE chat_messages
    SET finished_at = created_at
    WHERE finished_at IS NULL
      AND (
        role = 'user'
        OR status IN ('done', 'canceled', 'error')
      )
    """)

    execute("""
    UPDATE chat_message_steps
    SET finished_at = created_at
    WHERE finished_at IS NULL
      AND chat_message_id IN (
        SELECT id
        FROM chat_messages
        WHERE role = 'user'
           OR status IN ('done', 'canceled', 'error')
      )
    """)
  end

  def down do
    alter table(:chat_message_steps) do
      remove :finished_at
    end

    alter table(:chat_messages) do
      remove :finished_at
    end
  end
end
