Code.require_file(
  "../../../priv/repo/migrations/20261121072942_enforce_unique_content_files.exs",
  __DIR__
)

defmodule IntellectualClub.FilesTest do
  @moduledoc """
  Tests for logical file rows and deduplicated payload storage.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{ChatMessageContent, ChatMessageStepRequestFile}
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Files.GarbageCollector
  alias IntellectualClub.Repo.Migrations.EnforceUniqueContentFiles

  require Ash.Query

  describe "content file ownership migration" do
    @version 20_261_121_072_942
    @opts [migration_lock: false, log: false]

    setup do
      assert :ok = Ecto.Migrator.down(Repo, @version, EnforceUniqueContentFiles, @opts)
      %{user: actor} = user_fixture()
      %{item: item, step: step} = create_tool_call_anchor!(actor)
      %{actor: actor, step: step, item: item}
    end

    test "retains the original on the oldest content and splits every other owner once", %{
      actor: actor,
      item: item
    } do
      payload = unique_payload("historically shared")
      original = create_file!(filename: "source.txt", payload: payload)
      unrelated = create_file!(filename: "independent.txt", payload: payload)

      [later, oldest, tied, single] =
        for {file, seq} <- Enum.with_index([original, original, original, unrelated], 1) do
          create_content!(actor, item, sequence: seq, kind: :media, file_id: file.id)
        end

      # The oldest two timestamps tie, and neither belongs to the smallest content ID.
      Repo.query!(
        "UPDATE chat_message_contents SET created_at = '2000-01-01' WHERE id = ANY($1)",
        [
          [oldest.id, tied.id]
        ]
      )

      receipt =
        create_content!(actor, item,
          sequence: 5,
          kind: :opaque,
          content_json: %{"file_references" => [original.external_id]}
        )

      text = create_content!(actor, item, sequence: 6, content_text: "No attachment")
      read = fn content -> Ash.get!(ChatMessageContent, content.id, actor: actor) end

      # Older installations require writers to supply this timestamp explicitly.
      Repo.query!("ALTER TABLE files ALTER COLUMN created_at DROP DEFAULT")
      assert :ok = Ecto.Migrator.up(Repo, @version, EnforceUniqueContentFiles, @opts)
      assert read.(oldest).file_id == original.id
      assert read.(single).file_id == unrelated.id
      assert read.(receipt).content_json == receipt.content_json
      assert is_nil(read.(receipt).file_id) and is_nil(read.(text).file_id)

      copies =
        for content <- [later, tied] do
          persisted = read.(content)
          assert persisted.external_id == content.external_id
          assert {:ok, {file, ^payload}} = Files.load_payload(persisted.file_id)
          fields = [:filename, :storage_backend, :sha256, :mime_type, :size_bytes]
          assert Map.take(file, fields) == Map.take(original, fields)
          file
        end

      all_files = [original, unrelated | copies]
      assert length(Enum.uniq_by(all_files, & &1.id)) == 4
      assert length(Enum.uniq_by(all_files, & &1.external_id)) == 4
      assert {:ok, {source, ^payload}} = Files.load_payload_by_external_id(original.external_id)
      assert source.id == read.(oldest).file_id

      for migrate <- [&Ecto.Migrator.down/4, &Ecto.Migrator.up/4] do
        assert :ok = migrate.(Repo, @version, EnforceUniqueContentFiles, @opts)
        assert [read.(later).file_id, read.(tied).file_id] == Enum.map(copies, & &1.id)
        assert file_count(original.sha256) == 4
      end

      Ash.destroy!(read.(oldest), actor: actor)
      assert {:error, :not_found} = Files.get_by_external_id(original.external_id)

      for copy <- copies do
        assert {:ok, {_file, ^payload}} = Files.load_payload_by_external_id(copy.external_id)
      end
    end

    test "refuses to assign a file that is also owned outside message contents", %{
      actor: actor,
      item: item,
      step: step
    } do
      file = create_file!()
      create_content!(actor, item, kind: :media, file_id: file.id)

      create!(
        ChatMessageStepRequestFile,
        %{
          chat_message_step_id: step.id,
          reference_key: Ash.UUID.generate(),
          source_file_external_id: file.external_id,
          variant_key: "original",
          file_id: file.id
        },
        actor
      )

      assert_raise Postgrex.Error,
                   ~r/owned by both chat_message_contents and another table/,
                   fn ->
                     Ecto.Migrator.up(Repo, @version, EnforceUniqueContentFiles, @opts)
                   end
    end
  end

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
    assert payload == png_1x1()
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

  test "logical file creation failure removes a newly stored payload" do
    payload = unique_payload("new-payload-create-error")
    sha256 = sha256_hex(payload)

    assert {:error, _error} =
             Files.create_from_binary("invalid\0filename.txt", "text/plain", payload)

    assert file_count(sha256) == 0
    assert {:ok, :deleted} = GarbageCollector.collect_sha256(sha256)
    refute FilesystemStorage.exists?(sha256)
  end

  test "path-based logical file creation failure removes a newly stored payload" do
    payload = unique_payload("new-path-payload-create-error")
    sha256 = sha256_hex(payload)
    source_path = temp_file_path("create-error.txt")
    File.write!(source_path, payload)
    on_exit(fn -> File.rm(source_path) end)

    assert {:error, _error} =
             Files.create_from_path(
               "invalid\0filename.txt",
               "text/plain",
               source_path
             )

    assert File.read!(source_path) == payload
    assert file_count(sha256) == 0
    assert {:ok, :deleted} = GarbageCollector.collect_sha256(sha256)
    refute FilesystemStorage.exists?(sha256)
  end

  test "logical file creation failure preserves a preexisting payload" do
    payload = unique_payload("existing-payload-create-error")

    assert {:ok, existing_file} =
             Files.create_from_binary("existing.txt", "text/plain", payload)

    assert {:error, _error} =
             Files.create_from_binary("invalid\0filename.txt", "text/plain", payload)

    assert file_count(existing_file.sha256) == 1
    assert FilesystemStorage.exists?(existing_file.sha256)
    assert {:ok, {_file, ^payload}} = Files.load_payload(existing_file.id)

    assert :ok = Files.delete_file_and_maybe_payload(existing_file.id)
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
    assert file_count(duplicate.sha256) == 0
    assert FilesystemStorage.exists?(duplicate.sha256)
    assert {:ok, :deleted} = GarbageCollector.collect_sha256(duplicate.sha256)
    refute FilesystemStorage.exists?(duplicate.sha256)
    assert {:error, _error} = Files.load_payload(duplicate.id)
  end

  test "garbage collector retains referenced payloads and removes orphaned payloads" do
    payload = unique_payload("garbage-collector")
    assert {:ok, file} = Files.create_from_binary("gc.txt", "text/plain", payload)

    assert {:ok, :retained} = GarbageCollector.collect_sha256(file.sha256)
    assert FilesystemStorage.exists?(file.sha256)

    assert :ok = Files.delete_file_and_maybe_payload(file.id)
    assert FilesystemStorage.exists?(file.sha256)

    assert {:ok, :deleted} = GarbageCollector.collect_sha256(file.sha256)
    refute FilesystemStorage.exists?(file.sha256)
  end

  test "garbage collector sweep discovers orphaned filesystem payloads" do
    payload = unique_payload("garbage-collector-sweep")
    sha256 = sha256_hex(payload)

    assert {:ok, :created} = FilesystemStorage.store(sha256, payload)
    assert sha256 in elem(FilesystemStorage.list_payload_sha256s(), 1)

    assert {:ok, stats} = GarbageCollector.collect()
    assert stats.scanned >= 1
    assert stats.deleted >= 1
    refute FilesystemStorage.exists?(sha256)
  end

  test "deleting a payload prunes its empty directory and keeps sibling payload directories" do
    payload = unique_payload("sibling-a")
    sha256 = sha256_hex(payload)

    # A second payload in the same first-level directory but a different
    # second-level directory, so pruning must stop at the shared parent.
    {sibling, sibling_sha256} =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn index ->
        candidate = unique_payload("sibling-b-#{index}")
        {candidate, sha256_hex(candidate)}
      end)
      |> Enum.find(fn {_payload, candidate} ->
        binary_part(candidate, 0, 2) == binary_part(sha256, 0, 2) and
          binary_part(candidate, 2, 2) != binary_part(sha256, 2, 2)
      end)

    assert {:ok, :created} = FilesystemStorage.store(sha256, payload)
    assert {:ok, :created} = FilesystemStorage.store(sibling_sha256, sibling)
    on_exit(fn -> FilesystemStorage.delete(sibling_sha256) end)

    {:ok, path} = FilesystemStorage.path_for(sha256)
    assert :ok = FilesystemStorage.delete(sha256)

    refute FilesystemStorage.exists?(sha256)
    refute File.exists?(Path.dirname(path))
    assert File.dir?(Path.dirname(Path.dirname(path)))
    assert {:ok, ^sibling} = FilesystemStorage.fetch(sibling_sha256)
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
      payload: png_1x1()
    }
  end

  defp temp_file_path(filename) do
    safe_filename = String.replace(filename, ~r/[^a-zA-Z0-9_.-]/, "_")

    Path.join(
      System.tmp_dir!(),
      "ic-files-test-#{System.unique_integer([:positive])}-#{safe_filename}"
    )
  end

  defp unique_payload(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp sha256_hex(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
