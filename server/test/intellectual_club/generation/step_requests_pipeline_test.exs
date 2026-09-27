defmodule IntellectualClub.Generation.StepRequestsPipelineTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.StepRequestsFixtures

  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Generation.{Persistence, StepRequests}
  alias IntellectualClub.Generation.StepRequests.{Codec, Reader}

  @traced [{Codec, :hash_iodata, 1}, {Codec, :normalize!, 1}, {Jsonpatch, :diff, 3}]

  test "logical preparation computes each document once and publication does no codec work" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)
    source = compact_request(1)
    first = encoded_request_step!(message, 1, source, actor)

    {{changeset, snapshot}, calls} =
      trace_calls(fn ->
        StepRequests.prepare_create!(
          %{chat_message_id: message.id, sequence: 2},
          compact_request(2),
          actor: actor,
          previous_step: first,
          previous_request: source
        )
      end)

    assert calls[{Codec, :hash_iodata, 1}] == 2
    refute Map.has_key?(calls, {Codec, :normalize!, 1})
    assert calls[{Jsonpatch, :diff, 3}] == 1

    {second, calls} = trace_calls(fn -> Ash.create!(changeset, actor: actor) end)
    assert calls == %{}
    assert second.request_hash == snapshot.hash
    assert second.request_mode == :patch
  end

  test "unchanged retry preparation reuses one document and avoids diff" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)
    request = compact_request(1)
    first = encoded_request_step!(message, 1, request, actor)

    {{changeset, _snapshot}, calls} =
      trace_calls(fn ->
        StepRequests.prepare_create!(%{chat_message_id: message.id, sequence: 2}, request,
          actor: actor,
          previous_step: first,
          previous_request: request
        )
      end)

    assert calls[{Codec, :hash_iodata, 1}] == 1
    refute Map.has_key?(calls, {Codec, :normalize!, 1})
    refute Map.has_key?(calls, {Jsonpatch, :diff, 3})
    second = Ash.create!(changeset, actor: actor)
    assert stored_request_step!(second.id, actor).request_patch == []
  end

  test "unchanged legacy bases reuse the independently reconstructed snapshot" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)
    request = compact_request(1)
    first = historical_request_step!(message, 1, request, actor)

    {{changeset, _snapshot}, calls} =
      trace_calls(fn ->
        StepRequests.prepare_create!(%{chat_message_id: message.id, sequence: 2}, request,
          actor: actor,
          previous_step: first,
          previous_request: request
        )
      end)

    assert calls[{Codec, :hash_iodata, 1}] == 1
    refute Map.has_key?(calls, {Jsonpatch, :diff, 3})
    second = Ash.create!(changeset, actor: actor)
    assert stored_request_step!(second.id, actor).request_patch == []
  end

  test "reader hashes each reconstructed document once instead of hashing the next base again" do
    {rows, _previous} =
      Enum.map_reduce(1..12, nil, fn sequence, previous ->
        attrs =
          Codec.create_attributes(compact_request(sequence),
            sequence: sequence,
            previous_step: previous,
            previous_request: if(previous, do: compact_request(sequence - 1))
          )

        row = Map.merge(%{id: sequence, chat_message_id: 1, sequence: sequence}, attrs)
        {row, row}
      end)

    {requests, calls} = trace_calls(fn -> Reader.decode_rows!(Enum.reverse(rows)) end)
    assert map_size(requests) == 12
    assert calls[{Codec, :hash_iodata, 1}] == 12

    first = hd(rows)

    {unchanged, _previous} =
      Enum.map_reduce(2..12, first, fn sequence, previous ->
        attrs =
          Codec.create_attributes(compact_request(1),
            sequence: sequence,
            previous_step: previous,
            previous_request: compact_request(1)
          )

        row = Map.merge(%{id: sequence, chat_message_id: 1, sequence: sequence}, attrs)
        {row, row}
      end)

    {_requests, calls} = trace_calls(fn -> Reader.decode_rows!([first | unchanged]) end)
    assert calls[{Codec, :hash_iodata, 1}] == 1
  end

  test "persistence preserves the authoritative snapshot and rejects a full-write runtime mismatch" do
    %{user: actor} = user_fixture()
    message = request_message!(actor)
    source = compact_request(1)
    first = Persistence.create_request_step!(message, 1, source)
    assert first.request_snapshot.request == first.request
    assert first.request_snapshot.hash == first.step.request_hash

    assert_raise Ash.Error.Invalid, ~r/runtime_request_mismatch/, fn ->
      Persistence.persist_retry_error_and_start_next_step!(
        message.id,
        first.step.id,
        source,
        "retry",
        previous_request: compact_request(999),
        force_full: true
      )
    end

    assert Ash.get!(ChatMessageStep, first.step.id, actor: actor).status == :waiting_provider

    assert [first.step.id] ==
             ChatMessageStep
             |> Ash.Query.select([:id])
             |> Ash.read!(actor: actor)
             |> Enum.map(& &1.id)
  end

  defp trace_calls(fun) do
    child_id = make_ref()
    tracer = start_supervised!({Task, fn -> collect_calls(%{}) end}, id: child_id)
    Enum.each(@traced, fn {module, _, _} -> Code.ensure_loaded!(module) end)
    Enum.each(@traced, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call, :arity, {:tracer, tracer}])

    try do
      result = fun.()
      :erlang.trace(self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^ref}
      send(tracer, {:counts, self()})
      assert_receive {:counts, calls}
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(@traced, &:erlang.trace_pattern(&1, false, [:local]))
      stop_supervised!(child_id)
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _pid, :call, mfa} ->
        collect_calls(Map.update(calls, mfa, 1, &(&1 + 1)))

      {:counts, caller} ->
        send(caller, {:counts, calls})
        collect_calls(calls)
    end
  end
end
