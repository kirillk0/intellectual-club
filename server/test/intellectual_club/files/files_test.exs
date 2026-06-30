defmodule IntellectualClub.FilesTest do
  @moduledoc """
  Tests for logical file rows and deduplicated payload storage.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
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
    assert FilesystemStorage.exists?(file_a.sha256)
    assert file_count(file_a.sha256) == 2

    assert {:ok, {_stored_file, payload}} = Files.load_payload(file_a.id)
    assert payload == image_payload()
  end

  test "create_from_path creates a file row without loading the source payload" do
    payload = "path payload"
    source_path = temp_file_path("source.txt")
    File.write!(source_path, payload)

    assert {:ok, file} = Files.create_from_path("source.txt", "text/plain", source_path)
    assert file.filename == "source.txt"
    assert file.mime_type == "text/plain"
    assert file.size_bytes == byte_size(payload)
    assert file.sha256 == sha256_hex(payload)
    assert file.storage_backend == :fs

    assert {:ok, {loaded_file, storage_path}} = Files.load_path(file.id)
    assert loaded_file.id == file.id
    assert File.read!(storage_path) == payload
  end

  test "create_from_path deduplicates with existing filesystem payloads" do
    payload = "same payload"
    source_path = temp_file_path("same.txt")
    File.write!(source_path, payload)

    assert {:ok, file_a} =
             Files.create_from_upload(%{
               filename: "first.txt",
               mime_type: "text/plain",
               payload: payload
             })

    assert {:ok, file_b} = Files.create_from_path("second.txt", "text/plain", source_path)

    assert file_a.id != file_b.id
    assert file_a.sha256 == file_b.sha256
    assert file_count(file_a.sha256) == 2
    assert FilesystemStorage.exists?(file_a.sha256)
  end

  test "create_from_path returns source errors for missing files" do
    missing_path = temp_file_path("missing.txt")

    assert {:error, :enoent} = Files.create_from_path("missing.txt", "text/plain", missing_path)
  end

  test "duplicate_file reuses filesystem payload and payload is deleted only after the last file row" do
    assert {:ok, file} = Files.create_from_upload(image_upload("source.png"))
    assert {:ok, duplicate} = Files.duplicate_file(file.id)

    assert duplicate.id != file.id
    assert duplicate.sha256 == file.sha256
    assert duplicate.filename == file.filename
    assert duplicate.storage_backend == :fs
    assert FilesystemStorage.exists?(file.sha256)
    assert file_count(file.sha256) == 2

    assert :ok = Files.delete_file_and_maybe_payload(file.id)
    assert FilesystemStorage.exists?(duplicate.sha256)
    assert file_count(duplicate.sha256) == 1

    assert :ok = Files.delete_file_and_maybe_payload(duplicate.id)
    refute FilesystemStorage.exists?(duplicate.sha256)
    assert file_count(duplicate.sha256) == 0
    assert {:error, _error} = Files.load_payload(duplicate.id)
  end

  test "db storage backend is rejected" do
    attrs = %{
      sha256: sha256_hex("legacy"),
      filename: "legacy.txt",
      size_bytes: 6,
      mime_type: "text/plain",
      storage_backend: :db
    }

    assert {:error, _error} =
             StoredFile
             |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
             |> Ash.create(authorize?: false)

    assert {:ok, file} = Files.create_from_upload(image_upload("source.png"))

    assert {:error, _error} =
             file
             |> Ash.Changeset.for_update(:update_storage_backend, %{storage_backend: :db},
               authorize?: false
             )
             |> Ash.update(authorize?: false)

    assert Ash.get!(StoredFile, file.id, authorize?: false).storage_backend == :fs
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

  defp temp_file_path(filename) do
    safe_filename = String.replace(filename, ~r/[^a-zA-Z0-9_.-]/, "_")

    Path.join(
      System.tmp_dir!(),
      "ic-files-test-#{System.unique_integer([:positive])}-#{safe_filename}"
    )
  end

  defp sha256_hex(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
