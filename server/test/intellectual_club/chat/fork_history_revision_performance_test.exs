defmodule IntellectualClub.Chat.ForkHistoryRevisionPerformanceTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ForkHistoryRevision

  @moduletag :fork_revision_performance
  @moduletag timeout: 180_000
  @sql_event [:intellectual_club, :repo, :query]
  @markers ~w(FORK_REVISION_TEXT_PAYLOAD_SENTINEL FORK_REVISION_JSON_PAYLOAD_SENTINEL FORK_REVISION_RAW_REQUEST_SENTINEL FORK_REVISION_RAW_RESPONSE_SENTINEL)
  @payload_columns ~w(content_text content_json raw_request raw_response)
  @task "Inspect the anchored source only."

  # Fixed before measurement: one linked source, regardless of branch length or payload size.
  @max_queries 12
  @max_rows 16
  @max_bytes 16_384
  @query_margin 2
  @row_margin 2
  @byte_margin 2_048

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor}
  end

  test "measurement sees driver rows and payloads, including queries in caller tasks", %{
    actor: actor
  } do
    fixture = history!(actor, 2)
    first = hd(fixture.entries)
    supervisor = start_supervised!(Task.Supervisor)

    {_, stats} =
      measure(fn ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          Ash.get!(ChatMessageContent, first.content.id, actor: actor, authorize?: true)

          Ash.get!(ChatMessageStep, first.step.id,
            actor: actor,
            authorize?: true,
            load: [:raw_request, :raw_response]
          )
        end)
        |> Task.await(:infinity)
      end)

    assert stats.queries >= 2
    assert stats.returned_rows >= 2
    assert stats.approx_row_bytes > 0
    assert Enum.sort(stats.payload_markers) == Enum.sort(@markers)
    assert Enum.any?(stats.events, &("content_text" in &1.columns))
    assert_raise ExUnit.AssertionError, fn -> assert_metadata_only!(stats) end
  end

  test "N=10 and N=100 transfer bounded metadata with no per-message SQL", %{actor: actor} do
    measurements =
      for count <- [10, 100] do
        fixture = history!(actor, count)
        {token, stats} = measure(fn -> ForkHistoryRevision.revision(fixture.child, actor) end)
        assert_token!(token)
        assert_metadata_only!(stats)

        {from_id, id_stats} =
          measure(fn -> ForkHistoryRevision.revision(fixture.child.id, actor) end)

        assert from_id == token
        assert_metadata_only!(id_stats)
        assert_similar!(stats, id_stats)
        stats
      end

    [small, large] = measurements
    assert_similar!(small, large)
  end

  test "N=100 remains metadata-only when text, JSON and raw payloads grow to megabytes", %{
    actor: actor
  } do
    small_fixture = history!(actor, 100)
    {before, small} = measure(fn -> ForkHistoryRevision.revision(small_fixture.child, actor) end)
    assert_token!(before)
    assert_metadata_only!(small)

    fixture = inflate!(small_fixture, actor, 32_768)
    first = hd(fixture.entries)
    content = Ash.get!(ChatMessageContent, first.content.id, actor: actor, authorize?: true)

    step =
      Ash.get!(ChatMessageStep, first.step.id,
        actor: actor,
        authorize?: true,
        load: [:raw_request, :raw_response]
      )

    # Positive controls are deliberately outside the measured operation.
    assert byte_size(content.content_text) == 32_768
    assert byte_size(content.content_json["payload"]) == 32_768
    assert byte_size(step.raw_request["payload"]) == 32_768
    assert byte_size(step.raw_response["payload"]) == 32_768
    assert content.content_text =~ Enum.at(@markers, 0)
    assert content.content_json["payload"] =~ Enum.at(@markers, 1)
    assert step.raw_request["payload"] =~ Enum.at(@markers, 2)
    assert step.raw_response["payload"] =~ Enum.at(@markers, 3)

    {after_token, large} = measure(fn -> ForkHistoryRevision.revision(fixture.child, actor) end)
    assert_token!(after_token)
    refute after_token == before
    assert_metadata_only!(large)
    assert_similar!(small, large)
  end

  test "non-linked and unauthorized supplied structs do not trigger prefix loading", %{
    actor: actor
  } do
    fixture = history!(actor, 10)
    %{user: other} = user_fixture()

    {nil, plain} = measure(fn -> ForkHistoryRevision.revision(fixture.parent, actor) end)
    assert_metadata_only!(plain)

    {denied, stats} = measure(fn -> ForkHistoryRevision.revision(fixture.child, other) end)
    assert_token!(denied)
    assert_metadata_only!(stats)
    assert denied == ForkHistoryRevision.revision(fixture.child.id, other)
    refute denied == ForkHistoryRevision.revision(fixture.child, actor)
  end

  # Public helpers are reused only by the explicitly invoked asset benchmark.
  @doc false
  def history!(actor, count, payload_bytes \\ 128) when count >= 2 do
    parent = create!(Chat, :create_empty, %{}, actor)

    {entries, _last_id} =
      Enum.map_reduce(1..count, nil, fn index, parent_id ->
        message =
          create!(
            ChatMessage,
            :add_message,
            %{chat_id: parent.id, parent_id: parent_id, role: :assistant},
            actor
          )

        step =
          create!(
            ChatMessageStep,
            :create,
            %{
              chat_message_id: message.id,
              sequence: 1,
              response_final: true,
              raw_request: raw_payload(payload_bytes, 2),
              raw_response: raw_payload(payload_bytes, 3)
            },
            actor
          )

        item =
          create!(
            ChatMessageItem,
            :create,
            %{
              chat_message_step_id: step.id,
              sequence: 1,
              type: if(index == count, do: :tool_call, else: :answer)
            },
            actor
          )

        content =
          create!(
            ChatMessageContent,
            :create,
            Map.merge(
              content_payload(payload_bytes, index == count),
              %{chat_message_item_id: item.id, sequence: 1}
            ),
            actor
          )

        {%{message: message, step: step, item: item, content: content}, message.id}
      end)

    anchor = List.last(entries)

    child =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{
          parent_chat_id: parent.id,
          parent_message_id: anchor.message.id,
          parent_tool_call_item_id: anchor.item.id,
          parent_relation_kind: :fork,
          subagent: true
        },
        actor: actor,
        authorize?: true
      )
      |> Ash.Changeset.force_change_attributes(%{
        fork_source_step_id: anchor.step.id,
        fork_task: @task
      })
      |> Ash.create!(actor: actor, authorize?: true)

    %{parent: parent, child: child, entries: entries, count: count, payload_bytes: payload_bytes}
  end

  @doc false
  def inflate!(fixture, actor, payload_bytes) do
    entries =
      Enum.map(fixture.entries, fn entry ->
        content =
          update!(
            entry.content,
            content_payload(payload_bytes, entry.item.type == :tool_call),
            actor
          )

        step =
          update!(
            entry.step,
            %{
              raw_request: raw_payload(payload_bytes, 2),
              raw_response: raw_payload(payload_bytes, 3)
            },
            actor
          )

        %{entry | content: content, step: step}
      end)

    %{fixture | entries: entries, payload_bytes: payload_bytes}
  end

  defp content_payload(bytes, boundary?) do
    json = %{"payload" => payload(bytes, 1)}

    json =
      if boundary?,
        do:
          Map.merge(json, %{
            "name" => "agent__fork",
            "call_id" => "performance-fork",
            "arguments" => %{"task" => @task}
          }),
        else: json

    %{
      kind: if(boundary?, do: :opaque, else: :text),
      content_text: payload(bytes, 0),
      content_json: json
    }
  end

  defp raw_payload(bytes, marker_index), do: %{"payload" => payload(bytes, marker_index)}

  defp payload(bytes, marker_index) do
    marker = Enum.at(@markers, marker_index)
    marker <> String.duplicate("x", bytes - byte_size(marker))
  end

  defp create!(resource, action, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(action, attrs, actor: actor, authorize?: true)
    |> Ash.create!(actor: actor, authorize?: true)
  end

  defp update!(record, attrs, actor) do
    record
    |> Ash.Changeset.for_update(:update, attrs, actor: actor, authorize?: true)
    |> Ash.update!(actor: actor, authorize?: true)
  end

  @doc false
  def assert_token!(token), do: assert(is_binary(token) and byte_size(token) in 1..128)

  @doc false
  def assert_metadata_only!(stats) do
    message = inspect(summary(stats), pretty: true)
    assert stats.queries in 1..@max_queries, message
    assert stats.returned_rows <= @max_rows, message
    assert stats.approx_row_bytes <= @max_bytes, message
    assert stats.query_errors == 0, message
    assert stats.unmeasured_results == 0, message
    assert stats.payload_markers == [], message

    # Inspect actual Postgrex result columns, not SQL text that may mention payload
    # fields inside a server-side boundary predicate without returning those fields.
    for event <- stats.events do
      refute Enum.any?(event.columns, &(&1 in @payload_columns)), inspect(event)
      # Moving full-payload hashing into PostgreSQL would not be metadata-only either.
      refute Regex.match?(~r/"(?:content_text|raw_request|raw_response)"/, event.sql), event.sql
      refute Regex.match?(~r/"content_json"(?!\s*->>\s*'placement')/, event.sql), event.sql

      if String.starts_with?(event.sql, "WITH RECURSIVE") do
        # Keep authorization and placement work out of per-history-row loops.
        for name <-
              ~w(revision_messages revision_source_steps revision_all_items revision_source_contents revision_placements) do
          assert event.sql =~ ~s("#{name}" AS MATERIALIZED), event.sql
        end

        assert length(Regex.scan(~r/\) IS TRUE/, event.sql)) == 3, event.sql
        assert event.sql =~ "JOIN LATERAL", event.sql
      end
    end
  end

  @doc false
  def assert_similar!(left, right) do
    message = inspect([summary(left), summary(right)], pretty: true)
    assert abs(right.queries - left.queries) <= @query_margin, message
    assert abs(right.returned_rows - left.returned_rows) <= @row_margin, message
    assert abs(right.approx_row_bytes - left.approx_row_bytes) <= @byte_margin, message
  end

  @doc false
  def measure(operation) do
    table = :ets.new(__MODULE__, [:ordered_set, :public])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, @sql_event, &__MODULE__.handle_query/4, %{
        root: self(),
        table: table
      })

    started = System.monotonic_time()

    try do
      result = operation.()
      elapsed = System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)
      :telemetry.detach(handler)
      events = :ets.tab2list(table) |> Enum.map(&elem(&1, 1))

      {result,
       %{
         elapsed_ms: elapsed / 1000,
         queries: length(events),
         returned_rows: Enum.sum(Enum.map(events, & &1.returned_rows)),
         approx_row_bytes: Enum.sum(Enum.map(events, & &1.approx_row_bytes)),
         query_ms: Enum.sum(Enum.map(events, & &1.query_ms)),
         decode_ms: Enum.sum(Enum.map(events, & &1.decode_ms)),
         queue_ms: Enum.sum(Enum.map(events, & &1.queue_ms)),
         query_errors: Enum.count(events, & &1.error?),
         unmeasured_results: Enum.count(events, & &1.unmeasured?),
         payload_markers:
           events |> Enum.flat_map(& &1.payload_markers) |> Enum.uniq() |> Enum.sort(),
         events: events
       }}
    after
      :telemetry.detach(handler)
      :ets.delete(table)
    end
  end

  @doc false
  def handle_query(_event, measurements, metadata, %{root: root, table: table}) do
    # Async Ash queries retain the initiating process through the Task caller chain.
    if self() == root or root in Process.get(:"$callers", []) or metadata[:caller] == root do
      sql = IO.iodata_to_binary(metadata.query)
      stats = result_stats(metadata[:result])

      event =
        Map.merge(stats, %{
          sql: sql,
          query_ms: milliseconds(measurements[:query_time]),
          decode_ms: milliseconds(measurements[:decode_time]),
          queue_ms: milliseconds(measurements[:queue_time]),
          sql_sha256: Base.encode16(:crypto.hash(:sha256, sql), case: :lower)
        })

      :ets.insert(table, {System.unique_integer([:positive, :monotonic]), event})
    end
  end

  defp milliseconds(nil), do: 0.0

  defp milliseconds(native),
    do: System.convert_time_unit(native, :native, :microsecond) / 1000

  defp result_stats({:ok, %{rows: rows, columns: columns}}) when is_list(rows) or is_nil(rows) do
    rows = rows || []
    encoded = :erlang.term_to_binary(rows)

    %{
      returned_rows: length(rows),
      approx_row_bytes: byte_size(encoded),
      columns: columns || [],
      payload_markers: Enum.filter(@markers, &(:binary.match(encoded, &1) != :nomatch)),
      error?: false,
      unmeasured?: false
    }
  end

  defp result_stats(result) do
    %{
      returned_rows: 0,
      approx_row_bytes: 0,
      columns: [],
      payload_markers: [],
      error?: match?({:error, _}, result),
      unmeasured?: true
    }
  end

  @doc false
  def summary(stats), do: Map.delete(stats, :events)
end
