defmodule IntellectualClub.Repo.Migrations.DropSupportsFileProcessingFromBots do
  use Ecto.Migration

  def change do
    alter table(:bots) do
      remove :supports_file_processing, :boolean
    end
  end
end
