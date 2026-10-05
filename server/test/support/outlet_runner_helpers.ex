defmodule IntellectualClub.OutletRunnerHelpers do
  @moduledoc """
  Lets a test play an outlet runner against `IntellectualClub.Outlets.Runtime`:
  connect a runner session (answering the initial tool discovery), complete
  dispatched calls and wait until operations are queued for the runner.

      runner = connect_outlet_runner!(tool_instance, "runner", "session")
      wait_for_pending_operations!(tool_instance.id, ["execute"])
      {:ok, %{tasks: [call]}} = Runtime.poll(tool_instance, runner)
      complete_outlet_call!(tool_instance, runner, call, %{"result_text" => "ok"})
  """

  import ExUnit.Assertions

  alias IntellectualClub.Outlets.Runtime

  @poll_attempts 250
  @poll_interval_ms 20

  @doc """
  Connects a runner session: answers the initial `outlet.list_tools` discovery
  with `discovery_result` (default: no tools) and returns the runner payload for
  later polls.

  By default the payload keeps one execution slot and no control lane (a
  runner without background support). With `control_lane: true` it polls only
  control calls (background operations): `"capacity" => 0`,
  `"control_capacity" => 1`.
  """
  def connect_outlet_runner!(tool_instance, runner_id, runner_session_id, opts \\ []) do
    control_lane? = Keyword.get(opts, :control_lane, false)

    discovery_runner =
      %{
        "runner_id" => runner_id,
        "runner_session_id" => runner_session_id,
        "capacity" => 1,
        "max_wait_seconds" => 0
      }
      |> then(&if(control_lane?, do: Map.put(&1, "control_capacity", 0), else: &1))

    assert {:ok, %{status: "ok", tasks: [discovery]}} =
             Runtime.poll(tool_instance, discovery_runner)

    assert discovery.operation == "execute"
    assert discovery.function == "outlet.list_tools"

    complete_outlet_call!(tool_instance, discovery_runner, discovery, %{
      "result_raw" => Keyword.get(opts, :discovery_result, %{"tools" => []})
    })

    if control_lane?,
      do: %{discovery_runner | "capacity" => 0, "control_capacity" => 1},
      else: discovery_runner
  end

  @doc """
  Completes the dispatched `call` as `runner` with status `"done"`; `attrs`
  (string keys, e.g. `"result_raw"`, `"result_text"`) are merged into the
  completion payload.
  """
  def complete_outlet_call!(tool_instance, runner, call, attrs \\ %{}) do
    payload =
      Map.merge(
        %{
          "call_id" => call.call_id,
          "runner_id" => runner["runner_id"],
          "runner_session_id" => runner["runner_session_id"],
          "status" => "done"
        },
        attrs
      )

    assert :ok = Runtime.complete(tool_instance, payload)
  end

  @doc """
  Waits until at least the `expected` operations (e.g. `["execute",
  "background_status"]`, with repetitions) are pending for the tool instance.
  """
  def wait_for_pending_operations!(tool_instance_id, expected, attempts \\ @poll_attempts)

  def wait_for_pending_operations!(_tool_instance_id, expected, 0) do
    flunk("Timed out waiting for pending outlet operations: #{inspect(expected)}")
  end

  def wait_for_pending_operations!(tool_instance_id, expected, attempts) do
    available =
      Runtime
      |> :sys.get_state()
      |> get_in([:instances, tool_instance_id, :pending])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, :operation, "execute"))
      |> Enum.frequencies()

    ready? =
      expected
      |> Enum.frequencies()
      |> Enum.all?(fn {operation, count} -> Map.get(available, operation, 0) >= count end)

    if ready? do
      :ok
    else
      Process.sleep(@poll_interval_ms)
      wait_for_pending_operations!(tool_instance_id, expected, attempts - 1)
    end
  end
end
