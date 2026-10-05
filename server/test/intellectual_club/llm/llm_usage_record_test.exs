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
