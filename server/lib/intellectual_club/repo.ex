defmodule IntellectualClub.Repo do
  use AshPostgres.Repo,
    otp_app: :intellectual_club,
    warn_on_missing_ash_functions?: false

  require Logger

  defoverridable transact: 2

  # Ecto's transaction/2 delegates to transact/2, including Ecto.Multi calls.
  # Keep callbacks scoped to the outer boundary and the current dynamic repo.
  def transact(fun_or_multi, opts) do
    if in_transaction?() do
      super(fun_or_multi, opts)
    else
      key = after_commit_key()
      Process.put(key, [])

      {result, callbacks} =
        try do
          result = super(fun_or_multi, opts)
          {result, Process.get(key)}
        after
          Process.delete(key)
        end

      if match?({:ok, _}, result) do
        callbacks |> Enum.reverse() |> Enum.each(&run_after_commit/1)
      end

      result
    end
  end

  @doc """
  Runs best-effort work after the outermost Repo transaction commits.

  Nested transactions share the outer callback queue. Rollback, exceptions and
  uncertain commit outcomes discard it. Outside a transaction, work runs now.
  Callback failures are logged, never reported as failures of a committed write.
  """
  def after_commit(fun) when is_function(fun, 0) do
    callback = {get_dynamic_repo(), fun}

    if in_transaction?() do
      key = after_commit_key()

      case Process.get(key) do
        nil -> raise ArgumentError, "After-commit work requires a Repo transaction boundary"
        callbacks -> Process.put(key, [callback | callbacks])
      end
    else
      run_after_commit(callback)
    end

    :ok
  end

  defp after_commit_key, do: {__MODULE__, :after_commit, get_dynamic_repo()}

  defp run_after_commit({repo, fun}) do
    previous_repo = get_dynamic_repo()
    put_dynamic_repo(repo)

    try do
      fun.()
    rescue
      exception -> Logger.warning("After-commit callback failed: #{Exception.message(exception)}")
    catch
      kind, reason -> Logger.warning("After-commit callback failed: #{inspect({kind, reason})}")
    after
      put_dynamic_repo(previous_repo)
    end
  end

  def installed_extensions, do: ["ash-functions", "pg_trgm"]

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
