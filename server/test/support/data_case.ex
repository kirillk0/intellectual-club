defmodule IntellectualClub.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test.

  ## Shared helpers

  Test modules get these imports, so shared fixtures are called without a
  prefix. Do not copy `create_*!` helpers into test files: extend these modules
  (or pass the scenario specifics through `attrs`) instead.

    * `IntellectualClub.AccountsFixtures` — users, groups, signed-in conns;
    * `IntellectualClub.Fixtures` — `create!/3,4`, `unique_name/1` and the
      fixture conventions (actor first, `attrs` as map or keyword list);
    * `IntellectualClub.ChatFixtures` — chats, subchats, linked forks, messages,
      steps, items, contents, handoff results;
    * `IntellectualClub.BotsFixtures`, `IntellectualClub.LlmFixtures`,
      `IntellectualClub.ToolsFixtures`, `IntellectualClub.KnowledgeFixtures`,
      `IntellectualClub.BackgroundTasksFixtures`, `IntellectualClub.FilesFixtures`;
    * `IntellectualClub.ImageFixtures` — small image payloads;
    * `IntellectualClub.WaitHelpers` — `wait_until/2` and status waits;
    * `IntellectualClub.TestHttpServer` — local Bandit servers, scripted
      provider responses, SSE encoders;
    * `IntellectualClub.RepoTestHelpers` — backend pid, missing-record asserts;
    * `IntellectualClub.TestEnv` — per-test application env overrides.

  `IntellectualClubWeb.ConnCase` imports the same modules plus
  `IntellectualClubWeb.JsonApiHelpers`. `ExUnit.Case` modules import what they
  need explicitly (e.g. `IntellectualClub.ProviderStreamHelpers`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias IntellectualClub.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import IntellectualClub.AccountsFixtures
      import IntellectualClub.Fixtures
      import IntellectualClub.ChatFixtures
      import IntellectualClub.BotsFixtures
      import IntellectualClub.LlmFixtures
      import IntellectualClub.ToolsFixtures
      import IntellectualClub.KnowledgeFixtures
      import IntellectualClub.BackgroundTasksFixtures
      import IntellectualClub.FilesFixtures
      import IntellectualClub.ImageFixtures
      import IntellectualClub.WaitHelpers
      import IntellectualClub.TestHttpServer
      import IntellectualClub.RepoTestHelpers
      import IntellectualClub.TestEnv
      import IntellectualClub.DataCase
    end
  end

  setup tags do
    IntellectualClub.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  Tests tagged `sandbox: false` exercise real commit effects and must explicitly
  delete their committed fixtures before the SQL owner is stopped.
  """
  def setup_sandbox(tags) do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(IntellectualClub.Repo,
        shared: not tags[:async],
        sandbox: Map.get(tags, :sandbox, true)
      )

    on_exit(fn ->
      try do
        # Global application workers belong to the shared sandbox only. Async
        # tests must supervise and join their own explicitly allowed processes.
        unless tags[:async], do: IntellectualClub.DataCase.stop_background_test_tasks()
      after
        Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      end
    end)
  end

  @doc false
  def stop_background_test_tasks do
    IntellectualClub.SandboxCleanup.stop_background_tasks!()
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
