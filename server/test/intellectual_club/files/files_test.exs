defmodule IntellectualClub.FilesTest do
  @moduledoc """
  Tests for logical file rows and deduplicated payload storage.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Db
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilePayload

  require Ash.Query

  test "create_from_upload creates distinct file rows for the same payload" do
    upload = image_upload("same.png")

    assert {:ok, file_a} = Files.create_from_upload(upload)
    assert {:ok, file_b} = Files.create_from_upload(upload)

    assert file_a.id != file_b.id
    assert file_a.sha256 == file_b.sha256
    assert file_a.filename == "same.png"
    assert file_b.filename == "same.png"
    assert payload_count(file_a.sha256) == 1
    assert file_count(file_a.sha256) == 2

    assert {:ok, {_stored_file, payload}} = Files.load_payload(file_a.id)
    assert payload == image_payload()
  end

  test "duplicate_file reuses payload and payload is deleted only after the last file row" do
    assert {:ok, file} = Files.create_from_upload(image_upload("source.png"))
    assert {:ok, duplicate} = Files.duplicate_file(file.id)

    assert duplicate.id != file.id
    assert duplicate.sha256 == file.sha256
    assert duplicate.filename == file.filename
    assert payload_count(file.sha256) == 1
    assert file_count(file.sha256) == 2

    assert :ok = Files.delete_file_and_maybe_payload(file.id)
    assert payload_count(duplicate.sha256) == 1
    assert file_count(duplicate.sha256) == 1

    assert :ok = Files.delete_file_and_maybe_payload(duplicate.id)
    assert payload_count(duplicate.sha256) == 0
    assert file_count(duplicate.sha256) == 0
    assert {:error, _error} = Files.load_payload(duplicate.id)
  end

  defp payload_count(sha256) do
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
end
