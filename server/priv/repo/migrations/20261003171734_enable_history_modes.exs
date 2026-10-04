defmodule IntellectualClub.Repo.Migrations.EnableHistoryModes do
  @moduledoc """
  Preserves existing agent behavior while enabling explicit history modes.
  """

  use Ecto.Migration

  def up do
    # The old setting was ignored: every existing bot used agent history.
    execute("UPDATE bots SET history_mode = 'agent' WHERE history_mode = 'chat'")

    alter table(:bots) do
      modify :history_mode, :text, default: "agent"
    end
  end

  def down do
    execute("UPDATE bots SET history_mode = 'agent' WHERE history_mode = 'full'")

    alter table(:bots) do
      modify :history_mode, :text, default: "chat"
    end
  end
end
