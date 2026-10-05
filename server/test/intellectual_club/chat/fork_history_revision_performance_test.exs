defmodule IntellectualClub.Chat.ForkHistoryRevisionPerformanceTest do
  # Whitebox: SQL round trips, returned columns and transferred bytes of
  # ForkHistoryRevision.revision/2. An idle probe must read bounded metadata only,
  # never history text, JSON or raw provider payloads, whatever the history size.
  use IntellectualClub.DataCase, async: false

  @moduletag :whitebox

  import IntellectualClub.Chat.ForkFixtures

  alias IntellectualClub.Chat.{ChatMessageContent, ChatMessageStep, ForkHistoryRevision}
  alias IntellectualClub.SqlCapture

  @markers ~w(FORK_REVISION_TEXT_PAYLOAD_SENTINEL FORK_REVISION_JSON_PAYLOAD_SENTINEL FORK_REVISION_RAW_REQUEST_SENTINEL FORK_REVISION_RAW_RESPONSE_SENTINEL)
  @payload_columns ~w(content_text content_json raw_request raw_response)
  @fences ~w(revision_messages revision_source_steps revision_all_items revision_source_contents revision_placements)
  @task "Inspect the anchored source only."

  # Fixed before measurement: one linked source, regardless of history length or payload size.
  @max_queries 12
  @max_rows 16
  @max_bytes 16_384
  @byte_margin 2_048

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor}
  end

  test "measurement sees returned payloads, including queries in caller tasks", %{actor: actor} do
    first = hd(history!(actor, 2).entries)
    supervisor = start_supervised!(Task.Supervisor)

    {_, capture} =
      SqlCapture.measure(fn ->
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

    assert length(capture.queries) >= 2
    assert total(capture, :row_count) >= 2
    assert total(capture, :result_bytes) > 0
    assert Enum.all?(@markers, &SqlCapture.returned?(capture, &1))
    assert Enum.any?(capture.queries, &("content_text" in &1.columns))
    assert_raise ExUnit.AssertionError, fn -> assert_metadata_only!(capture) end
  end

  test "round trips and transferred bytes do not grow with the history length", %{
    actor: actor
  } do
    fixture = history!(actor, 3)
    {token, short} = measure(fixture.child, actor)
    assert_token!(token)
    assert_metadata_only!(short)
    assert length(short.queries) == 3
    assert [%{rows: [[true, _digest]]}] = aggregates(short)

    {from_id, by_id} = measure(fixture.child.id, actor)
    assert from_id == token
    assert cost(by_id) == cost(short)

    # Grow the same source branch from 3 to 30 messages above the boundary.
    top =
      Enum.reduce(1..27, nil, fn number, parent_id ->
        message = create_message!(actor, fixture.parent, %{role: :user, parent_id: parent_id})
        step = create_step!(actor, message, response_final: true)
        create_text_item!(actor, step, "Ancestor #{number}", type: :input)
        message.id
      end)

    reparent_message!(actor, hd(fixture.entries).message, top)
    {grown, long} = measure(fixture.child, actor)
    refute grown == token
    assert_metadata_only!(long)
    assert cost(long) == cost(short)
  end

  test "megabytes of text, JSON and raw payloads are never transferred", %{actor: actor} do
    {light_token, light} = measure(history!(actor, 30).child, actor)
    assert_metadata_only!(light)

    heavy = history!(actor, 30, 32_768)
    first = hd(heavy.entries)
    content = Ash.get!(ChatMessageContent, first.content.id, actor: actor, authorize?: true)

    step =
      Ash.get!(ChatMessageStep, first.step.id,
        actor: actor,
        authorize?: true,
        load: [:raw_request, :raw_response]
      )

    # Positive controls are deliberately outside the measured operation.
    for {payload, marker} <- [
          {content.content_text, Enum.at(@markers, 0)},
          {content.content_json["payload"], Enum.at(@markers, 1)},
          {step.raw_request["payload"], Enum.at(@markers, 2)},
          {step.raw_response["payload"], Enum.at(@markers, 3)}
        ] do
      assert byte_size(payload) == 32_768
      assert payload =~ marker
    end

    {heavy_token, large} = measure(heavy.child, actor)
    assert_token!(heavy_token)
    refute heavy_token == light_token
    assert_metadata_only!(large)
    assert Enum.map(large.queries, & &1.row_count) == Enum.map(light.queries, & &1.row_count)

    assert abs(total(large, :result_bytes) - total(light, :result_bytes)) <= @byte_margin,
           inspect([summary(light), summary(large)], pretty: true)
  end

  test "non-linked and unauthorized chats never reach the source summary", %{actor: actor} do
    fixture = history!(actor, 3)
    %{user: other} = user_fixture()

    {nil, plain} = measure(fixture.parent, actor)
    assert_metadata_only!(plain)
    assert aggregates(plain) == []

    {denied, unauthorized} = measure(fixture.child, other)
    assert_token!(denied)
    assert_metadata_only!(unauthorized)
    assert aggregates(unauthorized) == []
    assert denied == ForkHistoryRevision.revision(fixture.child.id, other)
    refute denied == ForkHistoryRevision.revision(fixture.child, actor)
  end

  test "the walk summarizes at most 32 linked sources", %{actor: actor} do
    deepest = actor |> create_fork_chain!(33) |> List.last()
    {token, capture} = measure(deepest, actor)
    assert_token!(token)
    assert length(aggregates(capture)) == 32
  end

  # A linear branch of `count` assistant messages whose last one holds the fork
  # call, with text, JSON and raw payloads of `payload_bytes` each, and a child.
  defp history!(actor, count, payload_bytes \\ 128) do
    parent = create_empty_chat!(actor)

    {entries, _last_id} =
      Enum.map_reduce(1..count, nil, fn index, parent_id ->
        boundary? = index == count
        message = create_message!(actor, parent, %{parent_id: parent_id})

        step =
          create_step!(actor, message,
            response_final: true,
            raw_request: %{"payload" => payload(payload_bytes, 2)},
            raw_response: %{"payload" => payload(payload_bytes, 3)}
          )

        item = create_item!(actor, step, type: if(boundary?, do: :tool_call, else: :answer))
        content = create_content!(actor, item, content_payload(payload_bytes, boundary?))
        {%{message: message, step: step, item: item, content: content}, message.id}
      end)

    anchor = List.last(entries)
    anchor = %{chat: parent, message: anchor.message, step: anchor.step, item: anchor.item}

    %{
      parent: parent,
      child: create_linked_chat!(actor, anchor, fork_task: @task),
      entries: entries
    }
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

  defp payload(bytes, marker_index) do
    marker = Enum.at(@markers, marker_index)
    marker <> String.duplicate("x", bytes - byte_size(marker))
  end

  defp measure(chat, actor),
    do: SqlCapture.measure(fn -> ForkHistoryRevision.revision(chat, actor) end)

  defp assert_token!(token), do: assert(is_binary(token) and byte_size(token) in 1..128)

  defp assert_metadata_only!(capture) do
    message = inspect(summary(capture), pretty: true)
    assert length(capture.queries) in 1..@max_queries, message
    assert total(capture, :row_count) <= @max_rows, message
    assert total(capture, :result_bytes) <= @max_bytes, message
    refute Enum.any?(capture.queries, &(&1.error? or &1.unmeasured?)), message
    refute Enum.any?(@markers, &SqlCapture.returned?(capture, &1)), message

    # Inspect the actual Postgrex result columns, not only SQL text that may mention
    # payload fields inside a server-side predicate without returning them.
    for query <- capture.queries do
      assert query.row_count <= 1, query.sql
      assert query.result_bytes < 4096, query.sql
      refute Enum.any?(query.columns, &(&1 in @payload_columns)), query.sql
      # Moving full-payload hashing into PostgreSQL would not be metadata-only either.
      refute Regex.match?(~r/"(?:content_text|raw_request|raw_response)"/, query.sql), query.sql
      refute Regex.match?(~r/"content_json"(?!\s*->>\s*'placement')/, query.sql), query.sql
    end

    for aggregate <- aggregates(capture) do
      assert aggregate.columns == ["available", "digest"]
      assert aggregate.result_bytes < 1024
      assert aggregate.sql =~ "UNION ("
      refute aggregate.sql =~ "UNION ALL"
      assert aggregate.sql =~ "->> 'placement'"
      # Keep authorization and placement work out of per-history-row loops.
      for name <- @fences, do: assert(aggregate.sql =~ ~s("#{name}" AS MATERIALIZED))
      assert length(Regex.scan(~r/\) IS TRUE/, aggregate.sql)) == 3
      assert aggregate.sql =~ "JOIN LATERAL"
    end
  end

  defp aggregates(capture),
    do: Enum.filter(capture.queries, &String.starts_with?(&1.sql, "WITH RECURSIVE"))

  defp cost(capture), do: Enum.map(capture.queries, &{&1.row_count, &1.result_bytes})

  defp total(capture, key), do: capture.queries |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()

  defp summary(capture),
    do: Enum.map(capture.queries, &Map.take(&1, [:source, :columns, :row_count, :result_bytes]))
end
