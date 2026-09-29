defmodule IntellectualClub.Generation.PersistenceFailure do
  @moduledoc """
  Classifies persistence failures without conflating a rollback with a lost commit acknowledgement.

  Only the owner of a transaction boundary may use `transaction/2`. Request preparation,
  response processing and post-commit work must never be replayed by that helper.
  Provider retry policy is deliberately unrelated to this bounded database retry policy.
  """

  require Logger

  @rollback_codes [:deadlock_detected, :serialization_failure, "40P01", "40001"]
  @retry_delays [100, 500, 1_500]
  @sql_scope {__MODULE__, :sql_scope}
  @sql_handler {__MODULE__, :sql_error}

  @doc false
  def attach_telemetry do
    case :telemetry.attach(
           @sql_handler,
           [:intellectual_club, :repo, :query],
           &__MODULE__.query/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def query(_event, _measurements, %{result: {:error, error}}, _config) do
    # Ecto emits the typed driver error before Ash/Splode converts it to text.
    # Only this process's active attempt may retain it; never retain SQL params.
    case Process.get(@sql_scope) do
      %{error: nil}
      when is_struct(error, Postgrex.Error) or is_struct(error, DBConnection.ConnectionError) ->
        Process.put(@sql_scope, %{error: error})

      _ ->
        :ok
    end

    :ok
  end

  def query(_event, _measurements, _metadata, _config), do: :ok

  @doc "Runs an Ash transaction, then delivers notifications outside its retry boundary."
  def ash_transaction(resources, fun, opts \\ []) do
    if IntellectualClub.Repo.in_transaction?() do
      Ash.transaction(resources, fun, opts)
    else
      result =
        transaction(
          fn ->
            Ash.transaction(resources, fun, Keyword.put(opts, :return_notifications?, true))
          end,
          operation: :ash_transaction
        )

      case result do
        {:ok, value, notifications} ->
          if Keyword.get(opts, :return_notifications?, false) do
            result
          else
            try do
              notifications
              |> Ash.Notifier.notify()
              |> Enum.group_by(&{&1.resource, &1.action})
              |> Enum.each(fn {{resource, action}, remaining} ->
                Ash.Actions.Helpers.warn_missed!(resource, action, %{notifications: remaining})
              end)

              {:ok, value}
            rescue
              error ->
                raise new(error,
                        kind: :unknown,
                        operation: :post_commit_notifications,
                        stacktrace: __STACKTRACE__
                      )
            catch
              kind, reason ->
                raise new({kind, reason},
                        kind: :unknown,
                        operation: :post_commit_notifications,
                        stacktrace: __STACKTRACE__
                      )
            end
          end

        other ->
          other
      end
    end
  end

  defexception [:kind, :reason, :operation, :stacktrace, attempts: 1]

  @impl true
  def message(failure), do: summary(failure)

  def new(reason, opts \\ [])
  def new(%__MODULE__{} = failure, _opts), do: failure

  def new(reason, opts) do
    %__MODULE__{
      kind: Keyword.get(opts, :kind, classify(reason)),
      reason: reason,
      operation: Keyword.get(opts, :operation),
      stacktrace: Keyword.get(opts, :stacktrace, []),
      attempts: Keyword.get(opts, :attempts, 1)
    }
  end

  def capture(fun, operation, opts \\ []) do
    old_scope = Process.put(@sql_scope, %{error: nil})

    try do
      case fun.() do
        {:error, %__MODULE__{}} = failure ->
          failure

        {:error, reason} ->
          case Process.get(@sql_scope).error do
            nil -> {:error, reason}
            sql_error -> {:error, new(sql_error, operation: operation)}
          end

        result ->
          result
      end
    rescue
      failure in [__MODULE__] ->
        {:error, failure}

      error ->
        cause = Process.get(@sql_scope).error || error

        kind =
          if is_nil(Process.get(@sql_scope).error) and
               Keyword.get(opts, :unknown_exception?, false), do: :unknown, else: classify(cause)

        {:error, new(cause, kind: kind, operation: operation, stacktrace: __STACKTRACE__)}
    catch
      :exit, reason ->
        kind = if lease_lost?(reason), do: :lease_lost, else: :unknown
        {:error, new(reason, kind: kind, operation: operation, stacktrace: __STACKTRACE__)}
    after
      if is_nil(old_scope),
        do: Process.delete(@sql_scope),
        else: Process.put(@sql_scope, old_scope)
    end
  end

  def task_down(reason, operation) do
    new(reason,
      kind: if(lease_lost?(reason), do: :lease_lost, else: :unknown),
      operation: operation
    )
  end

  def transaction(fun, opts \\ []) when is_function(fun, 0) do
    # At most three additional attempts, even if a caller supplies more delays.
    delays = Keyword.get(opts, :delays, @retry_delays) |> Enum.take(3)

    if IntellectualClub.Repo.in_transaction?() do
      # A nested Ash/Ecto transaction does not own the outer rollback. Let its
      # owner retry the complete transaction instead of using an aborted one.
      fun.()
    else
      retry_transaction(fun, opts, delays, 1)
    end
  end

  defp retry_transaction(fun, opts, delays, attempt) do
    old_scope = Process.put(@sql_scope, %{error: nil})

    {result, sql_error} =
      try do
        result =
          try do
            {:returned, fun.()}
          rescue
            error -> {:raised, error, __STACKTRACE__}
          end

        {result, Process.get(@sql_scope).error}
      after
        if is_nil(old_scope),
          do: Process.delete(@sql_scope),
          else: Process.put(@sql_scope, old_scope)
      end

    reason =
      case result do
        {:returned, {:error, reason}} -> sql_error || reason
        {:raised, reason, _stack} -> sql_error || reason
        _ -> nil
      end

    if rollback?(reason) and not connection_failure?(reason) do
      case delays do
        [delay | rest] ->
          delay = max(delay, 0)
          delay = delay + if(delay > 0, do: :rand.uniform(max(div(delay, 5), 1)) - 1, else: 0)
          operation = Keyword.get(opts, :operation, :transaction)

          Logger.warning(
            "Generation database transaction retry " <>
              "operation=#{operation} attempt=#{attempt} delay_ms=#{delay}"
          )

          :telemetry.execute(
            [:intellectual_club, :generation, :persistence, :retry],
            %{attempt: attempt, delay_ms: delay},
            %{operation: operation, message_id: Keyword.get(opts, :message_id)}
          )

          # The failed transaction has exited and returned its connection before
          # waiting. The Worker mailbox remains available while this task waits.
          receive do
          after
            delay -> retry_transaction(fun, opts, rest, attempt + 1)
          end

        [] ->
          stack =
            case result do
              {:raised, _, stack} -> stack
              _ -> []
            end

          raise new(reason,
                  kind: :retry_exhausted,
                  operation: Keyword.get(opts, :operation),
                  attempts: attempt,
                  stacktrace: stack
                )
      end
    else
      case result do
        {:returned, {:error, _}} when not is_nil(sql_error) ->
          {:error, new(sql_error, operation: Keyword.get(opts, :operation))}

        {:returned, value} ->
          value

        {:raised, _error, stack} when not is_nil(sql_error) ->
          raise new(sql_error, operation: Keyword.get(opts, :operation), stacktrace: stack)

        {:raised, error, stack} ->
          reraise error, stack
      end
    end
  end

  def classify({:exit, reason}), do: if(lease_lost?(reason), do: :lease_lost, else: :unknown)

  def classify(reason) do
    cond do
      lease_lost?(reason) -> :lease_lost
      connection_failure?(reason) -> :unknown
      true -> :permanent
    end
  end

  def rollback?(reason), do: contains?(reason, &rollback_error?/1)

  @doc "Identifies transient database errors for reads or explicitly idempotent operations."
  def transient_database_error?(reason), do: rollback?(reason) or connection_failure?(reason)

  @doc "Retries an explicitly idempotent operation after transient database failures."
  def retry_idempotent(fun, opts \\ []) when is_function(fun, 0) do
    if IntellectualClub.Repo.in_transaction?() do
      raise ArgumentError, "idempotent retry must own its transaction boundary"
    end

    retry_idempotent(fun, opts, Enum.take(Keyword.get(opts, :delays, @retry_delays), 3), 1)
  end

  defp retry_idempotent(fun, opts, delays, attempt) do
    operation = Keyword.fetch!(opts, :operation)
    result = capture(fun, operation)

    case {result, delays} do
      {{:error, reason}, [delay | rest]} ->
        if transient_database_error?(reason) do
          delay = max(delay, 0)
          delay = delay + if(delay > 0, do: :rand.uniform(max(div(delay, 5), 1)) - 1, else: 0)

          Logger.warning(
            "Generation idempotent database operation retry " <>
              "operation=#{operation} attempt=#{attempt} delay_ms=#{delay}"
          )

          receive do
          after
            delay -> retry_idempotent(fun, opts, rest, attempt + 1)
          end
        else
          result
        end

      _ ->
        result
    end
  end

  defp connection_failure?(reason), do: contains?(reason, &connection_error?/1)

  defp rollback_error?(%Postgrex.Error{postgres: postgres}) when is_map(postgres),
    do: postgres[:code] in @rollback_codes or postgres[:pg_code] in @rollback_codes

  defp rollback_error?(_), do: false
  defp connection_error?(%DBConnection.ConnectionError{}), do: true

  defp connection_error?(%Postgrex.Error{postgres: nil}), do: true

  defp connection_error?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] in [
      :admin_shutdown,
      :crash_shutdown,
      :cannot_connect_now,
      :too_many_connections
    ] or
      postgres[:pg_code] in ["57P01", "57P02", "57P03", "53300"] or
      (is_binary(postgres[:pg_code]) and String.starts_with?(postgres[:pg_code], "08"))
  end

  defp connection_error?(_), do: false

  # Inspect typed exception causes only, never infer retryability from arbitrary
  # text, SQL, provider payloads or a user-supplied string containing a SQLSTATE.
  defp contains?(nil, _predicate), do: false

  defp contains?(reason, predicate) do
    predicate.(reason) or
      case reason do
        %{errors: errors} when is_list(errors) -> Enum.any?(errors, &contains?(&1, predicate))
        %{error: error} -> contains?(error, predicate)
        %{reason: cause} -> contains?(cause, predicate)
        _ -> false
      end
  end

  def lease_lost?(reason) when reason in [:lease_lost, :lease_not_fenced], do: true
  def lease_lost?({:generation_lease_lost, _}), do: true
  def lease_lost?(%__MODULE__{kind: :lease_lost}), do: true
  def lease_lost?(_), do: false

  def summary(%__MODULE__{} = failure) do
    operation = failure.operation || :persistence
    cause = cause_name(failure.reason)

    suffix =
      if failure.kind == :retry_exhausted,
        do: " after #{failure.attempts} database attempts",
        else: ""

    "Generation #{operation} failed: #{cause}#{suffix}"
  end

  defp cause_name(%{__struct__: module}), do: inspect(module)
  defp cause_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp cause_name({name, _}) when is_atom(name), do: Atom.to_string(name)
  defp cause_name(_), do: "persistence operation error"

  def log(%__MODULE__{} = failure, message_id, step_id) do
    level = if failure.kind in [:permanent, :retry_exhausted], do: :error, else: :warning

    Logger.log(
      level,
      "Generation persistence failure message_id=#{message_id} step_id=#{inspect(step_id)} " <>
        "operation=#{failure.operation} classification=#{failure.kind} attempts=#{failure.attempts} " <>
        "reason=#{inspect(failure.reason, limit: 12, printable_limit: 500)}\n" <>
        Exception.format_stacktrace(failure.stacktrace || [])
    )
  end
end
