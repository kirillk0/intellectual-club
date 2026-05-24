defmodule IntellectualClub.Repo.Migrations.AddPreferredLocaleToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :preferred_locale, :text
    end
  end
end
