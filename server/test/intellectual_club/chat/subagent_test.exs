defmodule IntellectualClub.Chat.SubagentTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Generation.Worker, as: GenerationWorker
  alias IntellectualClub.Tools.ExecutionContext

  describe "start_invocation/5" do
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
  end

  describe "background waits" do
    test "await snapshot does not materialize snapshots while the generation process is alive" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor, subagent: true)

      message =
        create_generating_message!(actor, chat, user_text: "Work", step: :waiting_provider)

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
      set_message_status!(actor, message, :done)
      send(generation_pid, :stop)

      assert {:ok, %{status: :completed}} = Task.await(waiter, 2_000)
      assert_receive :snapshot_materialized
      refute_receive :snapshot_materialized, 50
    end

    test "read-only background reconciliation never resumes an orphaned generation" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor, subagent: true)

      message =
        create_generating_message!(actor, chat, user_text: "Work", step: :waiting_provider)

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
  end

  describe "creation policy" do
    test "nested limit counts mixed spawn-fork and spawn-handoff-spawn creation edges" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor, subagent: false)

      fork_child =
        create_subchat!(actor, root, :fork)

      spawn_child =
        create_subchat!(actor, root, :spawn)

      handoff_after_fork =
        create_subchat!(actor, fork_child, :handoff)

      fork_after_spawn =
        create_subchat!(actor, spawn_child, :fork)

      handoff_after_spawn =
        create_subchat!(actor, spawn_child, :handoff)

      spawn_after_handoff =
        create_subchat!(actor, handoff_after_spawn, :spawn)

      disabled =
        create_agent_tool!(actor, %{"nested_subchats_limit" => 0})

      for source <- [fork_child, spawn_child, handoff_after_fork] do
        assert {:error, message} = Subagent.ensure_creation_allowed(disabled, source, actor)

        assert message ==
                 "Nested subchat creation is unavailable for this subagent. " <>
                   "Continue working on the task yourself without creating another subchat."
      end

      one_level =
        create_agent_tool!(actor, %{"nested_subchats_limit" => 1})

      for source <- [fork_child, spawn_child, handoff_after_fork] do
        assert :ok = Subagent.ensure_creation_allowed(one_level, source, actor)
      end

      for source <- [fork_after_spawn, spawn_after_handoff] do
        assert {:error, message} = Subagent.ensure_creation_allowed(one_level, source, actor)

        assert message ==
                 "Nested subchat creation is unavailable for this subagent. " <>
                   "Continue working on the task yourself without creating another subchat."
      end

      two_levels =
        create_agent_tool!(actor, %{"nested_subchats_limit" => 2})

      for source <- [fork_after_spawn, spawn_after_handoff] do
        assert :ok = Subagent.ensure_creation_allowed(two_levels, source, actor)
      end
    end

    test "nested limit does not truncate creation depth after 64 ancestors" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor, subagent: false)

      source =
        Enum.reduce(1..65, root, fn _index, parent ->
          create_subchat!(actor, parent, :spawn)
        end)

      limit =
        create_agent_tool!(actor, %{"nested_subchats_limit" => 64})

      assert {:error, message} = Subagent.ensure_creation_allowed(limit, source, actor)

      assert message ==
               "Nested subchat creation is unavailable for this subagent. " <>
                 "Continue working on the task yourself without creating another subchat."
    end

    test "unavailable functions follow the nested limit and handoff policy" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor, subagent: false)

      spawn_child =
        create_subchat!(actor, root, :spawn)

      creation = ["fork", "fork_background", "spawn", "spawn_background"]

      disabled =
        create_agent_tool!(actor, %{"nested_subchats_limit" => 0})

      assert Subagent.unavailable_functions(disabled, root, actor) == []

      assert Subagent.unavailable_functions(disabled, spawn_child, actor) == [
               "handoff" | creation
             ]

      one_level =
        create_agent_tool!(actor, %{
          "nested_subchats_limit" => 1,
          "allow_handoff_in_subchats" => true
        })

      assert Subagent.unavailable_functions(one_level, spawn_child, actor) == []

      unsaved_fork = %Chat{
        owner_id: actor.id,
        parent_chat_id: spawn_child.id,
        parent_relation_kind: :fork,
        subagent: true
      }

      assert Subagent.unavailable_functions(one_level, unsaved_fork, actor) == creation
    end

    test "handoff setting applies to every subagent relation kind" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor, subagent: false)

      fork_child =
        create_subchat!(actor, root, :fork)

      spawn_child =
        create_subchat!(actor, root, :spawn)

      handoff_child =
        create_subchat!(actor, spawn_child, :handoff)

      disabled =
        create_agent_tool!(actor, %{"allow_handoff_in_subchats" => false})

      enabled =
        create_agent_tool!(actor, %{"allow_handoff_in_subchats" => true})

      assert :ok = Subagent.ensure_handoff_allowed(disabled, context(root, actor))

      for source <- [fork_child, spawn_child, handoff_child] do
        assert {:error, "Handoff is disabled inside subagent chats."} =
                 Subagent.ensure_handoff_allowed(disabled, context(source, actor))

        assert :ok = Subagent.ensure_handoff_allowed(enabled, context(source, actor))
      end
    end
  end

  describe "lifecycle_states/2" do
    test "lifecycle states expose direct generation and terminal statuses" do
      %{user: actor} = user_fixture()
      parent = create_empty_chat!(actor, subagent: false)

      roots =
        for status <- [:generating, :done, :error, :canceled] do
          root =
            create_subchat!(actor, parent, :fork)

          message =
            create_generating_message!(actor, root, user_text: "Work", step: :waiting_provider)

          if status != :generating do
            set_message_status!(actor, message, status,
              error_detail: if(status == :error, do: "Failed")
            )
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

    test "lifecycle states follow nested persisted handoffs without resuming generation" do
      %{user: actor} = user_fixture()
      parent = create_empty_chat!(actor, subagent: false)

      root =
        create_subchat!(actor, parent, :fork)

      root_message =
        create_generating_message!(actor, root, user_text: "Work", step: :waiting_provider)

      child =
        create_subchat!(actor, root, :handoff)

      child_message =
        create_generating_message!(actor, child, user_text: "Work", step: :waiting_provider)

      terminal =
        create_subchat!(actor, child, :handoff)

      terminal_message =
        create_generating_message!(actor, terminal, user_text: "Work", step: :waiting_provider)

      create_handoff_result!(actor, root_message, child, child_message)
      set_message_status!(actor, root_message, :done)
      create_handoff_result!(actor, child_message, terminal, terminal_message)
      set_message_status!(actor, child_message, :done)

      root = Ash.load!(root, [:last_message], actor: actor)
      terminal_id = terminal.id
      terminal_message_id = terminal_message.id

      assert %{
               active_generation_message_id: ^terminal_message_id,
               chat_id: ^terminal_id,
               last_message_status: :generating,
               message_id: ^terminal_message_id
             } = Subagent.lifecycle_states([root], actor)[root.id]

      child = Ash.load!(child, [:last_message], actor: actor)

      for states <- [
            Subagent.lifecycle_states([child], actor),
            Subagent.lifecycle_states([child], actor, %{child.id => 1})
          ] do
        assert %{
                 active_generation_message_id: ^terminal_message_id,
                 chat_id: ^terminal_id,
                 last_message_status: :generating
               } = states[child.id]
      end

      assert :not_found ==
               IntellectualClub.Generation.Supervisor.get_generation_state(terminal_message.id)

      set_message_status!(actor, terminal_message, :error, error_detail: "Failed")

      assert %{
               active_generation_message_id: nil,
               last_message_status: :error,
               message_id: ^terminal_message_id
             } = Subagent.lifecycle_states([root], actor)[root.id]
    end

    test "lifecycle states ignore unrelated handoff chats without a persisted tool result" do
      %{user: actor} = user_fixture()
      parent = create_empty_chat!(actor, subagent: false)

      root =
        create_subchat!(actor, parent, :spawn)

      root_message =
        create_generating_message!(actor, root, user_text: "Work", step: :waiting_provider)

      set_message_status!(actor, root_message, :done)

      manual_child =
        create_subchat!(actor, root, :handoff)

      _manual_message =
        create_generating_message!(actor, manual_child,
          user_text: "Work",
          step: :waiting_provider
        )

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

    test "lifecycle states fail closed for cycles and beyond the supported handoff depth" do
      %{user: actor} = user_fixture()
      parent = create_empty_chat!(actor, subagent: false)
      cycle_root = create_subchat!(actor, parent, :fork)

      cycle_root_message =
        create_generating_message!(actor, cycle_root, user_text: "Work", step: :waiting_provider)

      cycle_child = create_subchat!(actor, cycle_root, :handoff)

      cycle_child_message =
        create_generating_message!(actor, cycle_child, user_text: "Work", step: :waiting_provider)

      create_handoff_result!(actor, cycle_root_message, cycle_child, cycle_child_message)
      set_message_status!(actor, cycle_root_message, :done)
      create_handoff_result!(actor, cycle_child_message, cycle_root, cycle_root_message)
      set_message_status!(actor, cycle_child_message, :done)

      # One handoff chain shared by two roots: from `over_limit_root` it takes
      # 64 hops to reach the generating message, from `at_limit_root` 63.
      over_limit_root = create_subchat!(actor, parent, :spawn)
      at_limit_root = create_subchat!(actor, parent, :spawn)
      handoff_chat = create_subchat!(actor, at_limit_root, :handoff)

      chain_chat_ids = [
        over_limit_root.id,
        at_limit_root.id | List.duplicate(handoff_chat.id, 63)
      ]

      [_root_message | _rest] = chain = create_handoff_chain!(actor, chain_chat_ids)
      final_message_id = List.last(chain).id

      states =
        [cycle_root, over_limit_root, at_limit_root]
        |> Ash.load!([:last_message], actor: actor)
        |> Subagent.lifecycle_states(actor)

      for chat <- [cycle_root, over_limit_root] do
        assert %{active_generation_message_id: nil, last_message_status: :error} =
                 states[chat.id]
      end

      assert %{
               active_generation_message_id: ^final_message_id,
               last_message_status: :generating,
               message_id: ^final_message_id
             } = states[at_limit_root.id]
    end
  end

  # Creates one assistant message per chat id (in order) with bulk actions: all
  # but the last are done and hand off to the next one through a persisted
  # handoff tool result; the last one is still generating.
  defp create_handoff_chain!(actor, chat_ids) do
    last_index = length(chat_ids) - 1

    messages =
      bulk_create!(
        ChatMessage,
        :add_message,
        chat_ids
        |> Enum.with_index()
        |> Enum.map(fn {chat_id, index} ->
          %{
            chat_id: chat_id,
            role: :assistant,
            status: if(index == last_index, do: :generating, else: :done)
          }
        end),
        actor
      )

    sources = Enum.drop(messages, -1)
    targets = Enum.drop(messages, 1)

    steps =
      bulk_create!(
        ChatMessageStep,
        :create,
        Enum.map(sources, &%{chat_message_id: &1.id, sequence: 1, status: :done}),
        actor
      )

    calls =
      bulk_create!(
        ChatMessageItem,
        :create,
        Enum.map(steps, &%{chat_message_step_id: &1.id, sequence: 1, type: :tool_call}),
        actor
      )

    results =
      bulk_create!(
        ChatMessageItem,
        :create,
        Enum.zip_with(steps, calls, fn step, call ->
          %{
            chat_message_step_id: step.id,
            sequence: 2,
            type: :tool_result,
            tool_call_item_id: call.id
          }
        end),
        actor
      )

    bulk_create!(
      ChatMessageContent,
      :create,
      Enum.zip_with(results, targets, fn result, target ->
        %{
          chat_message_item_id: result.id,
          sequence: 1,
          kind: :opaque,
          content_text: "",
          content_json: %{
            "raw" => %{
              "handoff" => %{"chat_id" => target.chat_id, "generation_message_id" => target.id}
            }
          }
        }
      end),
      actor
    )

    messages
  end

  defp bulk_create!(resource, action, inputs, actor) do
    %Ash.BulkResult{status: :success, records: records} =
      Ash.bulk_create(inputs, resource, action,
        actor: actor,
        return_records?: true,
        return_errors?: true,
        sorted?: true
      )

    records
  end

  defp context(chat, actor) do
    %ExecutionContext{owner_id: actor.id, chat_id: chat.id}
  end

  defp create_agent_tool!(actor, config) do
    create_tool_instance!(actor,
      type: "native-agent-management",
      name: unique_name("Agent management"),
      alias: "agent_management_#{System.unique_integer([:positive])}",
      config: config
    )
  end
end
