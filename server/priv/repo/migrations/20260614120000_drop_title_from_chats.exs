defmodule IntellectualClub.Repo.Migrations.DropTitleFromChats do
  use Ecto.Migration

  def up do
    alter table(:chats) do
      remove :title, :text
    end
  end

  def down do
    alter table(:chats) do
      add :title, :text, null: false, default: "Untitled chat"
    end
  end
end
