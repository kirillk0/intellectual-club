defmodule IntellectualClub.Generation.RuntimeSnapshotsTest do
  use ExUnit.Case, async: false

  alias IntellectualClub.Generation.RuntimeSnapshots
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  setup do
    if is_nil(Process.whereis(RuntimeSnapshots)), do: start_supervised!(RuntimeSnapshots)
    %{message_id: -System.unique_integer([:positive])}
  end

  test "snapshots exclude raw/context fields and revisions see same-count edits", %{
    message_id: id
  } do
    {:ok, identity} = RuntimeSnapshots.register(id)
    assert {:ok, %{phase: :initializing}} = RuntimeSnapshots.read(id, self())

    snapshot = %{
      status: :generating,
      phase: :streaming,
      raw_request: %{secret: true},
      context: %{huge: true},
      step: step("first")
    }

    assert :ok = RuntimeSnapshots.publish(id, identity, snapshot)
    assert {:ok, first} = RuntimeSnapshots.read(id, self())
    refute Map.has_key?(first, :raw_request)
    refute Map.has_key?(first, :context)
    refute Map.has_key?(first.step, :raw_response)
    assert :ok = RuntimeSnapshots.publish(id, identity, %{snapshot | step: step("other")})
    assert {:ok, second} = RuntimeSnapshots.read(id, self())
    assert first.revision != second.revision
    assert :ok = RuntimeSnapshots.publish(id, identity, %{snapshot | step: step("other")})
    assert {:ok, ^second} = RuntimeSnapshots.read(id, self())
  end

  test "stale identities cannot publish, remove or clean up a replacement", %{message_id: id} do
    {:ok, old_identity} = RuntimeSnapshots.register(id)
    {:ok, replacement} = RuntimeSnapshots.register(id)

    assert :ok =
             RuntimeSnapshots.publish(id, replacement, %{phase: :persisting, step: step("new")})

    assert {:error, :stale_owner} =
             RuntimeSnapshots.publish(id, old_identity, %{step: step("old")})

    assert :ok = RuntimeSnapshots.remove(id, old_identity)
    send(Process.whereis(RuntimeSnapshots), {:DOWN, old_identity, :process, self(), :killed})
    _ = :sys.get_state(RuntimeSnapshots)
    assert {:ok, %{phase: :persisting}} = RuntimeSnapshots.read(id, self())
    assert :ok = RuntimeSnapshots.remove(id, replacement)
    assert :not_found = RuntimeSnapshots.read(id, self())
  end

  test "reads do not wait for a blocked worker and missing snapshots mean busy", %{message_id: id} do
    parent = self()

    worker =
      start_supervised!(
        {Task,
         fn ->
           Registry.register(IntellectualClub.Generation.Registry, {:message, id}, %{})
           send(parent, :registered)

           receive do
             :publish ->
               {:ok, identity} = RuntimeSnapshots.register(id)

               :ok =
                 RuntimeSnapshots.publish(id, identity, %{
                   status: :generating,
                   phase: :persisting,
                   step: step("visible")
                 })

               send(parent, {:published, identity})
           end

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive :registered
    assert {:busy, %{status: :generating}} = GenerationSupervisor.poll_generation(id)
    send(worker, :publish)
    assert_receive {:published, identity}
    assert {:ok, %{phase: :persisting}} = GenerationSupervisor.get_generation_state(id)
    assert {:error, :stale_owner} = RuntimeSnapshots.publish(id, identity, %{step: nil})
    assert :ok = RuntimeSnapshots.remove(id, identity)
    assert {:ok, _snapshot} = RuntimeSnapshots.read(id, worker)
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    _ = :sys.get_state(RuntimeSnapshots)
    assert :not_found = RuntimeSnapshots.read(id, worker)
    refute Map.has_key?(:sys.get_state(RuntimeSnapshots), identity)
  end

  test "remote node failure is unavailable, not proof of a dead generation", %{message_id: id} do
    name = "poll_snapshot_missing@127.0.0.1"

    owner =
      :erlang.binary_to_term(<<131, 88, 119, byte_size(name), name::binary, 1::32, 0::32, 0::32>>)

    assert {:error, :unavailable} = RuntimeSnapshots.read(id, owner)
  end

  defp step(text) do
    %{
      id: 1,
      sequence: 1,
      status: "waiting_provider",
      raw_response: %{secret: true},
      items: [
        %{
          id: -1,
          sequence: 1,
          type: "answer",
          contents: [%{id: -2, sequence: 1, kind: "text", content_text: text}]
        }
      ]
    }
  end
end
