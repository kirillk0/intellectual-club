defmodule IntellectualClub.TestEnv do
  @moduledoc """
  Per-test application environment overrides.

  The application environment is global, so these helpers are only safe in
  `async: false` modules. Every override is restored when the test exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Sets `key` for the current test and restores the previous value on exit."
  def put_app_env(key, value, app \\ :intellectual_club) when is_atom(key) and is_atom(app) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)
    on_exit(fn -> restore_app_env(app, key, previous) end)
    :ok
  end

  @doc "Deletes `key` for the current test and restores the previous value on exit."
  def delete_app_env(key, app \\ :intellectual_club) when is_atom(key) and is_atom(app) do
    previous = Application.fetch_env(app, key)
    Application.delete_env(app, key)
    on_exit(fn -> restore_app_env(app, key, previous) end)
    :ok
  end

  defp restore_app_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_app_env(app, key, :error), do: Application.delete_env(app, key)
end
