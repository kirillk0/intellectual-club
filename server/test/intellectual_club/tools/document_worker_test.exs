defmodule IntellectualClub.Tools.DocumentWorkerTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Tools.DocumentWorker

  setup do
    worker = start_supervised!({DocumentWorker, name: __MODULE__.Worker, queue_limit: 1})
    %{worker: worker}
  end

  test "isolates exceptions and accepts the next document", %{worker: worker} do
    assert {:error, :failed} = DocumentWorker.run(fn -> raise "broken input" end, 1_000, worker)
    assert {:ok, :ready} = DocumentWorker.run(fn -> :ready end, 1_000, worker)
  end

  test "does not load queued sources and rejects excess requests", %{worker: worker} do
    parent = self()

    first =
      :gen_server.send_request(
        worker,
        {:run,
         fn ->
           send(parent, {:loading, self()})

           receive do
             :continue -> :first
           end
         end, 5_000}
      )

    assert_receive {:loading, loader}

    second =
      :gen_server.send_request(
        worker,
        {:run,
         fn ->
           send(parent, :second_loaded)
           :second
         end, 5_000}
      )

    third =
      :gen_server.send_request(worker, {:run, fn -> send(parent, :excess_loaded) end, 5_000})

    assert {:reply, {:error, :busy}} = :gen_server.wait_response(third, 1_000)
    refute_received :second_loaded
    refute_received :excess_loaded
    send(loader, :continue)
    assert {:reply, {:ok, :first}} = :gen_server.wait_response(first, 1_000)
    assert {:reply, {:ok, :second}} = :gen_server.wait_response(second, 1_000)
    assert_received :second_loaded
  end

  test "kills a timed out loader before admitting another document", %{worker: worker} do
    parent = self()

    request =
      :gen_server.send_request(
        worker,
        {:run,
         fn ->
           send(parent, {:loading, self()})

           receive do
             :never -> :done
           end
         end, 100}
      )

    assert_receive {:loading, loader}
    monitor = Process.monitor(loader)
    assert {:reply, {:error, :timeout}} = :gen_server.wait_response(request, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^loader, :killed}
    assert {:ok, :ready} = DocumentWorker.run(fn -> :ready end, 1_000, worker)
  end

  test "cancels active work when the requesting process exits", %{worker: worker} do
    parent = self()

    caller =
      spawn(fn ->
        DocumentWorker.run(
          fn ->
            send(parent, {:loading, self()})

            receive do
              :never -> :done
            end
          end,
          5_000,
          worker
        )
      end)

    assert_receive {:loading, loader}
    monitor = Process.monitor(loader)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^loader, :killed}
    assert {:ok, :ready} = DocumentWorker.run(fn -> :ready end, 1_000, worker)
  end

  test "removes queued work when its requester exits", %{worker: worker} do
    parent = self()

    active =
      :gen_server.send_request(
        worker,
        {:run,
         fn ->
           send(parent, {:loading, self()})

           receive do
             :continue -> :done
           end
         end, 5_000}
      )

    assert_receive {:loading, loader}

    caller =
      spawn(fn ->
        request =
          :gen_server.send_request(
            worker,
            {:run, fn -> send(parent, :cancelled_source_loaded) end, 5_000}
          )

        # This call is a barrier after the admission request from the same sender.
        :sys.get_state(worker)
        send(parent, :queued)
        :gen_server.wait_response(request, 5_000)
      end)

    assert_receive :queued
    caller_ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    send(loader, :continue)
    assert {:reply, {:ok, :done}} = :gen_server.wait_response(active, 1_000)
    assert {:ok, :ready} = DocumentWorker.run(fn -> :ready end, 1_000, worker)
    refute_received :cancelled_source_loaded
  end

  @tag :whitebox
  test "checks the absolute deadline before dispatch even before the timer message", %{
    worker: worker
  } do
    parent = self()

    active =
      :gen_server.send_request(
        worker,
        {:run,
         fn ->
           send(parent, {:loading, self()})

           receive do
             :continue -> :done
           end
         end, 5_000}
      )

    assert_receive {:loading, loader}

    queued =
      :gen_server.send_request(
        worker,
        {:run, fn -> send(parent, :expired_source_loaded) end, 5_000}
      )

    :sys.replace_state(worker, fn state ->
      [job] = state.pending
      %{state | pending: [%{job | deadline: System.monotonic_time(:millisecond) - 1}]}
    end)

    send(loader, :continue)
    assert {:reply, {:ok, :done}} = :gen_server.wait_response(active, 1_000)
    assert {:reply, {:error, :timeout}} = :gen_server.wait_response(queued, 1_000)
    refute_received :expired_source_loaded
    assert {:ok, :ready} = DocumentWorker.run(fn -> :ready end, 1_000, worker)
  end

  test "stopping the manager stops its active worker", %{worker: worker} do
    parent = self()

    :gen_server.send_request(
      worker,
      {:run,
       fn ->
         send(parent, {:loading, self()})

         receive do
           :never -> :done
         end
       end, 5_000}
    )

    assert_receive {:loading, loader}
    ref = Process.monitor(loader)
    :ok = stop_supervised(DocumentWorker)
    assert_receive {:DOWN, ^ref, :process, ^loader, :killed}
  end

  test "terminates a worker exceeding its binary heap budget" do
    worker =
      start_supervised!({DocumentWorker, name: __MODULE__.SmallWorker, memory_bytes: 1_048_576},
        id: :small_worker
      )

    assert {:error, :memory_limit} =
             DocumentWorker.run(
               fn ->
                 bytes = :binary.copy("x", 4_194_304)
                 :erlang.garbage_collect()
                 byte_size(bytes)
               end,
               1_000,
               worker
             )

    assert {:ok, :ready} = DocumentWorker.run(fn -> :ready end, 1_000, worker)
  end
end
