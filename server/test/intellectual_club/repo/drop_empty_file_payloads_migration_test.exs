defmodule IntellectualClub.Repo.DropEmptyFilePayloadsMigrationTest do
  use IntellectualClub.DataCase, async: false

  @migration_file Path.expand(
                    "../../../priv/repo/migrations/20260628120000_drop_empty_file_payloads.exs",
                    __DIR__
                  )

  Code.require_file(@migration_file)

  alias IntellectualClub.Db
  alias IntellectualClub.Repo.Migrations.DropEmptyFilePayloads

  test "drop_file_payloads_if_empty! is a no-op when the table is missing" do
    repo = Db.repo()
    drop_file_payloads_table!(repo)

    assert :ok = DropEmptyFilePayloads.drop_file_payloads_if_empty!(repo)
    refute table_exists?(repo, "file_payloads")
  end

  test "drop_file_payloads_if_empty! drops an empty file_payloads table" do
    repo = Db.repo()
    recreate_file_payloads_table!(repo)

    assert table_exists?(repo, "file_payloads")
    assert :ok = DropEmptyFilePayloads.drop_file_payloads_if_empty!(repo)
    refute table_exists?(repo, "file_payloads")
  end

  test "drop_file_payloads_if_empty! rejects non-empty file_payloads table" do
    repo = Db.repo()
    recreate_file_payloads_table!(repo)
    insert_file_payload!(repo, sha256_hex("legacy-payload"), "legacy-payload")

    error =
      assert_raise RuntimeError, fn ->
        DropEmptyFilePayloads.drop_file_payloads_if_empty!(repo)
      end

    assert Exception.message(error) =~ "Cannot drop file_payloads"
    assert table_exists?(repo, "file_payloads")
    assert file_payload_count(repo) == 1
  end

  test "drop_file_payloads_if_empty! rejects legacy db backend file rows" do
    repo = Db.repo()
    recreate_file_payloads_table!(repo)
    insert_db_backend_file!(repo)

    error =
      assert_raise RuntimeError, fn ->
        DropEmptyFilePayloads.drop_file_payloads_if_empty!(repo)
      end

    assert Exception.message(error) =~ "storage_backend = 'db'"
    assert table_exists?(repo, "file_payloads")
  end

  defp recreate_file_payloads_table!(repo) do
    drop_file_payloads_table!(repo)

    Ecto.Adapters.SQL.query!(
      repo,
      """
      CREATE TABLE "file_payloads"
        ("payload" bytea NOT NULL, "sha256" text NOT NULL PRIMARY KEY)
      """,
      []
    )
  end

  defp drop_file_payloads_table!(repo) do
    Ecto.Adapters.SQL.query!(repo, ~s(DROP TABLE IF EXISTS "file_payloads"), [])
  end

  defp insert_file_payload!(repo, sha256, payload) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO "file_payloads" ("sha256", "payload")
      VALUES ($1, $2)
      """,
      [sha256, payload]
    )
  end

  defp insert_db_backend_file!(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      INSERT INTO "files"
        ("created_at", "external_id", "storage_backend", "mime_type", "size_bytes", "filename", "sha256")
      VALUES
        ($1, $2::uuid, 'db', 'text/plain', 0, 'legacy.txt', $3)
      """,
      [
        DateTime.utc_now() |> DateTime.truncate(:microsecond),
        Ecto.UUID.dump!(Ash.UUID.generate()),
        sha256_hex("legacy-file")
      ]
    )
  end

  defp file_payload_count(repo) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT COUNT(*) FROM "file_payloads"
        """,
        []
      )

    count
  end

  defp table_exists?(repo, table) do
    Ecto.Adapters.SQL.table_exists?(repo, table)
  end

  defp sha256_hex(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
