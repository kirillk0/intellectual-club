defmodule IntellectualClub.Repo.Migrations.AddBackgroundFunctionMetadata do
  use Ecto.Migration

  def change do
    alter table(:tool_functions) do
      add :execution_mode, :text, null: false, default: "direct"
      add :target_function_name, :text
    end
  end
end
