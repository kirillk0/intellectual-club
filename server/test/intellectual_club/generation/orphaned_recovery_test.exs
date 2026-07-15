defmodule IntellectualClub.Generation.OrphanedRecoveryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Fork
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatMessageStepRequestFile
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.ToolCall
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ToolFunction
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  setup do
    previous_backoff = Application.get_env(:intellectual_club, :generation_auto_retry_backoff_ms)
    previous_jitter = Application.get_env(:intellectual_club, :generation_auto_retry_jitter_ratio)

    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [60_000])
    Application.put_env(:intellectual_club, :generation_auto_retry_jitter_ratio, 0.0)

    on_exit(fn ->
      restore_env(:generation_auto_retry_backoff_ms, previous_backoff)
      restore_env(:generation_auto_retry_jitter_ratio, previous_jitter)
    end)

    :ok
  end

  test "recover_orphaned_generations restarts generating message from the last step" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    old_step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: generating_message.id,
          sequence: 1,
          status: :waiting_provider,
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "stream" => true
          },
          raw_response: nil,
          response_final: false
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message = wait_for_status!(generating_message.id, actor, [:done], 4_000)

    assert {:error, _} = Ash.get(ChatMessageStep, old_step.id, actor: actor)

    final_step =
      message.steps
      |> List.wrap()
      |> Enum.max_by(& &1.sequence)

    assert final_step.sequence == 1
    assert final_step.id != old_step.id
  end

  test "orphan restart preserves an oversized request image rendition" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, canonical_file} =
      Files.create_from_binary("orphan-source.png", "image/png", oversized_png_payload())

    {:ok, user_message} =
      Threads.add_message_to_end(chat, :user, "",
        actor: actor,
        contents: [%{kind: :media, file_id: canonical_file.id}]
      )

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    marker = RequestImages.marker(to_string(canonical_file.external_id), "image/png")

    raw_request = %{
      "model" => "demo-model",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => marker}]
        }
      ],
      "stream" => true
    }

    old_step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: generating_message.id,
          sequence: 1,
          status: :waiting_provider,
          raw_request: raw_request,
          raw_response: nil,
          response_final: false
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, old_step.id)

    [old_binding] = request_file_bindings(old_step.id)
    old_rendition_file = Ash.get!(StoredFile, old_binding.file_id, authorize?: false)

    assert old_binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
    assert FilesystemStorage.exists?(old_rendition_file.sha256)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message = wait_for_status!(generating_message.id, actor, [:done], 4_000)
    final_step = Enum.max_by(message.steps, & &1.sequence)
    [replacement_binding] = request_file_bindings(final_step.id)

    assert final_step.id != old_step.id
    assert {:error, _error} = Ash.get(ChatMessageStep, old_step.id, actor: actor)
    assert {:error, _error} = Ash.get(StoredFile, old_binding.file_id, authorize?: false)
    assert replacement_binding.file_id != old_binding.file_id
    assert replacement_binding.reference_key == old_binding.reference_key
    assert replacement_binding.source_file_external_id == old_binding.source_file_external_id
    assert replacement_binding.variant_key == old_binding.variant_key
    assert replacement_binding.file.sha256 == old_rendition_file.sha256
    assert FilesystemStorage.exists?(old_rendition_file.sha256)

    assert {:ok, hydrated_request} =
             RequestImages.hydrate(compact_request, final_step.id)

    assert inspect(hydrated_request) =~ "data:image/png;base64,"
  end

  test "recover_orphaned_generations cancels generating message without steps" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message =
      Ash.get!(ChatMessage, generating_message.id,
        actor: actor,
        load: [:steps]
      )

    assert message.status == :canceled
    assert message.error_detail == "Orphaned generation (worker not found)"
    assert message.steps == []
  end

  test "recover_orphaned_generations finalizes generating message with completed final step" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    completed_step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: generating_message.id,
          sequence: 1,
          status: :done,
          raw_request: %{
            "model" => "demo-model",
            "messages" => [%{"role" => "user", "content" => "Hello"}],
            "stream" => true
          },
          raw_response: %{"id" => "completed-final-step"},
          response_final: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message = wait_for_status!(generating_message.id, actor, [:done], 4_000)

    assert Ash.get!(ChatMessageStep, completed_step.id, actor: actor).status == :done
    assert Enum.map(message.steps, & &1.id) == [completed_step.id]
  end

  test "recover_orphaned_generations continues after completed tool step" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Use the tool", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => "Use the tool"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(generating_message.id, 1, raw_request, [])

    runtime_step =
      RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
      |> add_tool_call_to_runtime_step("call_1", "demo__echo", %{"value" => "one"}, 1)
      |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "tool-step-response"}})
      |> RuntimeTrace.apply_event({:set_step_response_final, true})

    %{tool_calls: [call]} =
      Persistence.persist_provider_completed!(generating_message.id, runtime_step)

    _result =
      Persistence.persist_tool_result!(generating_message.id, step_id, call, %{
        text: "tool output",
        result_raw: %{"ok" => true},
        media_contents: [],
        artifact_contents: []
      })

    :ok = Persistence.mark_step_done!(step_id)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message = wait_for_status!(generating_message.id, actor, [:done], 4_000)
    steps = Enum.sort_by(message.steps, & &1.sequence)

    assert Enum.map(steps, & &1.sequence) == [1, 2]
    assert hd(steps).id == step_id
    assert hd(steps).status == :done
  end

  test "recover_orphaned_generations resumes native agent sleep from persisted call timestamp" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool_instance = create_agent_management_tool_instance!(actor)
    _binding = create_chat_tool_binding!(actor, chat, tool_instance)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Sleep now", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => "Sleep now"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(generating_message.id, 1, raw_request, [])
    requested_ms = 300

    runtime_step =
      RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
      |> add_tool_call_to_runtime_step(
        "sleep_1",
        "agent_management__sleep",
        %{"seconds" => requested_ms / 1000},
        1
      )
      |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "sleep-step-response"}})
      |> RuntimeTrace.apply_event({:set_step_response_final, true})

    %{tool_calls: [call]} =
      Persistence.persist_provider_completed!(generating_message.id, runtime_step)

    assert %DateTime{} = call.created_at

    Process.sleep(180)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message = wait_for_status!(generating_message.id, actor, [:done], 5_000)
    sleep = sleep_result_payload!(message)

    assert sleep["milliseconds"] == requested_ms
    assert sleep["elapsed_milliseconds"] > 0
    assert sleep["remaining_milliseconds"] < requested_ms
    assert sleep["elapsed_milliseconds"] + sleep["remaining_milliseconds"] == requested_ms
  end

  test "recover_orphaned_generations reuses an existing generating fork subagent" do
    %{user: actor} = user_fixture()
    task = "Check the reusable fork"
    parent = create_parent_fork_call!(actor, task)
    child_chat = create_fork_child_chat!(actor, parent.chat, parent.message, parent.call, task)
    child_message = create_generating_child_message!(actor, child_chat, "Child work")

    :ok = GenerationSupervisor.recover_orphaned_generations()

    parent_message = wait_for_status!(parent.message.id, actor, [:done], 6_000)
    child_message = wait_for_status!(child_message.id, actor, [:done], 6_000)

    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat.id]

    assert get_in(fork_tool_result_raw!(parent_message, parent.call.item_id), [
             "fork",
             "chat_id"
           ]) == child_chat.id

    assert get_in(fork_tool_result_raw!(parent_message, parent.call.item_id), [
             "fork",
             "final_message_id"
           ]) == child_message.id
  end

  test "fork creates a new subagent on first execution" do
    %{user: actor} = user_fixture()
    task = "Create a fresh fork"
    parent = create_parent_fork_call!(actor, task)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: parent.chat.id,
      message_id: parent.message.id,
      assistant_message_id: parent.message.id,
      step_id: parent.step_id,
      tool_call_item_id: parent.call.item_id,
      available_file_external_ids: []
    }

    assert {:ok, result} = Fork.create_and_run(parent.tool_instance, task, context, actor)

    assert %{
             "chat_id" => child_chat_id,
             "message_id" => child_message_id,
             "generation_message_id" => child_message_id,
             "final_chat_id" => child_chat_id,
             "final_message_id" => child_message_id
           } = result.raw["fork"]

    refute result.raw["isError"]
    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

    child_message = Ash.get!(ChatMessage, child_message_id, actor: actor)
    assert child_message.status == :done
    assert child_message.error_detail == nil

    parent_message =
      Ash.get!(ChatMessage, parent.message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    raw = fork_tool_result_raw!(parent_message, parent.call.item_id)
    assert raw == result.raw
  end

  test "fork start_or_resume is non-blocking and snapshot uses an opaque answer cursor" do
    %{user: actor} = user_fixture()
    task = "Inspect completed fork"
    parent = create_parent_fork_call!(actor, task)
    child_chat = create_fork_child_chat!(actor, parent.chat, parent.message, parent.call, task)

    {:ok, child_message} =
      Threads.add_message_to_end(child_chat, :assistant, "Completed child answer", actor: actor)

    context = fork_execution_context(parent, actor)

    assert {:ok, reference} =
             Fork.start_or_resume(parent.tool_instance, task, context, actor)

    assert reference.chat_id == child_chat.id
    assert reference.generation_message_id == child_message.id

    assert {:ok, first} = Fork.snapshot(reference, actor)
    assert first.status == :completed
    assert [%{type: "answer", text: "Completed child answer", mode: "replace"}] = first.progress
    assert [%{cursor: progress_cursor}] = first.progress
    assert first.url == "/chats/#{child_chat.id}"
    refute Map.has_key?(first, :reasoning)
    assert is_binary(first.next_cursor)
    assert progress_cursor == first.next_cursor
    assert first.result.raw["fork"]["final_message_id"] == child_message.id

    assert {:ok, unchanged} = Fork.snapshot(reference, actor, first.next_cursor)
    assert unchanged.status == :completed
    assert unchanged.progress == []
    assert unchanged.next_cursor == first.next_cursor

    assert {:ok, reset} = Fork.snapshot(reference, actor, "invalid-cursor")
    assert [%{type: "answer", text: "Completed child answer", mode: "replace"}] = reset.progress
    assert [%{cursor: reset_cursor}] = reset.progress
    assert reset_cursor == reset.next_cursor
  end

  test "fork cancels a prepared child when durable reference persistence fails" do
    %{user: actor} = user_fixture()
    task = "Fail reference persistence"
    parent = create_parent_fork_call!(actor, task)
    context = fork_execution_context(parent, actor)

    assert {:error, :reference_write_failed} =
             Fork.start_or_resume(parent.tool_instance, task, context, actor,
               on_reference: fn _reference -> {:error, :reference_write_failed} end
             )

    [child_chat_id] = fork_child_ids_for_call(actor, parent.call.item_id)
    child_chat = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
    child_message = Ash.get!(ChatMessage, child_chat.last_message_id, actor: actor)

    assert child_message.status == :canceled
    assert GenerationSupervisor.get_generation_state(child_message.id) == :not_found
  end

  test "background fork cancels its generation when the waiter cannot snapshot its reference" do
    %{user: actor} = user_fixture()
    task = "Lose the durable fork reference"
    parent = create_parent_fork_call!(actor, task)
    child_chat = create_fork_child_chat!(actor, parent.chat, parent.message, parent.call, task)
    child = create_generating_child_message_state!(actor, child_chat, "Child work")

    invalid_reference = %{
      chat_id: parent.chat.id,
      message_id: child.message.id,
      generation_message_id: child.message.id,
      url: "/chats/#{child_chat.id}"
    }

    assert {:error, :invalid_fork_reference} =
             Fork.await_background_snapshot(invalid_reference, actor)

    child_message = Ash.get!(ChatMessage, child.message.id, actor: actor)
    assert child_message.status == :canceled
    assert GenerationSupervisor.get_generation_state(child.message.id) == :not_found
  end

  test "background fork completes through the durable task adapter" do
    %{user: actor} = user_fixture()
    task = "Complete in the background"
    parent = create_parent_fork_call!(actor, task)
    context = fork_execution_context(parent, actor)

    assert {:ok, launch} = BackgroundTasks.start_fork(parent.tool_instance, task, context)
    task_id = launch.raw["background_task_id"]
    assert is_binary(task_id)

    snapshot = wait_for_background_status!(task_id, actor.id, "completed", 6_000)

    assert is_integer(snapshot["target_chat_id"])

    assert get_in(snapshot, ["result", "raw", "fork", "chat_id"]) ==
             snapshot["target_chat_id"]

    generation_message_id = snapshot["runner_ref"]["fork_generation_message_id"]

    assert generation_message_id ==
             get_in(snapshot, ["result", "raw", "fork", "generation_message_id"])

    assert snapshot["runner_ref"]["fork_message_id"] == generation_message_id

    assert is_binary(snapshot["next_cursor"])
    assert Enum.all?(snapshot["progress"], &(&1["type"] == "answer"))

    {:ok, later_message} =
      Threads.add_message_to_end(
        Ash.get!(Chat, snapshot["target_chat_id"], actor: actor),
        :assistant,
        "Unrelated later answer",
        actor: actor
      )

    refute later_message.id == generation_message_id

    assert {:ok, stable_reference} = BackgroundTasks.snapshot(task_id, "invalid-cursor", actor.id)

    refute Enum.any?(stable_reference["progress"], fn item ->
             String.contains?(item["text"], "Unrelated later answer")
           end)

    assert {:ok, unchanged} =
             BackgroundTasks.snapshot(task_id, snapshot["next_cursor"], actor.id)

    assert unchanged["status"] == "completed"
    assert unchanged["progress"] == []
  end

  test "recover_orphaned_generations writes a missing parent result for completed fork subagent" do
    %{user: actor} = user_fixture()
    task = "Reuse completed fork"
    parent = create_parent_fork_call!(actor, task)
    child_chat = create_fork_child_chat!(actor, parent.chat, parent.message, parent.call, task)

    {:ok, child_message} =
      Threads.add_message_to_end(child_chat, :assistant, "Already done", actor: actor)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    parent_message = wait_for_status!(parent.message.id, actor, [:done], 6_000)

    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat.id]

    raw = fork_tool_result_raw!(parent_message, parent.call.item_id)
    assert get_in(raw, ["fork", "chat_id"]) == child_chat.id
    assert get_in(raw, ["fork", "final_message_id"]) == child_message.id
  end

  test "recover_orphaned_generations repairs a completed fork child without terminal hook" do
    %{user: actor} = user_fixture()
    task = "Recover terminal fork"
    parent = create_parent_fork_call!(actor, task)
    child_chat = create_fork_child_chat!(actor, parent.chat, parent.message, parent.call, task)
    child = create_generating_child_message_state!(actor, child_chat, "Child work")

    runtime_step =
      RuntimeTrace.new_step(id: child.step_id, sequence: 1, raw_request: child.raw_request)
      |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
      |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Child final answer"})
      |> RuntimeTrace.apply_event({:set_step_response_final, true})

    :ok = Persistence.persist_completed!(child.message.id, runtime_step)

    parent_message =
      Ash.get!(ChatMessage, parent.message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    refute fork_tool_result_raw(parent_message, parent.call.item_id)

    :ok = GenerationSupervisor.recover_orphaned_generations()

    parent_message = wait_for_status!(parent.message.id, actor, [:done], 6_000)

    raw = fork_tool_result_raw!(parent_message, parent.call.item_id)
    assert get_in(raw, ["fork", "chat_id"]) == child_chat.id
    assert get_in(raw, ["fork", "generation_message_id"]) == child.message.id
    assert get_in(raw, ["fork", "final_message_id"]) == child.message.id
  end

  test "recover_orphaned_generations turns terminal fork subagent failure into a tool result" do
    %{user: actor} = user_fixture()
    task = "Reuse canceled fork"
    parent = create_parent_fork_call!(actor, task)
    child_chat = create_fork_child_chat!(actor, parent.chat, parent.message, parent.call, task)

    {:ok, _child_message} =
      Threads.add_message_to_end(child_chat, :assistant, "Stopped",
        actor: actor,
        status: :canceled,
        error_detail: "Canceled by test"
      )

    :ok = GenerationSupervisor.recover_orphaned_generations()

    parent_message = wait_for_status!(parent.message.id, actor, [:done], 6_000)

    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat.id]

    raw = fork_tool_result_raw!(parent_message, parent.call.item_id)
    assert raw["isError"] == true
    assert raw["error"] == "Subagent generation was canceled."
  end

  test "recover_orphaned_generations follows handoff from fork child into canceled generation" do
    %{user: actor} = user_fixture()
    task = "Recover canceled handoff fork"
    parent = create_parent_fork_call!(actor, task)
    child_chat = create_fork_child_chat!(actor, parent.chat, parent.message, parent.call, task)

    {:ok, fork_generation_message} =
      Threads.add_message_to_end(child_chat, :assistant, "", actor: actor)

    handoff_chat = create_handoff_child_chat!(actor, child_chat, fork_generation_message)

    {:ok, handoff_generation_message} =
      Threads.add_message_to_end(handoff_chat, :assistant, "Stopped",
        actor: actor,
        status: :canceled,
        error_detail: "Canceled by test"
      )

    persist_handoff_tool_result!(
      actor,
      fork_generation_message,
      handoff_chat,
      handoff_generation_message
    )

    :ok = GenerationSupervisor.recover_orphaned_generations()

    parent_message = wait_for_status!(parent.message.id, actor, [:done], 6_000)

    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat.id]

    raw = fork_tool_result_raw!(parent_message, parent.call.item_id)
    assert raw["isError"] == true
    assert raw["error"] == "Subagent generation was canceled."
  end

  test "recover_orphaned_generations continues transient retry attempt numbering" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Recover retry provider",
          type: :responses,
          auth_method: :api_key,
          base_url: "http://127.0.0.1:9",
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "gpt-4.1-mini",
          note: "",
          parameters: %{},
          timeout_seconds: 1
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          llm_configuration_id: configuration.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Recover attempt", actor: actor)

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{
          chat_id: chat.id,
          parent_id: user_message.id,
          llm_configuration_id: configuration.id,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "gpt-4.1-mini",
      "input" => [%{"role" => "user", "content" => "Recover attempt"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(generating_message.id, 1, raw_request, [])

    %{step_id: orphaned_step_id, step_sequence: 2} =
      Persistence.persist_retry_error_and_start_next_step!(
        generating_message.id,
        step_id,
        raw_request,
        "Temporary network outage",
        attempt: 5,
        retry_delay_ms: 60_000,
        status_code: 503,
        error_kind: "network",
        retryable: true
      )

    :ok = GenerationSupervisor.recover_orphaned_generations()

    message = wait_for_retry_attempt!(generating_message.id, actor, 6, 15_000)
    steps = Enum.sort_by(message.steps, & &1.sequence)

    assert Enum.map(steps, & &1.sequence) == [1, 2, 3]
    assert Enum.map(steps, & &1.status) == [:error, :error, :waiting_provider]
    assert retry_error_metadata!(Enum.at(steps, 0))["attempt"] == 5
    assert retry_error_metadata!(Enum.at(steps, 1))["attempt"] == 6
    assert Enum.at(steps, 1).id != orphaned_step_id
    assert message.status == :generating

    :ok = GenerationSupervisor.cancel_generation(generating_message.id)
    canceled = wait_for_status!(generating_message.id, actor, [:canceled], 4_000)
    assert canceled.status == :canceled
  end

  defp wait_for_status!(message_id, actor, wanted, timeout_ms)
       when is_integer(message_id) and is_list(wanted) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_status(message_id, actor, wanted, deadline)
  end

  defp wait_for_background_status!(task_id, owner_id, wanted, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_background_status!(task_id, owner_id, wanted, deadline)
  end

  defp do_wait_for_background_status!(task_id, owner_id, wanted, deadline) do
    case BackgroundTasks.snapshot(task_id, nil, owner_id) do
      {:ok, %{"status" => ^wanted} = snapshot} ->
        snapshot

      {:ok, snapshot} ->
        cond do
          snapshot["status"] in ["failed", "canceled"] ->
            flunk(
              "Background task reached terminal status before #{inspect(wanted)}: " <>
                "#{inspect(snapshot)}; generation steps: " <>
                "#{inspect(background_generation_steps(snapshot))}"
            )

          System.monotonic_time(:millisecond) >= deadline ->
            flunk(
              "Background task did not reach expected status #{inspect(wanted)}: #{inspect(snapshot)}"
            )

          true ->
            Process.sleep(20)
            do_wait_for_background_status!(task_id, owner_id, wanted, deadline)
        end

      {:error, reason} ->
        flunk("Background task snapshot failed: #{inspect(reason)}")
    end
  end

  defp background_generation_steps(snapshot) do
    case get_in(snapshot, ["runner_ref", "fork_generation_message_id"]) do
      message_id when is_integer(message_id) ->
        ChatMessageStep
        |> Ash.Query.filter(chat_message_id == ^message_id)
        |> Ash.Query.sort(sequence: :asc)
        |> Ash.Query.select([:id, :sequence, :status, :raw_request])
        |> Ash.read!(authorize?: false)
        |> Enum.map(&Map.take(&1, [:id, :sequence, :status, :raw_request]))

      _other ->
        []
    end
  end

  defp do_wait_for_status(message_id, actor, wanted, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    if message.status in wanted do
      wait_for_generation_worker_to_stop!(message_id)
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_status(message_id, actor, wanted, deadline)
      else
        flunk("Message did not reach expected status")
      end
    end
  end

  defp wait_for_retry_attempt!(message_id, actor, expected_attempt, timeout_ms)
       when is_integer(message_id) and is_integer(expected_attempt) and expected_attempt > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_retry_attempt(message_id, actor, expected_attempt, deadline)
  end

  defp do_wait_for_retry_attempt(message_id, actor, expected_attempt, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    steps = List.wrap(message.steps)

    attempts = Enum.flat_map(steps, &retry_error_attempts/1)

    retry_step_sequences =
      steps
      |> Enum.filter(&(expected_attempt in retry_error_attempts(&1)))
      |> Enum.map(& &1.sequence)

    next_waiting_provider_step? =
      Enum.any?(steps, fn step ->
        step.status == :waiting_provider and
          Enum.any?(retry_step_sequences, &(&1 < step.sequence))
      end)

    if message.status == :generating and expected_attempt in attempts and
         next_waiting_provider_step? do
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_wait_for_retry_attempt(message_id, actor, expected_attempt, deadline)
      else
        flunk(
          "Message did not persist retry attempt #{expected_attempt}: " <>
            "status=#{inspect(message.status)} attempts=#{inspect(attempts)}"
        )
      end
    end
  end

  defp wait_for_generation_worker_to_stop!(message_id) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_for_generation_worker_to_stop!(message_id, deadline)
  end

  defp do_wait_for_generation_worker_to_stop!(message_id, deadline) do
    if GenerationSupervisor.get_generation_state(message_id) == :not_found do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_generation_worker_to_stop!(message_id, deadline)
      else
        flunk("Generation worker did not stop before timeout")
      end
    end
  end

  defp add_tool_call_to_runtime_step(runtime_step, call_id, name, args, sequence) do
    args_json = Jason.encode!(args)

    runtime_step
    |> RuntimeTrace.apply_event({:ensure_item, "tc:" <> call_id, :tool_call, sequence})
    |> RuntimeTrace.apply_event(
      {:set_opaque, "tc:" <> call_id, :tool_call, 10_000,
       %{
         "tool_call_id" => call_id,
         "call_id" => call_id,
         "name" => name,
         "raw" => %{
           "id" => call_id,
           "type" => "function",
           "function" => %{"name" => name, "arguments" => args_json}
         }
       }}
    )
  end

  defp create_agent_management_tool_instance!(actor) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-agent-management",
        name: "Agent management",
        alias: "agent_management",
        description: "",
        config: %{},
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat_tool_binding!(actor, chat, tool_instance) do
    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: tool_instance.id, enabled: true, sequence: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_tool_function!(actor, tool_instance, name) do
    ToolFunction
    |> Ash.Changeset.for_create(
      :create,
      %{
        tool_instance_id: tool_instance.id,
        name: name,
        description: "",
        parameters_schema: %{},
        enabled: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_parent_fork_call!(actor, task) do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    tool_instance = create_agent_management_tool_instance!(actor)
    _function = create_tool_function!(actor, tool_instance, "fork")
    _binding = create_chat_tool_binding!(actor, chat, tool_instance)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Fork now", actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => "Fork now"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])

    runtime_step =
      RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
      |> add_tool_call_to_runtime_step(
        "fork_#{System.unique_integer([:positive])}",
        "agent_management__fork",
        %{"task" => task},
        1
      )
      |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "fork-step-response"}})
      |> RuntimeTrace.apply_event({:set_step_response_final, true})

    %{tool_calls: [call]} = Persistence.persist_provider_completed!(message.id, runtime_step)

    %{chat: chat, message: message, step_id: step_id, call: call, tool_instance: tool_instance}
  end

  defp fork_execution_context(parent, actor) do
    %ExecutionContext{
      owner_id: actor.id,
      chat_id: parent.chat.id,
      message_id: parent.message.id,
      assistant_message_id: parent.message.id,
      step_id: parent.step_id,
      tool_call_item_id: parent.call.item_id,
      available_file_external_ids: []
    }
  end

  defp create_fork_child_chat!(actor, parent_chat, parent_message, call, task) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: task,
        parent_chat_id: parent_chat.id,
        parent_message_id: parent_message.id,
        parent_tool_call_item_id: call.item_id,
        parent_relation_kind: :fork,
        subagent: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_handoff_child_chat!(actor, source_chat, source_message) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: source_chat.note || "",
        parent_chat_id: source_chat.id,
        parent_message_id: source_message.id,
        parent_relation_kind: :handoff,
        subagent: source_chat.subagent == true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp persist_handoff_tool_result!(actor, source_message, handoff_chat, handoff_message) do
    step = last_step_for_message!(actor, source_message.id)
    sequence = next_item_sequence(step.items)

    call_item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: sequence,
          type: :tool_call
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    call = %ToolCall{
      item_id: call_item.id,
      step_id: step.id,
      sequence: sequence,
      call_id: "handoff_#{System.unique_integer([:positive])}",
      name: "agent_management__handoff",
      args: %{"summary" => "Continue in the handoff chat."},
      raw: %{}
    }

    Persistence.persist_tool_result!(source_message.id, step.id, call, %{
      text: "Handoff started.",
      result_raw: %{
        "handoff" => %{
          "chat_id" => handoff_chat.id,
          "generation_message_id" => handoff_message.id
        }
      },
      media_contents: [],
      artifact_contents: []
    })
  end

  defp last_step_for_message!(actor, message_id) do
    ChatMessage
    |> Ash.get!(message_id,
      actor: actor,
      load: [steps: [items: [:contents]]]
    )
    |> Map.get(:steps, [])
    |> Enum.sort_by(& &1.sequence)
    |> List.last()
  end

  defp next_item_sequence(items) do
    items
    |> List.wrap()
    |> Enum.map(&(&1.sequence || 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp create_generating_child_message!(actor, child_chat, prompt) do
    create_generating_child_message_state!(actor, child_chat, prompt).message
  end

  defp create_generating_child_message_state!(actor, child_chat, prompt) do
    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: child_chat.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => prompt}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])

    %{message: message, step_id: step_id, raw_request: raw_request}
  end

  defp fork_child_ids_for_call(actor, tool_call_item_id) do
    Chat
    |> Ash.Query.filter(parent_tool_call_item_id == ^tool_call_item_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.select([:id])
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp fork_tool_result_raw!(message, tool_call_item_id) do
    case fork_tool_result_raw(message, tool_call_item_id) do
      %{} = raw -> raw
      _other -> flunk("Expected fork tool result raw payload")
    end
  end

  defp fork_tool_result_raw(message, tool_call_item_id) do
    message.steps
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.find(fn item ->
      item.type == :tool_result and item.tool_call_item_id == tool_call_item_id
    end)
    |> case do
      nil ->
        nil

      item ->
        item.contents
        |> List.wrap()
        |> Enum.find_value(fn
          %{kind: :opaque, content_json: %{"raw" => %{} = raw}} -> raw
          _other -> nil
        end)
    end
  end

  defp sleep_result_payload!(message) do
    message.steps
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.filter(&(&1.type == :tool_result))
    |> Enum.flat_map(&List.wrap(&1.contents))
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.find_value(fn
      %{content_json: %{"raw" => %{"sleep" => %{} = sleep}}} -> sleep
      _other -> nil
    end)
    |> case do
      %{} = sleep -> sleep
      _other -> flunk("Expected persisted sleep tool result")
    end
  end

  defp retry_error_attempts(step) do
    step.items
    |> List.wrap()
    |> Enum.filter(&(&1.type == :error))
    |> Enum.flat_map(fn item ->
      item.contents
      |> List.wrap()
      |> Enum.filter(&(&1.kind == :opaque))
      |> Enum.map(& &1.content_json)
    end)
    |> Enum.filter(&retry_error_metadata?/1)
    |> Enum.map(&Map.get(&1, "attempt"))
  end

  defp retry_error_metadata!(step) do
    step.items
    |> List.wrap()
    |> Enum.filter(&(&1.type == :error))
    |> Enum.flat_map(fn item ->
      item.contents
      |> List.wrap()
      |> Enum.filter(&(&1.kind == :opaque))
      |> Enum.map(& &1.content_json)
    end)
    |> Enum.find(&retry_error_metadata?/1)
    |> case do
      %{} = metadata -> metadata
      _other -> flunk("Expected retry error metadata")
    end
  end

  defp retry_error_metadata?(%{} = metadata) do
    Map.get(metadata, "retryable") == true and is_integer(Map.get(metadata, "attempt"))
  end

  defp retry_error_metadata?(_metadata), do: false

  defp request_file_bindings(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:file)
    |> Ash.read!(authorize?: false)
  end

  defp oversized_png_payload do
    assert {:ok, image} = Image.new(3_000, 1_500)
    assert {:ok, payload} = Image.write(image, :memory, suffix: ".png")
    payload
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)
end
