defmodule IntellectualClub.BackgroundTasks.Adapters.Ssh do
  @moduledoc false

  @behaviour IntellectualClub.BackgroundTasks.Adapter

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Tools.Drivers.Ssh

  @impl true
  def execute_background(task, tool_instance, function_name, args, execution_context) do
    Ssh.execute_background_command(
      task,
      tool_instance,
      function_name,
      args,
      execution_context
    )
  end

  @impl true
  def recover_background(_task), do: :execution_lost

  @impl true
  def cancel_background(task) do
    _ = Ssh.cancel_background_command(task.id)

    runner_ref =
      task.runner_ref
      |> case do
        %{} = refs -> refs
        _other -> %{}
      end
      |> Map.put("remote_termination_confirmed", false)

    case BackgroundTasks.update_runner_ref(task, runner_ref) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
