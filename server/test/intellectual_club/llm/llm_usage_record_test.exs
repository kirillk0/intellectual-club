defmodule IntellectualClub.Llm.LlmUsageRecordTest do
  use IntellectualClub.DataCase, async: true
  alias IntellectualClub.Llm.LlmUsageRecord

  setup do
    %{user: owner} = user_fixture()
    %{user: consumer} = user_fixture()
    %{user: outsider} = user_fixture()
    %{user: admin} = user_fixture(%{is_admin: true})

    attrs = %{
      usage_user_id: consumer.id,
      usage_user_id_snapshot: consumer.id,
      usage_username_snapshot: consumer.username,
      configuration_owner_id: owner.id,
      configuration_owner_id_snapshot: owner.id,
      llm_configuration_id_snapshot: 1,
      llm_configuration_label_snapshot: "Shared configuration",
      chat_id_snapshot: 1,
      chat_message_id_snapshot: 1,
      chat_message_step_id_snapshot: System.unique_integer([:positive]),
      step_sequence: 1,
      status: :done,
      response_final: true,
      occurred_at: ~U[2026-10-03 12:00:00.000000Z],
      input_tokens: 100,
      output_tokens: 50,
      cost: 0.15,
      raw_usage: %{"cost" => 0.15}
    }

    %{owner: owner, consumer: consumer, outsider: outsider, admin: admin, attrs: attrs}
  end

  test "consumer creates their own usage for a different configuration owner", f do
    record = create!(f.attrs, f.consumer)
    assert record.usage_user_id == f.consumer.id
    assert record.configuration_owner_id_snapshot == f.owner.id
    assert Ash.get!(LlmUsageRecord, record.id, actor: f.owner).cost == 0.15
    assert Ash.get!(LlmUsageRecord, record.id, actor: f.consumer).cost == 0.15
    assert {:error, _error} = Ash.get(LlmUsageRecord, record.id, actor: f.outsider)
  end

  test "configuration owner, outsider, and admin cannot create another user's usage", f do
    for actor <- [f.owner, f.outsider, f.admin] do
      assert {:error, %Ash.Error.Invalid{}} = create(f.attrs, actor)
    end
  end

  test "creation validates both live and historical usage user IDs", f do
    for field <- [:usage_user_id, :usage_user_id_snapshot] do
      assert {:error, %Ash.Error.Invalid{}} =
               create(Map.put(f.attrs, field, f.outsider.id), f.consumer)
    end

    assert {:error, %Ash.Error.Invalid{}} =
             create(Map.put(f.attrs, :usage_user_id, nil), f.consumer)
  end

  test "ownership validation still runs when authorization is disabled", f do
    changeset = Ash.Changeset.for_create(LlmUsageRecord, :create, f.attrs, actor: f.outsider)
    assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
  end

  test "creation requires a current user", f do
    changeset = Ash.Changeset.for_create(LlmUsageRecord, :create, f.attrs)
    assert {:error, _error} = Ash.create(changeset)
  end

  test "creation authorization rejects changing the actor after validation", f do
    changeset = Ash.Changeset.for_create(LlmUsageRecord, :create, f.attrs, actor: f.consumer)
    assert {:error, %Ash.Error.Forbidden{}} = Ash.create(changeset, actor: f.outsider)
  end

  test "general update and destroy actions are unavailable to every actor", f do
    record = create!(f.attrs, f.consumer)
    assert Ash.Resource.Info.action(LlmUsageRecord, :update) == nil
    refute Enum.any?(Ash.Resource.Info.actions(LlmUsageRecord), &(&1.type == :destroy))

    for actor <- [f.consumer, f.owner, f.outsider, f.admin] do
      assert_raise ArgumentError, fn ->
        Ash.Changeset.for_update(record, :update, %{cost: 0.0}, actor: actor)
      end

      assert_raise ArgumentError, fn ->
        Ash.Changeset.for_destroy(record, :destroy, %{}, actor: actor)
      end
    end

    assert Ash.get!(LlmUsageRecord, record.id, actor: f.consumer).cost == 0.15
  end

  test "private maintenance actions reject billing fields and snapshots", f do
    record = create!(f.attrs, f.consumer)

    for name <- [:detach_deleted_references, :move_to_chat] do
      action = Ash.Resource.Info.action(LlmUsageRecord, name)
      refute action.public?

      for field <- [
            :cost,
            :input_tokens,
            :status,
            :occurred_at,
            :usage_user_id_snapshot,
            :raw_usage
          ] do
        changeset =
          Ash.Changeset.for_update(record, name, %{field => Map.fetch!(f.attrs, field)},
            actor: f.consumer
          )

        assert {:error, %Ash.Error.Invalid{}} = Ash.update(changeset, actor: f.consumer)
      end
    end

    persisted = Ash.get!(LlmUsageRecord, record.id, actor: f.consumer)
    fields = Enum.map(Ash.Resource.Info.attributes(LlmUsageRecord), & &1.name)
    assert Map.take(persisted, fields) == Map.take(record, fields)
  end

  test "only the consumer can maintain references and the target chat must be writable", f do
    record = create!(f.attrs, f.consumer)
    target = create_empty_chat!(f.consumer)
    foreign_target = create_empty_chat!(f.owner)

    for actor <- [f.owner, f.outsider, f.admin] do
      changeset =
        Ash.Changeset.for_update(record, :detach_deleted_references, %{}, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.update(changeset, actor: actor)
    end

    changeset =
      Ash.Changeset.for_update(record, :move_to_chat, %{chat_id: foreign_target.id},
        actor: f.consumer
      )

    assert {:error, %Ash.Error.Invalid{}} = Ash.update(changeset, actor: f.consumer)

    moved =
      record
      |> Ash.Changeset.for_update(:move_to_chat, %{chat_id: target.id}, actor: f.consumer)
      |> Ash.update!(actor: f.consumer)

    assert moved.chat_id == target.id

    detached =
      moved
      |> Ash.Changeset.for_update(:detach_deleted_references, %{chat_ids: [target.id]},
        actor: f.consumer
      )
      |> Ash.update!(actor: f.consumer)

    assert detached.chat_id == nil

    for field <- [
          :cost,
          :input_tokens,
          :status,
          :occurred_at,
          :usage_user_id_snapshot,
          :raw_usage
        ] do
      assert Map.fetch!(detached, field) == Map.fetch!(record, field)
    end
  end

  describe "deleted live references" do
    test "deleting the provider preserves its identity and billing snapshots", f do
      provider = create_provider!(f.owner)

      record =
        f.attrs
        |> Map.merge(%{
          provider_id: provider.id,
          provider_id_snapshot: provider.id,
          provider_name_snapshot: provider.name,
          provider_type_snapshot: provider.type
        })
        |> create!(f.consumer)

      assert :ok =
               provider
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: f.owner)
               |> Ash.destroy(actor: f.owner)

      persisted = Ash.get!(LlmUsageRecord, record.id, actor: f.consumer)
      assert persisted.provider_id == nil
      assert persisted.usage_user_id == f.consumer.id
      assert persisted.configuration_owner_id == f.owner.id
      assert_snapshot_unchanged(record, persisted)
    end

    for {reference, deleted_actor, surviving_actor} <- [
          {:usage_user_id, :consumer, :owner},
          {:configuration_owner_id, :owner, :consumer}
        ] do
      @reference reference
      @deleted_actor deleted_actor
      @surviving_actor surviving_actor

      test "deleting #{@deleted_actor} clears #{@reference} without losing historical access",
           f do
        record = create!(f.attrs, f.consumer)
        deleted_user = Map.fetch!(f, @deleted_actor)
        reader = Map.fetch!(f, @surviving_actor)

        assert :ok =
                 deleted_user
                 |> Ash.Changeset.for_destroy(:destroy, %{}, actor: f.admin)
                 |> Ash.destroy(actor: f.admin)

        persisted = Ash.get!(LlmUsageRecord, record.id, actor: reader)
        assert Map.fetch!(persisted, @reference) == nil
        assert_snapshot_unchanged(record, persisted)
        assert {:error, _} = Ash.get(LlmUsageRecord, record.id, actor: f.outsider)
      end
    end

    for {target, detached} <- [
          {:step, [:chat_message_step_id]},
          {:message, [:chat_message_id, :chat_message_step_id]},
          {:chat, [:chat_id, :chat_message_id, :chat_message_step_id]}
        ] do
      @target target
      @detached detached

      test "deleting #{@target} preserves usage and detaches only deleted trace references", f do
        anchor = create_tool_call_anchor!(f.consumer)

        record =
          create_usage_record!(f.consumer, anchor, %{
            configuration_owner_id: f.owner.id,
            configuration_owner_id_snapshot: f.owner.id
          })

        assert :ok =
                 anchor
                 |> Map.fetch!(@target)
                 |> Ash.Changeset.for_destroy(:destroy, %{}, actor: f.consumer)
                 |> Ash.destroy(actor: f.consumer)

        persisted = Ash.get!(LlmUsageRecord, record.id, actor: f.owner)

        for reference <- [:chat_id, :chat_message_id, :chat_message_step_id] do
          if reference in @detached do
            assert Map.fetch!(persisted, reference) == nil
          else
            assert Map.fetch!(persisted, reference) == Map.fetch!(record, reference)
          end
        end

        assert persisted.usage_user_id == f.consumer.id
        assert persisted.configuration_owner_id == f.owner.id
        assert_snapshot_unchanged(record, persisted)
      end
    end
  end

  defp assert_snapshot_unchanged(before, after_deletion) do
    mutable_fields = [
      :usage_user_id,
      :configuration_owner_id,
      :llm_configuration_id,
      :provider_id,
      :chat_id,
      :chat_message_id,
      :chat_message_step_id,
      :updated_at
    ]

    immutable_fields =
      LlmUsageRecord
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)
      |> Enum.reject(&(&1 in mutable_fields))

    assert Map.take(after_deletion, immutable_fields) == Map.take(before, immutable_fields)
  end

  defp create(attrs, actor) do
    LlmUsageRecord
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor)
  end

  defp create!(attrs, actor) do
    {:ok, record} = create(attrs, actor)
    record
  end
end
