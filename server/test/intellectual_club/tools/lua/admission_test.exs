defmodule IntellectualClub.Tools.Lua.AdmissionTest do
  use ExUnit.Case, async: false
  import IntellectualClub.TestEnv
  alias IntellectualClub.Tools.Lua.Admission

  test "whole calls are admitted before work and slots release on failure or caller death" do
    supervisor = start_supervised!(Task.Supervisor)
    put_app_env(:lua_tool_limits, max_per_user: 1)
    test = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Admission.with_slot(:busy_user, fn ->
          send(test, {:entered, self()})

          receive do
            :finish -> {:error, "expected"}
          end
        end)
      end)

    assert_receive {:entered, caller}
    assert {:error, _} = Admission.with_slot(:busy_user, fn -> flunk("not admitted") end)
    assert :ok = Admission.with_slot(:other_user, fn -> :ok end)
    send(caller, :finish)
    assert {:error, "expected"} = Task.await(task)
    assert :ok = Admission.with_slot(:busy_user, fn -> :ok end)

    assert_raise RuntimeError, fn ->
      Admission.with_slot(:busy_user, fn -> raise "expected" end)
    end

    assert :ok = Admission.with_slot(:busy_user, fn -> :ok end)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Admission.with_slot(:busy_user, fn ->
          send(test, :blocked)

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive :blocked
    assert Task.shutdown(task, :brutal_kill) == nil
    # Monitor DOWN and the following call travel from different senders. A
    # sys barrier then checking the monitor-owned entries avoids arbitrary sleeps.
    :sys.get_state(Admission)
    assert :ok = Admission.with_slot(:busy_user, fn -> :ok end)
  end
end
