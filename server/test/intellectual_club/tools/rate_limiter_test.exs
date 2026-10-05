defmodule IntellectualClub.Tools.RateLimiterTest do
  use ExUnit.Case, async: false

  import IntellectualClub.WaitHelpers

  alias IntellectualClub.Tools.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  test "nil limit grants a slot immediately" do
    id = unique_id()

    assert :ok = RateLimiter.await_slot(%{id: id, rps_limit: nil})
    assert RateLimiter.queue_length(id) == 0
  end

  test "fractional limit delays the next call by cooldown" do
    id = unique_id()

    assert :ok = RateLimiter.await_slot(%{id: id, rps_limit: 10})

    started_at = System.monotonic_time(:millisecond)
    task = Task.async(fn -> RateLimiter.await_slot(%{id: id, rps_limit: 10}) end)

    assert Task.yield(task, 25) == nil
    assert Task.await(task, 250) == :ok
    assert System.monotonic_time(:millisecond) - started_at >= 80
  end

  test "cooldown is measured from slot grant, not external execution completion" do
    id = unique_id()

    assert :ok = RateLimiter.await_slot(%{id: id, rps_limit: 10})
    Process.sleep(130)

    started_at = System.monotonic_time(:millisecond)
    assert :ok = RateLimiter.await_slot(%{id: id, rps_limit: 10})
    assert System.monotonic_time(:millisecond) - started_at < 50
  end

  test "queued callers are granted in FIFO order" do
    id = unique_id()
    parent = self()

    granted = :counters.new(1, [])

    assert :ok = RateLimiter.await_slot(%{id: id, rps_limit: 20})

    tasks =
      Enum.map(1..3, fn index ->
        task =
          Task.async(fn ->
            result = RateLimiter.await_slot(%{id: id, rps_limit: 20})
            :counters.add(granted, 1, 1)
            send(parent, {:granted, index, result})
          end)

        # Under load an earlier caller may already be granted; it still counts
        # as admitted before this one.
        wait_until(fn -> RateLimiter.queue_length(id) + :counters.get(granted, 1) >= index end,
          timeout: 500
        )

        task
      end)

    grants =
      Enum.map(1..3, fn _ ->
        receive do
          {:granted, index, :ok} -> index
        after
          1_200 -> flunk("timed out waiting for queued slot")
        end
      end)

    Enum.each(tasks, &Task.await(&1, 100))
    assert grants == [1, 2, 3]
  end

  test "new callers are rejected when estimated wait exceeds max backlog" do
    id = unique_id()

    assert :ok = RateLimiter.await_slot(%{id: id, rps_limit: 0.01})
    assert {:error, :busy} = RateLimiter.await_slot(%{id: id, rps_limit: 0.01})
  end

  test "different tool instances are limited independently" do
    id1 = unique_id()
    id2 = unique_id()

    assert :ok = RateLimiter.await_slot(%{id: id1, rps_limit: 0.01})
    assert :ok = RateLimiter.await_slot(%{id: id2, rps_limit: 0.01})
  end

  test "canceled queued callers are removed from the queue" do
    id = unique_id()

    assert :ok = RateLimiter.await_slot(%{id: id, rps_limit: 1})

    task = Task.async(fn -> RateLimiter.await_slot(%{id: id, rps_limit: 1}) end)
    wait_until(fn -> RateLimiter.queue_length(id) == 1 end, timeout: 500)

    Task.shutdown(task, :brutal_kill)
    wait_until(fn -> RateLimiter.queue_length(id) == 0 end, timeout: 500)
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
