defmodule IntellectualClub.OutletBackgroundFixtures do
  @moduledoc """
  Helpers for background tasks executed by an outlet runner.

  The test plays the runner (see `IntellectualClub.OutletRunnerHelpers`, which
  also provides `wait_for_pending_operations!/2`): `connect_runner!/3` completes
  the tool discovery and returns a runner payload with control capacity, `wait_for_control_call!/4`
  polls `IntellectualClub.Outlets.Runtime` like the runner does, and
  `complete_background_call!/4` answers a control call.
  """

  import ExUnit.Assertions
  import IntellectualClub.Fixtures
  import IntellectualClub.OutletRunnerHelpers
  import IntellectualClub.SubagentFixtures

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.ToolInstance

  @poll_attempts 250
  @poll_interval_ms 20

  @doc """
  Creates an outlet tool instance (alias `"outlet"`, one execution slot,
  no long polling, 60 s online timeout, 300 s disconnect grace).
  """
  def create_outlet_tool_instance!(actor, attrs \\ %{}) do
    defaults = %{
      type: "outlet",
      name: "Background Outlet",
      alias: "outlet",
      config: %{
        "max_concurrency" => 1,
        "poll_max_wait_seconds" => 0,
        "runner_online_timeout_seconds" => 60,
        "disconnect_grace_seconds" => 300
      },
      secrets: %{"token" => "background-outlet-token"},
      max_output_tokens: 20_000
    }

    create!(ToolInstance, merge_attrs(defaults, attrs), actor)
  end

  @doc """
  Connects a control-lane runner session (see
  `IntellectualClub.OutletRunnerHelpers.connect_outlet_runner!/4`) and returns
  the runner payload for control polls.
  """
  def connect_runner!(tool_instance, runner_id, runner_session_id) do
    connect_outlet_runner!(tool_instance, runner_id, runner_session_id, control_lane: true)
  end

  @doc """
  Polls as `runner` until a control call with `operation` arrives and returns
  it; fails on any other call or after the poll budget.
  """
  def wait_for_control_call!(tool_instance, runner, operation, attempts \\ @poll_attempts)

  def wait_for_control_call!(tool_instance, _runner, operation, 0) do
    runtime =
      Runtime
      |> :sys.get_state()
      |> get_in([:instances, tool_instance.id])
      |> case do
        %{} = instance -> Map.take(instance, [:runner, :pending, :running])
        other -> other
      end

    tasks =
      BackgroundTask
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.tool_instance_id == tool_instance.id))
      |> Enum.map(&Map.take(&1, [:id, :status, :runner_ref, :cancel_requested, :error]))

    flunk(
      "Timed out waiting for #{operation}; runtime=#{inspect(runtime)} tasks=#{inspect(tasks)}"
    )
  end

  def wait_for_control_call!(tool_instance, runner, operation, attempts) do
    case Runtime.poll(tool_instance, runner) do
      {:ok, %{tasks: []}} ->
        Process.sleep(@poll_interval_ms)
        wait_for_control_call!(tool_instance, runner, operation, attempts - 1)

      {:ok, %{tasks: tasks}} ->
        Enum.find(tasks, &(&1.operation == operation)) ||
          flunk("Expected #{operation}, got #{inspect(Enum.map(tasks, & &1.operation))}")

      other ->
        flunk("Unexpected outlet poll result: #{inspect(other)}")
    end
  end

  @doc "Completes the control `call` received by `runner` with `result_raw`."
  def complete_background_call!(tool_instance, runner, call, result_raw) do
    complete_outlet_call!(tool_instance, runner, call, %{"result_raw" => result_raw})
  end

  @doc "Restarts `IntellectualClub.Outlets.Runtime` under the application supervisor if needed."
  def ensure_outlet_runtime_started do
    if Process.whereis(Runtime) do
      :ok
    else
      case Supervisor.restart_child(IntellectualClub.Supervisor, Runtime) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  @doc """
  Launches `run_command` with `command` in the background from a fresh source
  tool call and returns the background task id.
  """
  def launch_background!(actor, tool_instance, command) do
    source = create_source_tool_call!(actor)
    context = tool_call_context(source, actor, root_chat_id: source.chat.id)

    assert {:ok, launch} =
             BackgroundTasks.start_tool(
               tool_instance,
               "run_command",
               %{"command" => command},
               context
             )

    task_id = launch.raw["background_task_id"]
    assert Ecto.UUID.cast(task_id) == {:ok, task_id}
    task_id
  end

  @doc """
  Launches `command`, acknowledges its `background_start` as running and
  waits until the local worker has handed the task over to the runner.
  """
  def start_running_background!(actor, tool_instance, runner, command) do
    task_id = launch_background!(actor, tool_instance, command)
    start_call = wait_for_control_call!(tool_instance, runner, "background_start")
    assert start_call.background_task_id == task_id

    complete_background_call!(tool_instance, runner, start_call, %{
      "background_task_id" => task_id,
      "status" => "running",
      "progress" => [],
      "next_cursor" => "0"
    })

    wait_for_worker_exit(task_id)
    _task = wait_for_task_status(task_id, actor.id, :running)
    task_id
  end

  @doc """
  Creates an outlet background task (`run_command "echo recovered"`, queued)
  for a fresh source tool call; `attrs` override the defaults.
  """
  def create_outlet_background_task!(actor, tool_instance, attrs) do
    source = create_source_tool_call!(actor)
    context = tool_call_context(source, actor, root_chat_id: source.chat.id)

    defaults = %{
      kind: "outlet_function",
      adapter: "outlet",
      status: :queued,
      function_name: "run_command",
      arguments: %{"command" => "echo recovered"},
      execution_context: execution_context_json(context),
      runner_ref: %{},
      tool_instance_id: tool_instance.id,
      source_chat_id: source.chat.id,
      source_message_id: source.message.id,
      source_step_id: source.step.id,
      source_tool_call_item_id: source.item.id
    }

    create!(BackgroundTask, Map.merge(defaults, attrs), actor)
  end

  @doc "Waits until the task owned by `owner_id` has `status` and returns it."
  def wait_for_task_status(task_id, owner_id, status, attempts \\ @poll_attempts)

  def wait_for_task_status(task_id, owner_id, status, 0) do
    flunk(
      "Background task did not reach #{status}: #{inspect(load_owned_task(task_id, owner_id))}"
    )
  end

  def wait_for_task_status(task_id, owner_id, status, attempts) do
    case load_owned_task(task_id, owner_id) do
      {:ok, %{status: ^status} = task} ->
        task

      {:ok, _task} ->
        Process.sleep(@poll_interval_ms)
        wait_for_task_status(task_id, owner_id, status, attempts - 1)

      other ->
        flunk("Unable to load background task: #{inspect(other)}")
    end
  end

  @doc "Reads the background task as its owner."
  def load_owned_task(task_id, owner_id) do
    case Ash.get(BackgroundTask, task_id, actor: %User{id: owner_id}) do
      {:ok, %BackgroundTask{} = task} -> {:ok, task}
      _other -> {:error, :not_found}
    end
  end

  @doc "Waits until no local worker is registered for the task."
  def wait_for_worker_exit(task_id, attempts \\ @poll_attempts)

  def wait_for_worker_exit(task_id, 0), do: flunk("Background worker #{task_id} did not stop")

  def wait_for_worker_exit(task_id, attempts) do
    case Registry.lookup(IntellectualClub.BackgroundTasks.ProcessRegistry, task_id) do
      [] ->
        :ok

      _workers ->
        Process.sleep(@poll_interval_ms)
        wait_for_worker_exit(task_id, attempts - 1)
    end
  end
end
