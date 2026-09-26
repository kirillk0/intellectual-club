defmodule IntellectualClub.Generation.PersistenceOperationTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.PersistenceOperation

  test "results are bound to operation, task, message, step and lease identity" do
    supervisor = start_supervised!({Task.Supervisor, []})
    owner = self()
    lease = %Lease{manager: self(), message_id: 101, ref: make_ref(), fence_token: "fence-a"}

    operation =
      PersistenceOperation.start(
        :provider_completed,
        101,
        202,
        lease,
        fn ->
          send(owner, {:writer_entered, self()})
          receive do: (:commit -> {:ok, :committed})
        end,
        supervisor: supervisor
      )

    assert_receive {:writer_entered, writer}
    assert writer != owner
    ref = operation.task.ref
    identity = operation.identity

    assert PersistenceOperation.matches?(operation, ref, identity, 101, 202, lease)
    refute PersistenceOperation.matches?(operation, make_ref(), identity, 101, 202, lease)

    refute PersistenceOperation.matches?(
             operation,
             ref,
             %{identity | id: make_ref()},
             101,
             202,
             lease
           )

    refute PersistenceOperation.matches?(operation, ref, identity, 102, 202, lease)
    refute PersistenceOperation.matches?(operation, ref, identity, 101, 203, lease)

    refute PersistenceOperation.matches?(operation, ref, identity, 101, 202, %{
             lease
             | ref: make_ref()
           })

    refute PersistenceOperation.matches?(operation, ref, identity, 101, 202, %{
             lease
             | fence_token: "fence-b"
           })

    send(writer, :commit)
    assert_receive {^ref, {:persistence_result, ^identity, {:ok, :committed}}}
    assert :ok = PersistenceOperation.acknowledge(operation)
  end

  test "owner kill terminates a blocked writer without terminate callbacks" do
    supervisor = start_supervised!({Task.Supervisor, []})
    test = self()

    {:ok, owner} =
      Task.Supervisor.start_child(supervisor, fn ->
        operation =
          PersistenceOperation.start(
            :round_transition,
            101,
            202,
            nil,
            fn ->
              send(test, {:writer_waiting, self()})
              receive do: (:never -> :ok)
            end,
            supervisor: supervisor
          )

        send(test, {:operation, operation})
        receive do: (:never -> :ok)
      end)

    owner_ref = Process.monitor(owner)
    assert_receive {:operation, operation}
    assert_receive {:writer_waiting, writer}
    assert writer == operation.task.pid
    writer_ref = Process.monitor(writer)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :killed}
  end

  test "shutdown joins a blocked writer before its caller may release the lease" do
    supervisor = start_supervised!({Task.Supervisor, []})
    owner = self()

    operation =
      PersistenceOperation.start(
        :cancel,
        101,
        202,
        nil,
        fn ->
          send(owner, {:writer_waiting, self()})
          receive do: (:never -> :ok)
        end,
        supervisor: supervisor
      )

    assert_receive {:writer_waiting, writer}
    monitor = Process.monitor(writer)
    assert :ok = PersistenceOperation.shutdown(operation)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}
  end
end
