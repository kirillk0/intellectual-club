defmodule IntellectualClub.OutletsReconciliationTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.ToolInstance

  setup do
    Runtime.reset!()
    on_exit(&Runtime.reset!/0)
    supervisor = start_supervised!(Task.Supervisor)
    %{user: actor} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(:create, %{type: "outlet", name: "Reconciliation outlet"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    context = %{
      tool: tool,
      supervisor: supervisor,
      runner: %{
        "runner_id" => "stable-runner",
        "runner_session_id" => "first-session",
        "capacity" => 20,
        "max_wait_seconds" => 0
      }
    }

    assert {:ok, %{tasks: [discovery]}} = poll(context, 1, [])
    complete(context, discovery.call_id)
    context
  end

  test "a fresh empty snapshot fails calls lost with a poll response and releases their waiters",
       context do
    {first_waiter, first} = claim(context, 2, [])
    {second_waiter, second} = claim(context, 3, [first.call_id])

    assert {:ok, %{tasks: []}} = poll(context, 4, [])

    for {waiter, call} <- [{first_waiter, first}, {second_waiter, second}] do
      assert {:error, error} = Task.await(waiter)
      assert error =~ "no longer tracks this call"
      assert error =~ "outcome is unknown"
      assert {:error, :not_found} = Runtime.fetch_running_call(context.tool, call.call_id)
    end

    state = :sys.get_state(Runtime)
    assert state.instances[context.tool.id].call_waiters == %{}
    assert state.waiter_index == %{}
  end

  test "snapshots preserve tracked long calls and calls whose completion is still being delivered",
       context do
    {waiter, call} = claim(context, 2, [])

    :sys.replace_state(Runtime, fn state ->
      put_in(
        state,
        [:instances, context.tool.id, :running, call.call_id, :started_at_ms],
        System.monotonic_time(:millisecond) - 3_600_000
      )
    end)

    for sequence <- 3..5 do
      assert {:ok, %{tasks: []}} = poll(context, sequence, [call.call_id])
      assert {:ok, _call} = Runtime.fetch_running_call(context.tool, call.call_id)
    end

    complete(context, call.call_id)
    assert {:ok, %{text: "done"}} = Task.await(waiter)
    assert {:ok, %{tasks: []}} = poll(context, 6, [])
  end

  test "missing and malformed reports keep legacy calls alive", context do
    {waiter, call} = claim(context, 2, [])

    reports = [
      %{},
      %{"poll_sequence" => 3},
      %{"poll_sequence" => 4, "active_call_ids" => nil},
      %{"poll_sequence" => 5, "active_call_ids" => "not-a-list"},
      %{"poll_sequence" => 6, "active_call_ids" => [call.call_id, nil]},
      %{"poll_sequence" => 7, "active_call_ids" => [""]},
      %{"active_call_ids" => []},
      %{"poll_sequence" => "8", "active_call_ids" => []}
    ]

    for report <- reports do
      assert {:ok, %{tasks: []}} = Runtime.poll(context.tool, Map.merge(context.runner, report))
      assert {:ok, _call} = Runtime.fetch_running_call(context.tool, call.call_id)
    end

    complete(context, call.call_id)
    assert {:ok, _result} = Task.await(waiter)
  end

  test "delayed or duplicate polls neither fail newer calls nor claim pending work", context do
    {waiter, call} = claim(context, 3, [])
    assert :ok = Runtime.enqueue_if_absent(context.tool, "another_call", %{})

    for sequence <- [2, 3] do
      assert {:ok, %{tasks: []}} = poll(context, sequence, [])
      assert {:ok, _call} = Runtime.fetch_running_call(context.tool, call.call_id)
      assert [_pending] = :sys.get_state(Runtime).instances[context.tool.id].pending
    end

    assert {:ok, %{tasks: [new_call]}} = poll(context, 4, [call.call_id])
    assert {:ok, _call} = Runtime.fetch_running_call(context.tool, new_call.call_id)
    complete(context, call.call_id)
    complete(context, new_call.call_id)
    assert {:ok, _result} = Task.await(waiter)
  end

  test "a snapshot fails only missing calls and frees capacity before assigning new calls",
       context do
    {missing_waiter, missing} = claim(context, 2, [])
    {tracked_waiter, tracked} = claim(context, 3, [missing.call_id])
    assert :ok = Runtime.enqueue_if_absent(context.tool, "next_call", %{})
    tool = %{context.tool | config: %{"max_concurrency" => 2}}

    assert {:ok, %{tasks: [next]}} = poll(%{context | tool: tool}, 4, [tracked.call_id])
    assert {:error, _error} = Task.await(missing_waiter)
    assert {:ok, _call} = Runtime.fetch_running_call(tool, tracked.call_id)
    assert {:ok, _call} = Runtime.fetch_running_call(tool, next.call_id)

    complete(context, tracked.call_id)
    complete(context, next.call_id)
    assert {:ok, _result} = Task.await(tracked_waiter)
  end

  test "a conflicting runner cannot reconcile calls and a restarted runner resets the sequence",
       context do
    {waiter, call} = claim(context, 100, [])
    competing = %{context | runner: Map.put(context.runner, "runner_id", "another-runner")}
    assert {:error, :runner_already_active} = poll(competing, 101, [])
    assert {:ok, _call} = Runtime.fetch_running_call(context.tool, call.call_id)

    restarted = %{context | runner: Map.put(context.runner, "runner_session_id", "new-session")}
    assert {:ok, %{tasks: [discovery]}} = poll(restarted, 1, [])
    assert {:error, "Runner session replaced before completion."} = Task.await(waiter)
    assert {:error, :not_found} = Runtime.fetch_running_call(context.tool, call.call_id)
    complete(restarted, discovery.call_id)
    assert {:ok, %{tasks: []}} = poll(restarted, 2, [])
  end

  test "disconnect timeout still applies to runners reporting active calls", context do
    {waiter, _call} = claim(context, 2, [])
    now = System.monotonic_time(:millisecond)

    :sys.replace_state(Runtime, fn state ->
      update_in(state, [:instances, context.tool.id, :runner], fn runner ->
        %{runner | last_seen_ms: now - 400_000, offline_since_ms: now - 301_000}
      end)
    end)

    send(Process.whereis(Runtime), :sweep)
    _state = :sys.get_state(Runtime)
    assert {:error, "Runner disconnected."} = Task.await(waiter)
  end

  defp poll(context, sequence, active_call_ids, overrides \\ %{}) do
    payload =
      context.runner
      |> Map.merge(%{"poll_sequence" => sequence, "active_call_ids" => active_call_ids})
      |> Map.merge(overrides)

    Runtime.poll(context.tool, payload)
  end

  defp claim(context, sequence, active_call_ids) do
    waiter =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        Runtime.enqueue_and_wait(context.tool, "read_image", %{"local_path" => "image.png"})
      end)

    assert {:ok, %{tasks: [call]}} =
             poll(context, sequence, active_call_ids, %{"max_wait_seconds" => 5})

    # The request's snapshot must not be applied to calls assigned by its response.
    assert {:ok, _call} = Runtime.fetch_running_call(context.tool, call.call_id)
    {waiter, call}
  end

  defp complete(context, call_id) do
    assert :ok =
             Runtime.complete(
               context.tool,
               Map.merge(context.runner, %{
                 "call_id" => call_id,
                 "status" => "done",
                 "result_text" => "done",
                 "result_raw" => %{}
               })
             )
  end
end
