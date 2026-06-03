defmodule IntellectualClub.Repo.Migrations.AddPreferredThemeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :preferred_theme, :text, null: false, default: "system"
    end
  end
end
