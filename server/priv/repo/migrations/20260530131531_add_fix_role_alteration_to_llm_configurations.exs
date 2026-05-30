defmodule IntellectualClub.Repo.Migrations.AddFixRoleAlterationToLlmConfigurations do
  use Ecto.Migration

  def change do
    alter table(:llm_configurations) do
      add :fix_role_alteration, :boolean, null: false, default: false
    end
  end
end
