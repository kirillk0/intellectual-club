defmodule IntellectualClub.Generation.StepRequestsStorageTest do
  @moduledoc """
  Persistence layer of step requests on `ChatMessageStep`: reads and chain
  reconstruction, actor isolation, validation of logical and physical
  encodings on create, immutability and private physical rewrites.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.SqlCapture
  import IntellectualClub.StepRequestsFixtures

  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Generation.StepRequests.{Codec, Error}

  describe "reads and reconstruction" do
    test "historical unselected raw requests are fetched, never mistaken for empty objects" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      request = compact_request(1)
      step = historical_request_step!(message, 1, request, actor)

      projected =
        ChatMessageStep |> Ash.Query.select([:id, :sequence]) |> Ash.read_one!(actor: actor)

      refute Ash.Resource.selected?(projected, :raw_request)

      assert StepRequests.request_for_step!(step.id, actor: actor) == request
      assert StepRequests.requests_for_steps!([projected], actor: actor) == %{step.id => request}
      assert stored_request_step!(step.id, actor).request_hash == nil

      forged = %{projected | raw_request: %{"forged" => true}}
      assert StepRequests.requests_for_steps!([forged], actor: actor) == %{step.id => request}
    end

    test "large JSON integers and expanded float exponents survive JSONB full and patch reads" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)

      request = %{
        "positive" => Integer.pow(10, 80) + 123,
        "negative" => -(Integer.pow(10, 80) + 123),
        "exponent" => 1.0e80,
        "wide" => Integer.pow(10, 400) + 123
      }

      first = encoded_request_step!(message, 1, request, actor)
      restored = StepRequests.request_for_step!(first.id, actor: actor)
      expected_jsonb = Map.put(request, "exponent", Integer.pow(10, 80))
      assert restored === expected_jsonb
      assert Codec.hash(restored) == first.request_hash

      target = Map.put(request, "next", true)

      second =
        encoded_request_step!(message, 2, target, actor,
          previous_step: first,
          previous_request: request
        )

      assert second.request_mode == :patch

      assert StepRequests.request_for_step!(second.id, actor: actor) ===
               Map.put(expected_jsonb, "next", true)
    end

    test "JSONB numeric reserialization does not invalidate full or patch hashes" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)

      request =
        Map.merge(compact_request(1), %{"large" => 1.0e30, "small" => 1.0e-20, "zero" => -0.0})

      first = encoded_request_step!(message, 1, request, actor)
      decoded = StepRequests.request_for_step!(first.id, actor: actor)
      assert Codec.json!(decoded) == Codec.json!(request)
      target = Map.put(decoded, "index", 2)

      second =
        encoded_request_step!(message, 2, target, actor,
          previous_step: first,
          previous_request: decoded
        )

      assert second.request_mode == :patch

      assert Codec.json!(StepRequests.request_for_step!(second.id, actor: actor)) ==
               Codec.json!(target)
    end

    test "known runtime bases retain JSONB numeric equivalence without reading the raw predecessor" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)

      source =
        Map.merge(compact_request(1), %{"large" => 1.0e30, "small" => 1.0e-20, "zero" => -0.0})

      first = encoded_request_step!(message, 1, source, actor)
      target = Map.put(source, "index", 2)

      attrs =
        StepRequests.create_attributes(target,
          sequence: 2,
          previous_step: first,
          previous_request: source
        )

      assert attrs.request_mode == :patch

      {{:ok, second}, stats} =
        measure(fn ->
          create_encoding(message.id, 2, attrs, actor, private_arguments: %{request_base: source})
        end)

      assert stats.raw_reads == 0
      assert stats.shared_locks >= 1

      assert Codec.json!(StepRequests.request_for_step!(second.id, actor: actor)) ==
               Codec.json!(target)
    end

    @tag :whitebox
    test "batch reconstruction uses bounded queries and fetches each ancestry window once" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)

      {steps, _previous} =
        Enum.map_reduce(1..40, nil, fn sequence, previous ->
          step =
            encoded_request_step!(message, sequence, compact_request(sequence), actor,
              previous_step: previous,
              previous_request: if(previous, do: compact_request(sequence - 1))
            )

          {step, step}
        end)

      {requests, stats} = measure(fn -> StepRequests.requests_for_steps!(steps, actor: actor) end)
      assert map_size(requests) == 40
      assert Enum.all?(steps, &(requests[&1.id] == compact_request(&1.sequence)))
      assert stats.queries <= 4
      assert stats.rows <= 80

      {request, stats} =
        measure(fn -> StepRequests.request_for_step!(List.last(steps).id, actor: actor) end)

      assert request == compact_request(40)
      assert stats.queries <= 4
      assert stats.rows <= 34
    end
  end

  describe "actor isolation" do
    test "read, create and physical rewrites preserve actor isolation even with a supplied resource" do
      %{user: owner} = user_fixture()
      %{user: stranger} = user_fixture()
      message = request_message!(owner)
      request = compact_request(1)
      step = historical_request_step!(message, 1, request, owner)

      assert {:error, _error} = StepRequests.request_for_step(step.id, actor: stranger)

      assert {:error, _error} =
               StepRequests.request_for_step(step.id, actor: stranger, authorize?: false)

      assert_raise Error, fn -> StepRequests.requests_for_steps!([step], actor: stranger) end
      assert_raise Error, fn -> StepRequests.request_for_step!(step.id, []) end

      assert {:error, _error} =
               ChatMessageStep
               |> Ash.Changeset.for_create(
                 :create,
                 %{chat_message_id: message.id, sequence: 2, raw_request: request},
                 actor: stranger
               )
               |> Ash.create(actor: stranger)

      assert {:error, _error} = rewrite(step, StepRequests.create_attributes(request), stranger)
      assert stored_request_step!(step.id, owner).request_hash == nil
    end

    test "shared read access is retained, but physical rewrite and backfill stay owner-only" do
      %{user: owner} = user_fixture()
      %{user: recipient} = user_fixture()
      message = shared_request_message!(owner, recipient)
      request = compact_request(1)
      first = historical_request_step!(message, 1, request, owner)

      second =
        encoded_request_step!(message, 2, compact_request(2), owner,
          previous_step: first,
          previous_request: request
        )

      assert second.request_mode == :patch
      assert StepRequests.request_for_step!(second.id, actor: recipient) == compact_request(2)
      assert {:error, _error} = rewrite(first, StepRequests.create_attributes(request), recipient)

      assert {:ok, %{scanned_messages: 0}} =
               StepRequests.backfill_batch(actor: recipient, message_limit: 10, dry_run: false)

      assert stored_request_step!(first.id, owner).request_hash == nil
    end
  end

  describe "creation validation" do
    test "creation validates patch shape, same-message predecessor, base hash and result hash" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      other_message = request_message!(actor)
      request = compact_request(1)
      first = historical_request_step!(message, 1, request, actor)

      attrs =
        StepRequests.create_attributes(compact_request(2),
          sequence: 2,
          previous_step: first,
          previous_request: request
        )

      assert attrs.request_mode == :patch

      invalid_attrs = [
        Map.put(attrs, :request_base_hash, String.duplicate("0", 64)),
        Map.put(attrs, :request_hash, String.duplicate("0", 64)),
        Map.put(attrs, :request_base_sequence, 3),
        Map.put(attrs, :request_checkpoint_distance, 2),
        Map.put(attrs, :raw_request, %{"not" => "empty"}),
        Map.put(attrs, :request_patch, [%{"op" => "remove", "path" => "/missing"}])
      ]

      for invalid <- invalid_attrs do
        assert {:error, _error} = create_encoding(message.id, 2, invalid, actor)
      end

      assert {:error, _error} = create_encoding(message.id, 1, attrs, actor)
      assert {:error, _error} = create_encoding(other_message.id, 2, attrs, actor)
      assert {:ok, second} = create_encoding(message.id, 2, attrs, actor)
      assert StepRequests.request_for_step!(second.id, actor: actor) == compact_request(2)
    end

    test "a supplied runtime base is hash-checked using predecessor metadata without raw reads" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      request = compact_request(1)
      first = encoded_request_step!(message, 1, request, actor)
      target = compact_request(2)

      attrs =
        StepRequests.create_attributes(target,
          sequence: 2,
          previous_step: first,
          previous_request: request
        )

      assert {:error, _} =
               create_encoding(message.id, 2, attrs, actor,
                 private_arguments: %{request_base: compact_request(999)}
               )

      {{:ok, second}, stats} =
        measure(fn ->
          create_encoding(message.id, 2, attrs, actor,
            private_arguments: %{request_base: request}
          )
        end)

      assert stats.raw_reads == 0
      assert stats.shared_locks >= 1
      assert second.request_mode == :patch
      assert StepRequests.request_for_step!(second.id, actor: actor) == target
    end

    test "runtime base claims cannot spoof the locked persisted hash, result, distance or actor" do
      %{user: actor} = user_fixture()
      %{user: stranger} = user_fixture()
      message = request_message!(actor)
      source = compact_request(1)
      first = encoded_request_step!(message, 1, source, actor)

      attrs =
        StepRequests.create_attributes(compact_request(2),
          sequence: 2,
          previous_step: first,
          previous_request: source
        )

      forged = compact_request(999)
      forged_previous = %{first | request_hash: Codec.hash(forged)}

      forged_attrs =
        StepRequests.create_attributes(compact_request(1000),
          sequence: 2,
          previous_step: forged_previous,
          previous_request: forged
        )

      assert forged_attrs.request_mode == :patch

      for {invalid, base} <- [
            {forged_attrs, forged},
            {%{attrs | request_hash: String.duplicate("0", 64)}, source},
            {%{attrs | request_checkpoint_distance: 2}, source},
            {%{attrs | request_base_sequence: 3}, source}
          ] do
        assert {:error, _} =
                 create_encoding(message.id, 2, invalid, actor,
                   private_arguments: %{request_base: base}
                 )
      end

      assert {:error, _} =
               create_encoding(message.id, 2, attrs, stranger,
                 private_arguments: %{request_base: source}
               )

      assert {:ok, second} =
               create_encoding(message.id, 2, attrs, actor,
                 private_arguments: %{request_base: source}
               )

      assert StepRequests.request_for_step!(second.id, actor: actor) == compact_request(2)
    end

    test "legacy nil-hash predecessors resolve from storage even when a runtime base is provided" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      source = compact_request(1)
      first = historical_request_step!(message, 1, source, actor)
      assert first.request_hash == nil

      attrs =
        StepRequests.create_attributes(compact_request(2),
          sequence: 2,
          previous_step: first,
          previous_request: source
        )

      {{:ok, second}, stats} =
        measure(fn ->
          create_encoding(message.id, 2, attrs, actor,
            private_arguments: %{request_base: compact_request(999)}
          )
        end)

      assert stats.raw_reads > 0
      assert StepRequests.request_for_step!(second.id, actor: actor) == compact_request(2)
    end

    test "logical creation prepares normalized snapshots before locks and publishes without raw base reads" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      source = compact_request(1)
      first = encoded_request_step!(message, 1, source, actor)
      request = Map.put(source, :added, %{value: 1.0})

      {{changeset, snapshot}, preparation} =
        measure(fn ->
          StepRequests.prepare_create!(%{chat_message_id: message.id, sequence: 2}, request,
            actor: actor,
            previous_step: first,
            previous_request: source
          )
        end)

      assert snapshot.request["added"] === %{"value" => 1.0}
      assert snapshot.hash == Codec.hash(request)
      assert preparation.raw_reads == 0
      assert preparation.shared_locks == 0

      {{:ok, second}, publication} = measure(fn -> Ash.create(changeset, actor: actor) end)
      assert publication.raw_reads == 0
      assert publication.shared_locks >= 1
      assert second.request_mode == :patch
      assert second.request_hash == snapshot.hash
      assert StepRequests.request_for_step!(second.id, actor: actor) == snapshot.request
    end

    test "logical writes reject runtime base mismatches even when forced full or checkpoint limited" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      source = compact_request(1)
      first = encoded_request_step!(message, 1, source, actor)

      for opts <- [[force_full: true], [max_chain: 1], []] do
        changeset =
          logical_changeset(
            message.id,
            2,
            compact_request(2),
            actor,
            Keyword.merge(opts,
              request_base: compact_request(999),
              request_base_step_id: first.id
            )
          )

        refute changeset.valid?
        assert {:error, _} = Ash.create(changeset, actor: actor)
      end

      legacy_message = request_message!(actor)
      legacy = historical_request_step!(legacy_message, 1, source, actor)
      assert legacy.request_hash == nil

      assert {:error, _} =
               logical_changeset(legacy_message.id, 2, source, actor,
                 request_base: compact_request(999),
                 force_full: true
               )
               |> Ash.create(actor: actor)
    end

    test "caller snapshots and validated flags cannot authorize logical or physical encodings" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      source = compact_request(1)
      first = encoded_request_step!(message, 1, source, actor)
      target = compact_request(2)
      forged = %{Codec.snapshot!(target) | hash: String.duplicate("0", 64), request: source}

      changeset =
        logical_changeset(message.id, 2, target, actor, request_base: source)
        |> Ash.Changeset.set_context(%{validated: true, step_request_snapshot: forged})

      assert {:ok, second} = Ash.create(changeset, actor: actor)
      assert second.request_hash == Codec.hash(target)
      assert StepRequests.request_for_step!(second.id, actor: actor) == target

      other = request_message!(actor)

      assert {:error, _} =
               logical_changeset(other.id, 1, forged, actor)
               |> Ash.create(actor: actor)

      attrs =
        Codec.create_attributes(target,
          sequence: 3,
          previous_step: second,
          previous_request: target
        )

      assert {:error, _} =
               create_encoding(message.id, 3, %{attrs | request_hash: first.request_hash}, actor,
                 private_arguments: %{request_base: target},
                 context: %{validated: true, step_request_snapshot: forged}
               )
    end

    test "resource-owned plans reject changed inputs, owners, actors and locked predecessor metadata" do
      %{user: actor} = user_fixture()
      %{user: stranger} = user_fixture()
      message = request_message!(actor)
      source = compact_request(1)
      first = historical_request_step!(message, 1, source, actor)

      changeset =
        logical_changeset(message.id, 2, compact_request(2), actor, request_base: source)

      assert changeset.valid?

      for {field, value} <- [
            request_hash: String.duplicate("0", 64),
            sequence: 3,
            owner_id: stranger.id,
            raw_request: source
          ] do
        assert {:error, _} =
                 changeset
                 |> Ash.Changeset.force_change_attribute(field, value)
                 |> Ash.create(actor: actor)
      end

      assert {:error, _} =
               changeset
               |> Ash.Changeset.force_set_argument(:request, compact_request(3))
               |> Ash.create(actor: actor)

      assert {:error, _} = Ash.create(changeset, actor: stranger)

      assert {:ok, _} = rewrite(first, Codec.create_attributes(source), actor)
      assert {:error, _} = Ash.create(changeset, actor: actor)

      assert {:ok, second} =
               logical_changeset(message.id, 2, compact_request(2), actor, request_base: source)
               |> Ash.create(actor: actor)

      assert second.request_mode == :patch
    end
  end

  describe "immutability and physical rewrites" do
    test "ordinary updates reject every logical or physical request field, including forced changes" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      step = historical_request_step!(message, 1, compact_request(1), actor)

      for {field, value} <-
            Map.put(StepRequests.create_attributes(compact_request(2)), :sequence, 2) do
        assert {:error, _error} =
                 step
                 |> Ash.Changeset.for_update(:update, %{field => value}, actor: actor)
                 |> Ash.update(actor: actor)
      end

      for {field, value} <- [
            raw_request: %{"forged" => true},
            sequence: 2,
            request_hash: String.duplicate("0", 64)
          ] do
        assert {:error, _error} =
                 step
                 |> Ash.Changeset.for_update(:update, %{}, actor: actor)
                 |> Ash.Changeset.force_change_attribute(field, value)
                 |> Ash.update(actor: actor)
      end

      assert {:ok, updated} =
               step
               |> Ash.Changeset.for_update(
                 :update,
                 %{status: :error, raw_response: %{"error" => "test"}, input_tokens: 7},
                 actor: actor
               )
               |> Ash.update(actor: actor)

      assert updated.input_tokens == 7
      assert StepRequests.request_for_step!(step.id, actor: actor) == compact_request(1)
    end

    test "private rewrite independently checks equivalence and does not alter timestamps or responses" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      first = historical_request_step!(message, 1, compact_request(1), actor)

      second =
        historical_request_step!(message, 2, compact_request(2), actor, %{
          raw_response: %{"opaque" => true},
          input_tokens: 5
        })

      before = stored_request_step!(second.id, actor)

      attrs =
        StepRequests.create_attributes(compact_request(2),
          sequence: 2,
          previous_step: first,
          previous_request: compact_request(1)
        )

      assert attrs.request_mode == :patch
      assert {:ok, _updated} = rewrite(second, attrs, actor)
      after_step = stored_request_step!(second.id, actor)

      assert Map.drop(Map.from_struct(after_step), Codec.fields() ++ [:__metadata__, :__meta__]) ==
               Map.drop(Map.from_struct(before), Codec.fields() ++ [:__metadata__, :__meta__])

      assert after_step.updated_at == before.updated_at
      assert StepRequests.request_for_step!(second.id, actor: actor) == compact_request(2)

      assert {:error, _error} =
               rewrite(second, StepRequests.create_attributes(%{"changed" => true}), actor)

      assert StepRequests.request_for_step!(second.id, actor: actor) == compact_request(2)
    end

    test "physical rewrites accept semantic integer and float equality but not rounded large integers" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      source = Map.merge(compact_request(1), %{"value" => 1, "large" => Integer.pow(10, 80)})
      step = historical_request_step!(message, 1, source, actor)
      equivalent = %{source | "value" => 1.0, "large" => 1.0e80}
      assert {:ok, _} = rewrite(step, Codec.create_attributes(equivalent), actor)

      assert {:error, _} =
               rewrite(
                 step,
                 Codec.create_attributes(%{source | "large" => Integer.pow(10, 80) + 1}),
                 actor
               )

      assert Codec.equal?(StepRequests.request_for_step!(step.id, actor: actor), source)
    end

    test "removing a full checkpoint underneath a patch chain is rejected" do
      %{user: actor} = user_fixture()
      message = request_message!(actor)
      first = encoded_request_step!(message, 1, compact_request(1), actor)
      second = encoded_request_step!(message, 2, compact_request(2), actor, force_full: true)

      third =
        encoded_request_step!(message, 3, compact_request(3), actor,
          previous_step: second,
          previous_request: compact_request(2)
        )

      assert third.request_mode == :patch

      attrs =
        StepRequests.create_attributes(compact_request(2),
          sequence: 2,
          previous_step: first,
          previous_request: compact_request(1)
        )

      assert attrs.request_mode == :patch
      assert {:error, _error} = rewrite(second, attrs, actor)
      assert StepRequests.request_for_step!(third.id, actor: actor) == compact_request(3)
    end
  end

  defp logical_changeset(message_id, sequence, request, actor, opts \\ []) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create_request,
      %{chat_message_id: message_id, sequence: sequence},
      actor: actor,
      private_arguments: Map.put(Map.new(opts), :request, request)
    )
  end

  defp rewrite(step, attrs, actor) do
    step
    |> Ash.Changeset.for_update(:rewrite_request_encoding, %{},
      actor: actor,
      private_arguments: %{encoding: attrs}
    )
    |> Ash.update(actor: actor)
  end

  defp create_encoding(message_id, sequence, attrs, actor, opts \\ []) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(attrs, %{chat_message_id: message_id, sequence: sequence}),
      Keyword.put(opts, :actor, actor)
    )
    |> Ash.create(actor: actor)
  end

  # Statistics of the SELECTs from chat_message_steps issued by the test process
  # (and its tasks) while `fun` runs.
  defp measure(fun) do
    {result, capture} = SqlCapture.measure(fun)
    steps = SqlCapture.selects_from(capture.queries, "chat_message_steps")

    {result,
     %{
       queries: length(steps),
       rows: Enum.sum_by(steps, & &1.row_count),
       raw_reads: length(SqlCapture.reading(steps, "raw_request")),
       shared_locks: Enum.count(steps, &String.contains?(&1.sql, "FOR SHARE"))
     }}
  end
end
