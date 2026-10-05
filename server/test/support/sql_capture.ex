defmodule IntellectualClub.SqlCapture do
  @moduledoc """
  Captures the SQL statements the repo runs while a function executes, for
  whitebox tests that assert round trips, row locks and transferred payloads,
  and for tests that assert which columns are (not) read.

  `measure/2` records rich query maps plus the linked fork cleanup telemetry
  (`:plan`, `:discover`). By default only the calling process is observed,
  including queries that Ash runs in tasks spawned by it (the `$callers`
  chain):

      {result, capture} = SqlCapture.measure(fn -> Ash.destroy(chat, actor: actor) end)
      assert length(capture.queries) <= 40
      assert [_plan] = capture.plans

  `capture_queries/2` returns just the SQL text and observes every process by
  default, so absence assertions also cover work done by other processes (use
  it only in `async: false` modules, or pass `processes: :callers`):

      {context, queries} = capture_queries(fn -> Context.build!(chat.id, actor: actor) end)
      assert [] == queries |> selects_from("chat_message_steps") |> reading("raw_request")

  Each query map has `:sql`, `:params`, `:source` (the Ecto source table, else
  the first `FROM` table), `:select?`, `:lock?` (a row-locking `SELECT`),
  `:columns`, `:rows`, `:row_count`, `:result_bytes` (external term size of the
  returned rows), `:error?` and `:unmeasured?` (no row result was reported).
  """

  @query_event [:intellectual_club, :repo, :query]
  @plan_event [:intellectual_club, :linked_fork_cleanup, :plan]
  @discover_event [:intellectual_club, :linked_fork_cleanup, :discover]
  @lock_pattern ~r/FOR (?:NO KEY UPDATE|UPDATE|KEY SHARE|SHARE)/

  @doc """
  Runs `operation` and returns `{result, capture}` with `:queries`, `:plans` and
  `:discoveries` (lists of `{measurements, metadata}`) in emission order.

  Options:

    * `:processes` — `:callers` (default: the calling process and its
      `$callers` descendants) or `:all` (every process).
    * `:after_lock` — `{table, fun}`: calls `fun` once, in the calling process,
      right after the first row-locking query on `table` returns. Lets a test
      change the database between two cleanup fences of one transaction.
    * `:after_query` — `{predicate, fun}`: calls `fun` once, in the process that
      ran the query, right after the first captured query for which
      `predicate.(query)` is true (e.g. `&SqlCapture.returned?(&1, marker)`).
  """
  def measure(operation, opts \\ []) do
    table = :ets.new(__MODULE__, [:ordered_set, :public])
    handler = {__MODULE__, make_ref()}
    root = self()
    all? = Keyword.get(opts, :processes, :callers) == :all

    for key <- [:after_lock, :after_query], hook = Keyword.get(opts, key) do
      :ets.insert(table, {key, hook})
    end

    :ok =
      :telemetry.attach_many(
        handler,
        [@query_event, @plan_event, @discover_event],
        &__MODULE__.handle_event/4,
        %{root: root, table: table, all?: all?}
      )

    try do
      result = operation.()
      :telemetry.detach(handler)
      {result, capture(table)}
    after
      :telemetry.detach(handler)
      :ets.delete(table)
    end
  end

  @doc """
  Runs `fun` and returns `{result, sqls}`: the SQL text of every statement in
  execution order. Observes every process unless `processes: :callers` is given
  (see the module docs).
  """
  def capture_queries(fun, opts \\ []) when is_function(fun, 0) do
    {result, capture} = measure(fun, Keyword.put_new(opts, :processes, :all))
    {result, Enum.map(capture.queries, & &1.sql)}
  end

  @doc "Keeps the `SELECT` statements (SQL text or query maps) that read from `table`."
  def selects_from(queries, table) do
    Enum.filter(queries, fn query ->
      sql = sql(query)
      String.starts_with?(sql, "SELECT") and String.contains?(sql, ~s(FROM "#{table}"))
    end)
  end

  @doc "Keeps the statements (SQL text or query maps) that mention the quoted `column`."
  def reading(queries, column),
    do: Enum.filter(queries, &String.contains?(sql(&1), ~s("#{column}")))

  @doc "Row-locking queries of `capture`."
  def lock_queries(%{queries: queries}), do: Enum.filter(queries, & &1.lock?)

  @doc """
  Ids returned by the row-locking queries of `capture`, grouped by table:
  `%{"chats" => MapSet.t(), ...}`.
  """
  def locked_ids(capture) do
    capture
    |> lock_queries()
    |> Enum.reduce(%{}, fn query, acc ->
      Map.update(
        acc,
        query.source,
        MapSet.new(ids(query)),
        &MapSet.union(&1, MapSet.new(ids(query)))
      )
    end)
  end

  @doc "Ids of `table` rows locked in `capture` (empty when none)."
  def locked_ids(capture, table), do: Map.get(locked_ids(capture), table, MapSet.new())

  @doc "Whether any row returned by `query` (or by any query of a capture) contains `binary`."
  def returned?(%{queries: queries}, binary), do: Enum.any?(queries, &returned?(&1, binary))

  def returned?(%{rows: rows}, binary),
    do: :binary.match(:erlang.term_to_binary(rows), binary) != :nomatch

  @doc false
  def handle_event(event, measurements, metadata, %{root: root, table: table, all?: all?}) do
    if all? or self() == root or root in Process.get(:"$callers", []) or
         metadata[:caller] == root do
      value =
        case event do
          @query_event -> {:query, query(metadata)}
          @plan_event -> {:plan, {measurements, metadata}}
          @discover_event -> {:discover, {measurements, metadata}}
        end

      :ets.insert(table, {System.unique_integer([:positive, :monotonic]), value})
      maybe_after_lock(value, table, root)
      maybe_after_query(value, table)
    end
  end

  defp sql(%{sql: sql}), do: sql
  defp sql(sql) when is_binary(sql), do: sql

  defp maybe_after_lock({:query, %{lock?: true, source: source}}, table, root) do
    with true <- self() == root,
         [{:after_lock, {^source, fun}}] <- :ets.lookup(table, :after_lock) do
      :ets.delete(table, :after_lock)
      fun.()
    end
  end

  defp maybe_after_lock(_value, _table, _root), do: :ok

  defp maybe_after_query({:query, query}, table) do
    with [{:after_query, {predicate, fun}}] <- :ets.lookup(table, :after_query),
         true <- predicate.(query),
         # Only the first matching query runs the hook, also across processes.
         1 <- :ets.select_delete(table, [{{:after_query, :_}, [], [true]}]) do
      fun.()
    end
  end

  defp maybe_after_query(_value, _table), do: :ok

  defp capture(table) do
    events =
      for {key, value} <- :ets.tab2list(table), is_integer(key), do: value

    %{
      queries: for({:query, query} <- events, do: query),
      plans: for({:plan, plan} <- events, do: plan),
      discoveries: for({:discover, discovery} <- events, do: discovery)
    }
  end

  defp query(metadata) do
    sql = IO.iodata_to_binary(metadata.query)

    source =
      case {metadata[:source], Regex.run(~r/FROM "([a-z_]+)"/, sql)} do
        {source, _match} when is_binary(source) -> source
        {nil, [_, source]} -> source
        _other -> "other"
      end

    Map.merge(
      %{
        sql: sql,
        params: metadata[:params] || [],
        source: source,
        select?: String.starts_with?(sql, ["SELECT", "WITH"]),
        lock?: Regex.match?(@lock_pattern, sql)
      },
      result(metadata[:result])
    )
  end

  defp result({:ok, %{rows: rows, columns: columns}}) when is_list(rows) or is_nil(rows) do
    rows = rows || []

    %{
      columns: columns || [],
      rows: rows,
      row_count: length(rows),
      result_bytes: :erlang.external_size(rows),
      error?: false,
      unmeasured?: false
    }
  end

  defp result(result) do
    %{
      columns: [],
      rows: [],
      row_count: 0,
      result_bytes: 0,
      error?: match?({:error, _}, result),
      unmeasured?: true
    }
  end

  defp ids(%{columns: columns, rows: rows}) do
    case Enum.find_index(columns, &(&1 == "id")) do
      nil -> []
      index -> Enum.map(rows, &Enum.at(&1, index))
    end
  end
end
