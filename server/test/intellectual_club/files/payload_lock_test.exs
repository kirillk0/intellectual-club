defmodule IntellectualClub.Files.PayloadLockTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Files.GarbageCollector
  alias IntellectualClub.Files.PayloadLock
  alias IntellectualClub.Repo

  require Ash.Query

  test "transaction advisory lock serializes callers for the same SHA" do
    sha256 = String.duplicate("ab", 32)
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            :ok = PayloadLock.acquire(sha256)
            send(parent, {:payload_lock_acquired, self()})

            receive do
              :release_payload_lock -> :ok
            end
          end)
        end)
      end)

    assert_receive {:payload_lock_acquired, holder_pid}, 1_000

    waiter =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(parent, {:payload_lock_waiting, self()})

          Repo.transaction(fn ->
            :ok = PayloadLock.acquire(sha256)
            send(parent, {:payload_lock_acquired, self()})
            :ok
          end)
        end)
      end)

    assert_receive {:payload_lock_waiting, waiter_pid}, 1_000
    refute_receive {:payload_lock_acquired, ^waiter_pid}, 100

    send(holder_pid, :release_payload_lock)

    assert_receive {:payload_lock_acquired, ^waiter_pid}, 1_000
    assert {:ok, :ok} = Task.await(holder)
    assert {:ok, :ok} = Task.await(waiter)
  end

  test "lock requires a transaction and validates SHA" do
    assert {:error, :transaction_required} =
             Sandbox.unboxed_run(Repo, fn ->
               PayloadLock.acquire(String.duplicate("cd", 32))
             end)

    assert {:error, :invalid_sha256} = PayloadLock.lock_key("invalid")
  end

  test "concurrent deletion of the last logical files leaves one collectible payload" do
    payload = unique_payload("concurrent-delete")

    {first_file, second_file} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, first_file} =
          Files.create_from_binary("first.bin", "application/octet-stream", payload)

        {:ok, second_file} = Files.duplicate_file(first_file.id)
        {first_file, second_file}
      end)

    results =
      [first_file.id, second_file.id]
      |> Enum.map(fn file_id ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Files.delete_file_and_maybe_payload(file_id)
          end)
        end)
      end)
      |> Task.await_many()

    assert results == [:ok, :ok]

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, false} =
               StoredFile
               |> Ash.Query.filter(sha256 == ^first_file.sha256)
               |> Ash.exists(authorize?: false)

      assert FilesystemStorage.exists?(first_file.sha256)
      assert {:ok, :deleted} = GarbageCollector.collect_sha256(first_file.sha256)
      refute FilesystemStorage.exists?(first_file.sha256)
    end)
  end

  test "concurrent creation and collection preserve the committed payload" do
    payload = unique_payload("concurrent-create-collect")
    sha256 = sha256_hex(payload)
    parent = self()

    assert {:ok, _status} = FilesystemStorage.store(sha256, payload)

    creator =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :start -> :ok
        end

        Sandbox.unboxed_run(Repo, fn ->
          Files.create_from_binary("created.bin", "application/octet-stream", payload)
        end)
      end)

    collector =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :start -> :ok
        end

        Sandbox.unboxed_run(Repo, fn ->
          GarbageCollector.collect_sha256(sha256)
        end)
      end)

    assert_receive {:ready, creator_pid}, 1_000
    assert_receive {:ready, collector_pid}, 1_000
    send(creator_pid, :start)
    send(collector_pid, :start)

    assert {:ok, file} = Task.await(creator)
    assert {:ok, status} = Task.await(collector)
    assert status in [:deleted, :retained]

    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, {_file, ^payload}} = Files.load_payload(file.id)
      assert :ok = Files.delete_file_and_maybe_payload(file.id)
      assert {:ok, :deleted} = GarbageCollector.collect_sha256(sha256)
    end)
  end

  defp unique_payload(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp sha256_hex(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
