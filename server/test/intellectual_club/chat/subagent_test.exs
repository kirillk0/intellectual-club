defmodule IntellectualClub.Chat.SubagentTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ToolInstance

  test "start invocation commits the reference before provider start and cancels start failures" do
    test_process = self()
    reference = %{chat_id: 11, generation_message_id: 22}

    assert {:error, :provider_failed} =
             Subagent.start_invocation(
               %ExecutionContext{},
               reference,
               [
                 on_reference: fn persisted_reference ->
                   send(test_process, {:phase, :reference, persisted_reference})
                   :ok
                 end
               ],
               fn canceled_reference ->
                 send(test_process, {:phase, :cancel, canceled_reference})
               end,
               fn ->
                 send(test_process, {:phase, :provider, reference})
                 {:error, :provider_failed}
               end
             )

    assert_receive {:phase, :reference, ^reference}
    assert_receive {:phase, :provider, ^reference}
    assert_receive {:phase, :cancel, ^reference}
  end

  test "start invocation cancels a failed reference commit without starting the provider" do
    test_process = self()
    reference = %{chat_id: 33, generation_message_id: 44}

    assert {:error, :reference_failed} =
             Subagent.start_invocation(
               %ExecutionContext{},
               reference,
               [
                 on_reference: fn persisted_reference ->
                   send(test_process, {:phase, :reference, persisted_reference})
                   {:error, :reference_failed}
                 end
               ],
               fn canceled_reference ->
                 send(test_process, {:phase, :cancel, canceled_reference})
               end,
               fn ->
                 send(test_process, {:phase, :provider, reference})
                 {:ok, reference}
               end
             )

    assert_receive {:phase, :reference, ^reference}
    assert_receive {:phase, :cancel, ^reference}
    refute_receive {:phase, :provider, ^reference}, 10
  end

  test "nested limit counts mixed spawn-fork and spawn-handoff-spawn creation edges" do
    %{user: actor} = user_fixture()
    root = create_chat!(actor, nil, nil, false)
    fork_child = create_chat!(actor, root, :fork, true)
    spawn_child = create_chat!(actor, root, :spawn, true)
    handoff_after_fork = create_chat!(actor, fork_child, :handoff, true)
    fork_after_spawn = create_chat!(actor, spawn_child, :fork, true)
    handoff_after_spawn = create_chat!(actor, spawn_child, :handoff, true)
    spawn_after_handoff = create_chat!(actor, handoff_after_spawn, :spawn, true)

    disabled = create_tool_instance!(actor, %{"nested_subchats_limit" => 0})

    for source <- [fork_child, spawn_child, handoff_after_fork] do
      assert {:error, message} = Subagent.ensure_creation_allowed(disabled, source, actor)
      assert message =~ "nested_subchats_limit"
    end

    one_level = create_tool_instance!(actor, %{"nested_subchats_limit" => 1})

    for source <- [fork_child, spawn_child, handoff_after_fork] do
      assert :ok = Subagent.ensure_creation_allowed(one_level, source, actor)
    end

    for source <- [fork_after_spawn, spawn_after_handoff] do
      assert {:error, message} = Subagent.ensure_creation_allowed(one_level, source, actor)
      assert message =~ "nested_subchats_limit"
    end

    two_levels = create_tool_instance!(actor, %{"nested_subchats_limit" => 2})

    for source <- [fork_after_spawn, spawn_after_handoff] do
      assert :ok = Subagent.ensure_creation_allowed(two_levels, source, actor)
    end
  end

  test "handoff setting applies to every subagent relation kind" do
    %{user: actor} = user_fixture()
    root = create_chat!(actor, nil, nil, false)
    fork_child = create_chat!(actor, root, :fork, true)
    spawn_child = create_chat!(actor, root, :spawn, true)
    handoff_child = create_chat!(actor, spawn_child, :handoff, true)

    disabled = create_tool_instance!(actor, %{"allow_handoff_in_subchats" => false})
    enabled = create_tool_instance!(actor, %{"allow_handoff_in_subchats" => true})

    assert :ok = Subagent.ensure_handoff_allowed(disabled, context(root, actor))

    for source <- [fork_child, spawn_child, handoff_child] do
      assert {:error, "Handoff is disabled inside subagent chats."} =
               Subagent.ensure_handoff_allowed(disabled, context(source, actor))

      assert :ok = Subagent.ensure_handoff_allowed(enabled, context(source, actor))
    end
  end

  test "nested limit does not truncate creation depth after 64 ancestors" do
    %{user: actor} = user_fixture()
    root = create_chat!(actor, nil, nil, false)

    source =
      Enum.reduce(1..65, root, fn _index, parent ->
        create_chat!(actor, parent, :spawn, true)
      end)

    limit = create_tool_instance!(actor, %{"nested_subchats_limit" => 64})

    assert {:error, message} = Subagent.ensure_creation_allowed(limit, source, actor)
    assert message =~ "nested_subchats_limit"
  end

  defp create_chat!(actor, nil, nil, subagent) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, %{note: "", subagent: subagent}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_chat!(actor, parent, relation_kind, subagent) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: "",
        parent_chat_id: parent.id,
        parent_relation_kind: relation_kind,
        subagent: subagent
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_tool_instance!(actor, config) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-agent-management",
        name: "Agent management #{System.unique_integer([:positive])}",
        description: "",
        alias: "agent_management_#{System.unique_integer([:positive])}",
        config: config,
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp context(chat, actor) do
    %ExecutionContext{owner_id: actor.id, chat_id: chat.id}
  end
end
