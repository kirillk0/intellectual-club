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

  @doc """
  Runs `fun` in a transaction whose statements PostgreSQL cancels after
  `timeout_ms`, with JIT compilation disabled for them.

  Interactive reads use this so a pathological query fails fast instead of
  holding a pool connection until the client-side timeout. Returns
  `{:ok, result}` or `{:error, :statement_timeout}`; other errors are raised.
  The settings are transaction-local and restored for an enclosing transaction.
  """
  @statement_timeout_key {__MODULE__, :statement_timeout}

  def with_statement_timeout(timeout_ms, fun)
      when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    # A fixed handler is safe even when a deadline kills its caller. Per-call
    # telemetry attachments would leak on brutal task shutdown.
    :telemetry.attach(
      {__MODULE__, :statement_timeout},
      [:intellectual_club, :repo, :query],
      &__MODULE__.track_statement_timeout/4,
      nil
    )

    previous = Process.put(@statement_timeout_key, :watching)

    try do
      transaction(fn ->
        %{rows: [[previous_timeout, previous_jit]]} =
          query!("SELECT current_setting('statement_timeout'), current_setting('jit')", [])

        put_local_settings(Integer.to_string(timeout_ms), "off")
        result = fun.()
        if recorded_statement_timeout?(), do: rollback(:statement_timeout)
        put_local_settings(previous_timeout, previous_jit)
        result
      end)
      |> case do
        {:error, error} ->
          if recorded_statement_timeout?() or statement_timeout_error?(error),
            do: {:error, :statement_timeout},
            else: raise(Ash.Error.to_error_class(error))

        result ->
          result
      end
    rescue
      error ->
        if recorded_statement_timeout?() or statement_timeout_error?(error),
          do: {:error, :statement_timeout},
          else: reraise(error, __STACKTRACE__)
    after
      case {previous, recorded_statement_timeout?()} do
        {nil, _} -> Process.delete(@statement_timeout_key)
        {:watching, true} -> Process.put(@statement_timeout_key, :canceled)
        _ -> Process.put(@statement_timeout_key, previous)
      end
    end
  end

  @doc false
  def track_statement_timeout(_event, _measurements, metadata, _config) do
    # Some optional enrichment loaders intentionally handle Ash errors. Remember
    # the original cancellation before a later query only reports 25P02.
    case metadata[:result] do
      {:error, error} ->
        if Process.get(@statement_timeout_key) && statement_timeout_error?(error),
          do: Process.put(@statement_timeout_key, :canceled)

      _ ->
        :ok
    end
  end

  defp recorded_statement_timeout?, do: Process.get(@statement_timeout_key) == :canceled

  defp put_local_settings(statement_timeout, jit) do
    query!(
      "SELECT set_config('statement_timeout', $1, true), set_config('jit', $2, true)",
      [statement_timeout, jit]
    )
  end

  # Ash wraps data layer exceptions, sometimes only as their formatted message.
  defp statement_timeout_error?(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: true

  defp statement_timeout_error?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &statement_timeout_error?/1)

  defp statement_timeout_error?(%{error: error}), do: statement_timeout_error?(error)

  defp statement_timeout_error?(message) when is_binary(message),
    do: String.contains?(message, "(query_canceled)")

  defp statement_timeout_error?(_error), do: false

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
