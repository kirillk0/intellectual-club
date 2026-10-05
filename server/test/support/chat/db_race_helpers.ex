defmodule IntellectualClub.Chat.DbRaceHelpers do
  @moduledoc """
  Helpers for tests that race real PostgreSQL transactions outside the SQL
  sandbox (`Sandbox.unboxed_run/2`), synchronizing on PostgreSQL's own wait
  graph instead of sleeps.

  Import explicitly: `import IntellectualClub.Chat.DbRaceHelpers`.

  A typical race:

      setup do
        attach_query_barrier!()
        ...
      end

      holder = db_task!(fn ->
        pause_after_query(&lock_query?(&1, "chat_messages"), parent)
        do_locked_write()
      end)

      assert_receive {:query_barrier, holder_pid, holder_backend}
      waiter = db_task!(fn -> send(parent, {:backend, backend_pid!()}); conflicting_write() end)
      assert_receive {:backend, waiter_backend}
      send(holder_pid, {:continue_after_block, waiter_backend})
      assert_receive {:blocked_query, ^holder_pid, ^waiter_backend, waiting_sql, _observed}

  The holder pauses right after its first query matching the predicate, and
  resumes only once PostgreSQL reports `waiter_backend` blocked by it.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import IntellectualClub.RepoTestHelpers, only: [backend_pid!: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.LinkedForkCleanupLocksTaskFixture
  alias IntellectualClub.Chat.LinkedForkCleanupLocksUsageFixture
  alias IntellectualClub.Repo

  require Ash.Query

  @timeout 10_000
  @barrier {__MODULE__, :barrier}

  @doc "Default receive timeout of these helpers (ms)."
  def race_timeout, do: @timeout

  @doc """
  Starts a supervised task running `fun`; its result is delivered to the test
  process and returned by `finish!/1`.
  """
  def supervised_task!(fun) do
    parent = self()
    ref = make_ref()

    pid =
      start_supervised!(%{
        id: ref,
        start: {Task, :start_link, [fn -> send(parent, {:task_result, ref, fun.()}) end]},
        restart: :temporary
      })

    %{pid: pid, ref: ref, monitor: Process.monitor(pid)}
  end

  @doc """
  Like `supervised_task!/1`, but `fun` runs on its own unboxed connection and a
  raised exception is returned as `{:raised, error, stacktrace}`.
  """
  def db_task!(fun) do
    supervised_task!(fn ->
      try do
        Sandbox.unboxed_run(Repo, fun)
      rescue
        error -> {:raised, error, __STACKTRACE__}
      end
    end)
  end

  @doc "Waits for the result of a task started by `supervised_task!/1` or `db_task!/1`."
  def finish!(%{pid: pid, ref: ref, monitor: monitor}) do
    assert_receive {:task_result, ^ref, result}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, @timeout
    assert reason in [:normal, :noproc]
    result
  end

  @doc "Attaches the query barrier telemetry handler for the current test."
  def attach_query_barrier! do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        &__MODULE__.handle_query_barrier/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc """
  Arms a one-shot barrier in the calling process: after its next query whose
  SQL satisfies `matcher`, it sends `{:query_barrier, self(), backend}` to
  `parent` and waits for `{:continue_after_block, waiter_backend}`. Once the
  waiter is blocked by this connection it sends `{:blocked_query, self(),
  waiter_backend, waiting_sql, observe.()}`; `observe` runs while the waiter is
  still blocked.
  """
  def pause_after_query(matcher, parent, observe \\ fn -> :ok end) do
    Process.put(@barrier, {matcher, parent, observe})
  end

  @doc "Whether `sql` row-locks `table` (`FOR UPDATE` or `FOR NO KEY UPDATE` by default)."
  def lock_query?(sql, table, modes \\ ["FOR UPDATE", "FOR NO KEY UPDATE"]) do
    String.contains?(sql, ~s(FROM "#{table}")) and String.contains?(sql, modes)
  end

  @doc false
  def handle_query_barrier(_event, _measurements, metadata, _config) do
    with {matcher, parent, observe} <- Process.get(@barrier),
         true <- matcher.(IO.iodata_to_binary(metadata.query)) do
      Process.delete(@barrier)
      blocker = backend_pid!()
      send(parent, {:query_barrier, self(), blocker})

      receive do
        {:continue_after_block, waiter} ->
          query = await_blocked!(waiter, blocker)
          send(parent, {:blocked_query, self(), waiter, query, observe.()})
      after
        @timeout -> raise "Missing query barrier release"
      end
    end
  end

  @doc """
  Polls PostgreSQL's wait graph (on the caller's connection) until backend
  `waiter` is blocked by backend `blocker`; returns the waiting query.
  """
  def await_blocked!(waiter, blocker) do
    await_blocked!(waiter, blocker, System.monotonic_time(:millisecond) + @timeout)
  end

  defp await_blocked!(waiter, blocker, deadline) do
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: rows} =
      Repo.query!(
        "SELECT query FROM pg_stat_activity WHERE pid = $1::int " <>
          "AND $2::int = ANY(pg_blocking_pids(pid))",
        [waiter, blocker]
      )

    case rows do
      [[query]] ->
        query

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Backend #{waiter} did not wait on the expected PostgreSQL fence")
        end

        await_blocked!(waiter, blocker, deadline)
    end
  end

  @doc """
  Deletes, on committed data, everything `actor` owns (usage and task
  envelopes, chats newest first) and the account itself.
  """
  def cleanup_committed_owner!(actor) do
    Sandbox.unboxed_run(Repo, fn ->
      for resource <- [LinkedForkCleanupLocksTaskFixture, LinkedForkCleanupLocksUsageFixture] do
        resource |> Ash.read!(actor: actor) |> Enum.each(&Ash.destroy!(&1, actor: actor))
      end

      Chat
      |> Ash.Query.filter(owner_id == ^actor.id)
      |> Ash.Query.sort(id: :desc)
      |> Ash.read!(actor: actor)
      |> Enum.each(&Ash.destroy!(&1, actor: actor))

      # Account fixtures are bootstrapped without an administrator; dispose of
      # only this test's account using the same fixture-only authorization bypass.
      actor
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!(authorize?: false)
    end)
  end
end
