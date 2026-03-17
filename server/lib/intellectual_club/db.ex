defmodule IntellectualClub.Db do
  @moduledoc """
  Centralized access to the currently active database backend.

  The runtime chooses between SQLite and PostgreSQL based on `DATABASE_URL`
  (see `config/runtime.exs`).
  """

  @spec repo() :: module()
  def repo do
    Application.get_env(:intellectual_club, :active_repo, IntellectualClub.Repo)
  end

  @spec data_layer() :: module()
  def data_layer do
    Application.get_env(:intellectual_club, :active_data_layer, AshSqlite.DataLayer)
  end

  @spec adapter() :: :sqlite | :postgres
  def adapter do
    case data_layer() do
      AshPostgres.DataLayer -> :postgres
      AshSqlite.DataLayer -> :sqlite
      _ -> :sqlite
    end
  end

  @spec postgres?() :: boolean()
  def postgres?, do: adapter() == :postgres

  @spec sqlite?() :: boolean()
  def sqlite?, do: adapter() == :sqlite
end
