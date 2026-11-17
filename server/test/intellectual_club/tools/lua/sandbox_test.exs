defmodule IntellectualClub.Tools.Lua.SandboxTest do
  use ExUnit.Case, async: false
  import IntellectualClub.TestEnv
  alias IntellectualClub.Tools.Lua.Sandbox

  setup do
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  test "the watchdog kills a blocked worker and releases capacity", ctx do
    put_app_env(:lua_tool_limits, timeout_ms: 100)
    test = self()

    task =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        Sandbox.run(:watchdog_test, fn ->
          send(test, {:worker, self()})

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    assert {:error, message} = Task.await(task)
    assert message =~ "timed out"
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert :ok = Sandbox.run(:watchdog_test, fn -> :ok end)
  end

  test "caller death terminates the worker even if it is blocked", ctx do
    test = self()

    {:ok, caller} =
      Task.Supervisor.start_child(ctx.supervisor, fn ->
        Sandbox.run(:cancellation_test, fn ->
          send(test, {:worker, self()})

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
  end

  test "per-user capacity fails fast without blocking other users", ctx do
    put_app_env(:lua_tool_limits, max_per_user: 1)
    test = self()

    task =
      Task.Supervisor.async_nolink(ctx.supervisor, fn ->
        Sandbox.run(:busy_user, fn ->
          send(test, {:worker, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:worker, worker}
    assert {:error, message} = Sandbox.run(:busy_user, fn -> flunk("capacity must reject") end)
    assert message =~ "capacity"
    assert :ok = Sandbox.run(:other_user, fn -> :ok end)
    send(worker, :finish)
    assert :ok = Task.await(task)
  end
end
