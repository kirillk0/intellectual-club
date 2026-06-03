defmodule IntellectualClub.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can run database tests asynchronously by setting
  `use IntellectualClub.DataCase, async: true`. SQLite tests must keep
  `async: false` because SQLite only supports one writer at a time.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias IntellectualClub.Db

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
    if tags[:async] && IntellectualClub.Db.sqlite?() do
      raise """
      SQLite tests cannot run asynchronously with Ecto SQL Sandbox.

      Use async: false for tests that use IntellectualClub.DataCase or IntellectualClubWeb.ConnCase.
      """
    end

    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(IntellectualClub.Db.repo(), shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
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
