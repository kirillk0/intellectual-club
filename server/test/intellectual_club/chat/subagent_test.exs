defmodule IntellectualClub.Chat.SubagentTest do
  use IntellectualClub.DataCase, async: false

  require Ash.Query

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Worker, as: GenerationWorker
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

  test "await snapshot does not materialize snapshots while the generation process is alive" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor, nil, nil, true)
    message = create_generation_message!(chat, actor)
    test_process = self()

    generation_pid =
      spawn(fn ->
        :yes = :global.register_name(GenerationWorker.global_name(message.id), self())
        send(test_process, {:generation_registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(generation_pid), do: Process.exit(generation_pid, :kill)
    end)

    assert_receive {:generation_registered, ^generation_pid}

    reference = %{
      primitive: :spawn,
      chat_id: chat.id,
      message_id: message.id,
      generation_message_id: message.id,
      url: "/chats/#{chat.id}"
    }

    snapshot_fun = fn ^reference, ^actor, nil ->
      send(test_process, :snapshot_materialized)
      {:ok, %{status: :completed, result: %{text: "done", raw: %{}}}}
    end

    waiter = Task.async(fn -> Subagent.await_snapshot(reference, actor, snapshot_fun) end)

    refute_receive :snapshot_materialized, 250
    set_message_status!(message, :done, actor)
    send(generation_pid, :stop)

    assert {:ok, %{status: :completed}} = Task.await(waiter, 2_000)
    assert_receive :snapshot_materialized
    refute_receive :snapshot_materialized, 50
  end

  test "read-only background reconciliation never resumes an orphaned generation" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor, nil, nil, true)
    message = create_generation_message!(chat, actor)

    reference = %{
      primitive: :spawn,
      chat_id: chat.id,
      message_id: message.id,
      generation_message_id: message.id,
      url: "/chats/#{chat.id}"
    }

    snapshot_fun = fn _reference, _actor, _cursor ->
      flunk("a non-terminal read-only reconciliation must not materialize a snapshot")
    end

    assert {:retry, {:generation_worker_not_ready, message_id}} =
             Subagent.reconcile_background_wait_read_only(reference, actor, snapshot_fun)

    assert message_id == message.id
    assert :not_found == IntellectualClub.Generation.Supervisor.get_generation_state(message.id)
    assert {:ok, %{status: :generating}} = Ash.get(ChatMessage, message.id, actor: actor)
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

      assert message ==
               "Nested subchat creation is unavailable for this subagent. " <>
                 "Continue working on the task yourself without creating another subchat."
    end

    one_level = create_tool_instance!(actor, %{"nested_subchats_limit" => 1})

    for source <- [fork_child, spawn_child, handoff_after_fork] do
      assert :ok = Subagent.ensure_creation_allowed(one_level, source, actor)
    end

    for source <- [fork_after_spawn, spawn_after_handoff] do
      assert {:error, message} = Subagent.ensure_creation_allowed(one_level, source, actor)

      assert message ==
               "Nested subchat creation is unavailable for this subagent. " <>
                 "Continue working on the task yourself without creating another subchat."
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

  test "lifecycle states follow nested persisted handoffs without resuming generation" do
    %{user: actor} = user_fixture()
    parent = create_chat!(actor, nil, nil, false)
    root = create_chat!(actor, parent, :fork, true)
    root_message = create_generation_message!(root, actor)
    child = create_chat!(actor, root, :handoff, true)
    child_message = create_generation_message!(child, actor)
    terminal = create_chat!(actor, child, :handoff, true)
    terminal_message = create_generation_message!(terminal, actor)

    persist_handoff_result!(root_message, child, child_message, actor)
    set_message_status!(root_message, :done, actor)
    persist_handoff_result!(child_message, terminal, terminal_message, actor)
    set_message_status!(child_message, :done, actor)

    root = Ash.load!(root, [:last_message], actor: actor)
    terminal_id = terminal.id
    terminal_message_id = terminal_message.id

    assert %{
             active_generation_message_id: ^terminal_message_id,
             chat_id: ^terminal_id,
             last_message_status: :generating,
             message_id: ^terminal_message_id
           } = Subagent.lifecycle_states([root], actor)[root.id]

    assert :not_found ==
             IntellectualClub.Generation.Supervisor.get_generation_state(terminal_message.id)

    set_message_status!(terminal_message, :error, actor)

    assert %{
             active_generation_message_id: nil,
             last_message_status: :error,
             message_id: ^terminal_message_id
           } = Subagent.lifecycle_states([root], actor)[root.id]
  end

  test "lifecycle states expose direct generation and terminal statuses" do
    %{user: actor} = user_fixture()
    parent = create_chat!(actor, nil, nil, false)

    roots =
      for status <- [:generating, :done, :error, :canceled] do
        root = create_chat!(actor, parent, :fork, true)
        message = create_generation_message!(root, actor)

        if status != :generating do
          set_message_status!(message, status, actor)
        end

        {status, root, message}
      end

    states =
      roots
      |> Enum.map(fn {_status, root, _message} -> root end)
      |> Ash.load!([:last_message], actor: actor)
      |> Subagent.lifecycle_states(actor)

    for {status, root, message} <- roots do
      expected_active_id = if status == :generating, do: message.id, else: nil

      assert %{
               active_generation_message_id: ^expected_active_id,
               last_message_status: ^status,
               message_id: message_id
             } = states[root.id]

      assert message_id == message.id
    end
  end

  test "lifecycle states ignore unrelated handoff chats without a persisted tool result" do
    %{user: actor} = user_fixture()
    parent = create_chat!(actor, nil, nil, false)
    root = create_chat!(actor, parent, :spawn, true)
    root_message = create_generation_message!(root, actor)
    set_message_status!(root_message, :done, actor)

    manual_child = create_chat!(actor, root, :handoff, true)
    _manual_message = create_generation_message!(manual_child, actor)
    root = Ash.load!(root, [:last_message], actor: actor)
    root_id = root.id
    root_message_id = root_message.id

    assert %{
             active_generation_message_id: nil,
             chat_id: ^root_id,
             last_message_status: :done,
             message_id: ^root_message_id
           } = Subagent.lifecycle_states([root], actor)[root.id]
  end

  test "lifecycle states fail closed for cycles and excessive handoff depth" do
    %{user: actor} = user_fixture()
    parent = create_chat!(actor, nil, nil, false)

    cycle_root = create_chat!(actor, parent, :fork, true)
    cycle_root_message = create_generation_message!(cycle_root, actor)
    cycle_child = create_chat!(actor, cycle_root, :handoff, true)
    cycle_child_message = create_generation_message!(cycle_child, actor)

    persist_handoff_result!(cycle_root_message, cycle_child, cycle_child_message, actor)
    set_message_status!(cycle_root_message, :done, actor)
    persist_handoff_result!(cycle_child_message, cycle_root, cycle_root_message, actor)
    set_message_status!(cycle_child_message, :done, actor)

    depth_root = create_chat!(actor, parent, :spawn, true)
    depth_root_message = create_generation_message!(depth_root, actor)

    {_last_chat, _last_message} =
      Enum.reduce(1..64, {depth_root, depth_root_message}, fn _index,
                                                              {source_chat, source_message} ->
        child = create_chat!(actor, source_chat, :handoff, true)
        child_message = create_generation_message!(child, actor)
        persist_handoff_result!(source_message, child, child_message, actor)
        set_message_status!(source_message, :done, actor)
        {child, child_message}
      end)

    states =
      [cycle_root, depth_root]
      |> Ash.load!([:last_message], actor: actor)
      |> Subagent.lifecycle_states(actor)

    for chat <- [cycle_root, depth_root] do
      assert %{active_generation_message_id: nil, last_message_status: :error} =
               states[chat.id]
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

    assert message ==
             "Nested subchat creation is unavailable for this subagent. " <>
               "Continue working on the task yourself without creating another subchat."
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

  defp create_generation_message!(chat, actor) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Work", actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_id: message.id, sequence: 1, status: :waiting_provider},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    message
  end

  defp set_message_status!(message, status, actor) do
    message
    |> Ash.Changeset.for_update(
      :set_generation_state,
      %{status: status, error_detail: if(status == :error, do: "Failed", else: nil)},
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp persist_handoff_result!(source_message, child_chat, child_message, actor) do
    step =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^source_message.id)
      |> Ash.Query.sort(sequence: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: actor)

    call_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    result_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: 2,
          type: :tool_result,
          tool_call_item_id: call_item.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: result_item.id,
        sequence: 1,
        kind: :opaque,
        content_text: "",
        content_json: %{
          "raw" => %{
            "handoff" => %{
              "chat_id" => child_chat.id,
              "generation_message_id" => child_message.id
            }
          }
        }
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
