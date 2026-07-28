defmodule IntellectualClub.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias IntellectualClub.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import IntellectualClub.AccountsFixtures
      import IntellectualClub.DataCase
    end
  end

  setup tags do
    IntellectualClub.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(IntellectualClub.Repo, shared: not tags[:async])

    on_exit(fn ->
      IntellectualClub.DataCase.stop_background_test_tasks()
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)
  end

  @doc false
  def stop_background_test_tasks do
    terminate_dynamic_children(IntellectualClub.BackgroundTasks.Supervisor)
    terminate_dynamic_children(IntellectualClub.BackgroundTasks.ExecutionSupervisor)
    terminate_dynamic_children(IntellectualClub.Generation.Supervisor)
    terminate_dynamic_children(IntellectualClub.Notifications.Dispatcher)
    :ok
  end

  defp terminate_dynamic_children(supervisor) do
    if Process.whereis(supervisor) do
      supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_id, pid, _type, _modules} when is_pid(pid) ->
          _ = DynamicSupervisor.terminate_child(supervisor, pid)

        _other ->
          :ok
      end)
    end
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
