defmodule IntellectualClub.Generation.RecoveryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.Recovery

  test "coalesces overlapping requests into one pending recovery" do
    test_pid = self()
    release_ref = make_ref()

    recovery_fun = fn ->
      send(test_pid, {:recovery_started, self()})

      receive do
        {:release, ^release_ref} -> :ok
      end
    end

    recovery =
      start_supervised!({Recovery, name: nil, recovery_fun: recovery_fun})

    :ok = Recovery.request(recovery)
    assert_receive {:recovery_started, first_task}, 1_000

    :ok = Recovery.request(recovery)
    :ok = Recovery.request(recovery)
    :ok = Recovery.request(recovery)

    assert Recovery.status(recovery) == %{running?: true, pending?: true}
    refute_receive {:recovery_started, _task}, 50

    send(first_task, {:release, release_ref})
    assert_receive {:recovery_started, second_task}, 1_000
    assert Recovery.status(recovery) == %{running?: true, pending?: false}
    refute_receive {:recovery_started, _task}, 50

    send(second_task, {:release, release_ref})
    assert_eventually_idle(recovery)
  end

  defp assert_eventually_idle(recovery, attempts \\ 50)

  defp assert_eventually_idle(_recovery, 0) do
    flunk("Recovery coordinator did not become idle")
  end

  defp assert_eventually_idle(recovery, attempts) do
    if Recovery.status(recovery) == %{running?: false, pending?: false} do
      :ok
    else
      Process.sleep(10)
      assert_eventually_idle(recovery, attempts - 1)
    end
  end
end
