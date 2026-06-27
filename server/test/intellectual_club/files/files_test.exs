defmodule IntellectualClub.FilesTest do
  @moduledoc """
  Tests for logical file rows and deduplicated payload storage.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Db
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilePayload
  alias IntellectualClub.Files.FilesystemStorage

  require Ash.Query

  test "create_from_upload creates distinct file rows for the same filesystem payload" do
    upload = image_upload("same.png")

    assert {:ok, file_a} = Files.create_from_upload(upload)
    assert {:ok, file_b} = Files.create_from_upload(upload)

    assert file_a.id != file_b.id
    assert file_a.sha256 == file_b.sha256
    assert file_a.storage_backend == :fs
    assert file_b.storage_backend == :fs
    assert file_a.filename == "same.png"
    assert file_b.filename == "same.png"
    assert db_payload_count(file_a.sha256) == 0
    assert FilesystemStorage.exists?(file_a.sha256)
    assert file_count(file_a.sha256) == 2

    assert {:ok, {_stored_file, payload}} = Files.load_payload(file_a.id)
    assert payload == image_payload()
  end

  test "duplicate_file reuses filesystem payload and payload is deleted only after the last file row" do
    assert {:ok, file} = Files.create_from_upload(image_upload("source.png"))
    assert {:ok, duplicate} = Files.duplicate_file(file.id)

    assert duplicate.id != file.id
    assert duplicate.sha256 == file.sha256
    assert duplicate.filename == file.filename
    assert duplicate.storage_backend == :fs
    assert db_payload_count(file.sha256) == 0
    assert FilesystemStorage.exists?(file.sha256)
    assert file_count(file.sha256) == 2

    assert :ok = Files.delete_file_and_maybe_payload(file.id)
    assert FilesystemStorage.exists?(duplicate.sha256)
    assert file_count(duplicate.sha256) == 1

    assert :ok = Files.delete_file_and_maybe_payload(duplicate.id)
    refute FilesystemStorage.exists?(duplicate.sha256)
    assert db_payload_count(duplicate.sha256) == 0
    assert file_count(duplicate.sha256) == 0
    assert {:error, _error} = Files.load_payload(duplicate.id)
  end

  test "migrate_db_payloads_to_fs migrates legacy DB payload rows idempotently" do
    payload = "legacy payload #{System.unique_integer([:positive])}"
    file = create_db_file!("legacy-a.txt", payload)
    duplicate = create_db_file!("legacy-b.txt", payload)

    assert file.sha256 == duplicate.sha256
    assert db_payload_count(file.sha256) == 1
    refute FilesystemStorage.exists?(file.sha256)

    assert {:ok, stats} = Files.migrate_db_payloads_to_fs()

    assert stats == %{
             db_files: 2,
             unique_payloads: 1,
             payloads_written: 1,
             files_updated: 2,
             db_payloads_deleted: 1,
             missing_payloads: [],
             errors: []
           }

    migrated = Ash.get!(StoredFile, file.id, authorize?: false)
    migrated_duplicate = Ash.get!(StoredFile, duplicate.id, authorize?: false)

    assert migrated.storage_backend == :fs
    assert migrated_duplicate.storage_backend == :fs
    assert db_payload_count(file.sha256) == 0
    assert FilesystemStorage.exists?(file.sha256)
    assert {:ok, {_file, ^payload}} = Files.load_payload(file.id)

    assert {:ok, retry_stats} = Files.migrate_db_payloads_to_fs()

    assert retry_stats == %{
             db_files: 0,
             unique_payloads: 0,
             payloads_written: 0,
             files_updated: 0,
             db_payloads_deleted: 0,
             missing_payloads: [],
             errors: []
           }
  end

  test "migrate_db_payloads_to_fs reports legacy rows without DB payloads" do
    sha256 = sha256_hex("missing #{System.unique_integer([:positive])}")

    file =
      StoredFile
      |> Ash.Changeset.for_create(
        :create,
        %{
          sha256: sha256,
          filename: "missing.txt",
          size_bytes: 7,
          mime_type: "text/plain",
          storage_backend: :db
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    assert {:ok, stats} = Files.migrate_db_payloads_to_fs()
    assert stats.missing_payloads == [sha256]
    assert stats.files_updated == 0
    assert Ash.get!(StoredFile, file.id, authorize?: false).storage_backend == :db

    assert_raise RuntimeError, fn ->
      Files.migrate_db_payloads_to_fs!()
    end
  end

  defp db_payload_count(sha256) do
    Db.repo().aggregate(
      from(payload in FilePayload, where: payload.sha256 == ^sha256),
      :count,
      :sha256
    )
  end

  defp file_count(sha256) do
    StoredFile
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp image_upload(filename) do
    %{
      filename: filename,
      mime_type: "image/png",
      payload: image_payload()
    }
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp create_db_file!(filename, payload) do
    sha256 = sha256_hex(payload)
    repo = Db.repo()

    %FilePayload{sha256: sha256, payload: payload}
    |> repo.insert!(on_conflict: :nothing, conflict_target: [:sha256])

    StoredFile
    |> Ash.Changeset.for_create(
      :create,
      %{
        sha256: sha256,
        filename: filename,
        size_bytes: byte_size(payload),
        mime_type: "text/plain",
        storage_backend: :db
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp sha256_hex(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
