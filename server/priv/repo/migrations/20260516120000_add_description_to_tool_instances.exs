defmodule IntellectualClub.Repo.Migrations.AddDescriptionToToolInstances do
  use Ecto.Migration

  def change do
    alter table(:tool_instances) do
      add :description, :text, null: false, default: ""
    end
  end
end
