defmodule IntellectualClub.Repo.Migrations.DropEmptyFilePayloads do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  @file_payloads_table "file_payloads"

  def up do
    drop_file_payloads_if_empty!(repo())
  end

  def down do
    create table(:file_payloads, primary_key: false) do
      add :payload, :binary, null: false
      add :sha256, :text, null: false, primary_key: true
    end
  end

  def drop_file_payloads_if_empty!(repo) do
    if table_exists?(repo, @file_payloads_table) do
      validate_can_drop!(repo)
      Ecto.Adapters.SQL.query!(repo, ~s(DROP TABLE "#{@file_payloads_table}"), [])
    end

    :ok
  end

  def validate_can_drop!(repo) do
    if table_exists?(repo, @file_payloads_table) do
      validate_file_payloads_empty!(repo)
      validate_no_db_backend_files!(repo)
    end

    :ok
  end

  defp validate_file_payloads_empty!(repo) do
    case table_row_count(repo, @file_payloads_table) do
      0 ->
        :ok

      count ->
        raise """
        Cannot drop file_payloads because it still contains #{count} row(s).

        Migrate all legacy DB file payloads to filesystem storage before running this migration.
        """
    end
  end

  defp validate_no_db_backend_files!(repo) do
    count =
      repo.one(
        from(file in "files",
          where: field(file, :storage_backend) == "db",
          select: count("*")
        )
      ) || 0

    if count > 0 do
      raise """
      Cannot drop file_payloads because #{count} file row(s) still reference storage_backend = 'db'.

      Migrate all legacy DB file records to filesystem storage before running this migration.
      """
    end

    :ok
  end

  defp table_row_count(repo, table) do
    repo.one(from(row in table, select: count("*"))) || 0
  end

  defp table_exists?(repo, table) do
    Ecto.Adapters.SQL.table_exists?(repo, table)
  end
end
