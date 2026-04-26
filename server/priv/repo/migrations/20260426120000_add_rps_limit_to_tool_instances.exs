defmodule IntellectualClub.Repo.Migrations.AddRpsLimitToToolInstances do
  use Ecto.Migration

  def change do
    alter table(:tool_instances) do
      add :rps_limit, :float
    end
  end
end
