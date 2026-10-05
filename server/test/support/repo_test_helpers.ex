defmodule IntellectualClub.RepoTestHelpers do
  @moduledoc """
  Database-level helpers for lock and transaction tests.

  Imported by `IntellectualClub.DataCase` and `IntellectualClubWeb.ConnCase`.
  """

  import ExUnit.Assertions

  require Ash.Query

  @doc "Returns the PostgreSQL backend pid of the connection used by the calling process."
  def backend_pid! do
    %{rows: [[pid]]} = IntellectualClub.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  @doc "Asserts that `resource` has no record with `id` visible to `actor`."
  def assert_missing!(resource, id, actor) do
    assert {:ok, nil} = resource |> Ash.Query.filter(id == ^id) |> Ash.read_one(actor: actor)
  end
end
