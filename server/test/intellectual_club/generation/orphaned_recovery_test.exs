defmodule IntellectualClub.Generation.OrphanedRecoveryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatMessageStepRequestFile
  alias IntellectualClub.Chat.ChatShare
  alias IntellectualClub.Chat.Fork
  alias IntellectualClub.Chat.Spawn
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.ToolCall
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
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

  test "stale parent epoch cannot prepare a fork child" do
    %{user: actor} = user_fixture()
    task = "Do not fork after cancellation"
    parent = create_parent_fork_call!(actor, task)
    assert {:ok, lease} = Lease.acquire(parent.message.id)

    context = %{
      fork_execution_context(parent, actor)
      | generation_fence_token: lease.fence_token
    }

    assert :canceled =
             Persistence.cancel_generating_message!(parent.message.id,
               error_detail: nil
             )

    assert :ok = Lease.release(lease)

    assert {:error, :parent_generation_stale} =
             Fork.start_or_resume(parent.tool_instance, task, context, actor)

    assert fork_child_ids_for_call(actor, parent.call.item_id) == []
  end

  test "spawn creates one empty-context subagent and returns spawn metadata" do
    %{user: actor} = user_fixture()
    brief = "  Research a focused question  "
    trimmed_brief = String.trim(brief)
    prompt = "Return a concise independent answer."
    parent = create_parent_spawn_call!(actor, brief, prompt)

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Spawn demo", type: :demo, base_url: nil, api_key: nil},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{provider_id: provider.id, model_name: "demo", parameters: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Spawn bot", first_messages: ["Fresh bot greeting"]},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    source_chat =
      parent.chat
      |> Ash.Changeset.for_update(
        :update,
        %{bot_id: bot.id, llm_configuration_id: configuration.id},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    knowledge_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Spawn chat context", content: "Copied chat binding"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _knowledge_binding =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_id: source_chat.id,
          knowledge_block_id: knowledge_block.id,
          enabled: false,
          sequence: 17
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    [source_tool_binding] =
      ChatToolBinding
      |> Ash.Query.filter(chat_id == ^source_chat.id)
      |> Ash.read!(actor: actor)

    source_tool_binding =
      source_tool_binding
      |> Ash.Changeset.for_update(:update, %{enabled: true, sequence: 9}, actor: actor)
      |> Ash.update!(actor: actor)

    parent = %{parent | chat: source_chat}
    context = fork_execution_context(parent, actor)

    assert {:ok, result} =
             Spawn.create_and_run(parent.tool_instance, brief, prompt, context, actor)

    assert %{
             "chat_id" => child_chat_id,
             "prompt_message_id" => prompt_message_id,
             "message_id" => generation_message_id,
             "generation_message_id" => generation_message_id,
             "final_chat_id" => child_chat_id,
             "final_message_id" => generation_message_id
           } = result.raw["spawn"]

    refute Map.has_key?(result.raw, "fork")
    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

    child = Ash.get!(Chat, child_chat_id, actor: actor)
    assert child.note == trimmed_brief
    assert child.parent_chat_id == parent.chat.id
    assert child.parent_message_id == parent.message.id
    assert child.parent_relation_kind == :spawn
    assert child.subagent == true
    assert child.bot_id == bot.id
    assert child.llm_configuration_id == configuration.id

    assert [] =
             ChatShare
             |> Ash.Query.filter(chat_id == ^child_chat_id)
             |> Ash.read!(actor: actor)

    [child_knowledge_binding] =
      ChatKnowledgeBlock
      |> Ash.Query.filter(chat_id == ^child_chat_id)
      |> Ash.read!(actor: actor)

    assert child_knowledge_binding.knowledge_block_id == knowledge_block.id
    assert child_knowledge_binding.enabled == false
    assert child_knowledge_binding.sequence == 17

    [child_tool_binding] =
      ChatToolBinding
      |> Ash.Query.filter(chat_id == ^child_chat_id)
      |> Ash.read!(actor: actor)

    assert child_tool_binding.tool_instance_id == source_tool_binding.tool_instance_id
    assert child_tool_binding.enabled == true
    assert child_tool_binding.sequence == 9

    child_messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^child_chat_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.load(steps: [items: [:contents]])
      |> Ash.read!(actor: actor)

    assert Enum.map(child_messages, & &1.role) == [:assistant, :user, :assistant]
    assert Enum.at(child_messages, 1).id == prompt_message_id
    assert Enum.at(child_messages, 2).id == generation_message_id

    assert child_messages
           |> Enum.at(0)
           |> IntellectualClub.Chat.Previews.message_preview_text() == "Fresh bot greeting"

    assert child_messages
           |> Enum.at(1)
           |> IntellectualClub.Chat.Previews.message_preview_text() == prompt

    refute Enum.any?(child_messages, fn message ->
             IntellectualClub.Chat.Previews.message_preview_text(message) == "Spawn now"
           end)

    assert {:ok, same_reference} =
             Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor)

    assert same_reference.chat_id == child_chat_id
    assert same_reference.prompt_message_id == prompt_message_id
    assert same_reference.generation_message_id == generation_message_id
    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat_id]
  end

  test "spawn cancels a prepared generation when durable reference persistence fails" do
    %{user: actor} = user_fixture()
    brief = "Prepare but do not start"
    prompt = "Do not duplicate this generation."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    context = fork_execution_context(parent, actor)

    assert {:error, :reference_write_failed} =
             Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor,
               on_reference: fn _reference -> {:error, :reference_write_failed} end
             )

    [child_chat_id] = fork_child_ids_for_call(actor, parent.call.item_id)
    child = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
    assert child.last_message.status == :canceled
    assert GenerationSupervisor.get_generation_state(child.last_message.id) == :not_found
  end

  test "stale parent epoch cannot prepare a spawn child" do
    %{user: actor} = user_fixture()
    brief = "Do not spawn"
    prompt = "The parent was canceled."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    assert {:ok, lease} = Lease.acquire(parent.message.id)

    context = %{
      fork_execution_context(parent, actor)
      | generation_fence_token: lease.fence_token
    }

    assert :canceled =
             Persistence.cancel_generating_message!(parent.message.id,
               error_detail: nil
             )

    assert :ok = Lease.release(lease)

    assert {:error, :parent_generation_stale} =
             Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor)

    assert fork_child_ids_for_call(actor, parent.call.item_id) == []
  end

  test "stale parent epoch cannot persist an early subagent tool result" do
    %{user: actor} = user_fixture()
    parent = create_parent_spawn_call!(actor, "Stale result", "Do not write a result.")
    assert {:ok, lease} = Lease.acquire(parent.message.id)

    context = %{
      fork_execution_context(parent, actor)
      | generation_fence_token: lease.fence_token
    }

    assert :canceled =
             Persistence.cancel_generating_message!(parent.message.id, error_detail: nil)

    assert :ok = Lease.release(lease)

    assert {:error, :parent_generation_stale} =
             Subagent.persist_parent_tool_result(
               context,
               %ExecutionResult{text: "stale", raw: %{}, media: [], artifacts: []}
             )

    assert [] =
             ChatMessageItem
             |> Ash.Query.filter(chat_message_step_id == ^parent.step_id and type == :tool_result)
             |> Ash.read!(actor: actor)
  end

  test "completed parent rejects subagent prepare and early result with the same live epoch" do
    %{user: actor} = user_fixture()
    brief = "Completed parent"
    prompt = "Do not create a child."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    assert {:ok, lease} = Lease.acquire(parent.message.id)

    context = %{
      fork_execution_context(parent, actor)
      | generation_fence_token: lease.fence_token
    }

    _completed =
      parent.message
      |> Ash.Changeset.for_update(
        :set_generation_state,
        %{status: :done, finished_at: DateTime.utc_now()},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert {:error, :parent_generation_stale} =
             Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor)

    assert {:error, :parent_generation_stale} =
             Subagent.persist_parent_tool_result(
               context,
               %ExecutionResult{text: "stale", raw: %{}, media: [], artifacts: []}
             )

    assert fork_child_ids_for_call(actor, parent.call.item_id) == []

    assert [] =
             ChatMessageItem
             |> Ash.Query.filter(chat_message_step_id == ^parent.step_id and type == :tool_result)
             |> Ash.read!(actor: actor)

    assert :ok = Lease.release(lease)
    assert Ash.get!(ChatMessage, parent.message.id, actor: actor).generation_fence_token == nil
  end

  test "spawn resumes the same prepared generation after a crash before reference persistence" do
    %{user: actor} = user_fixture()
    brief = "Recover prepared spawn"
    prompt = "Resume this exact generation."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    context = fork_execution_context(parent, actor)

    assert {:error, {:throw, :simulated_crash}} =
             Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor,
               on_reference: fn _reference -> throw(:simulated_crash) end
             )

    [child_chat_id] = fork_child_ids_for_call(actor, parent.call.item_id)
    child = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
    generation_message_id = child.last_message.id

    assert child.last_message.status == :generating
    assert GenerationSupervisor.get_generation_state(generation_message_id) == :not_found

    assert {:ok, reference} =
             Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor)

    assert reference.chat_id == child_chat_id
    assert reference.generation_message_id == generation_message_id
    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

    completed = wait_for_status!(generation_message_id, actor, [:done], 6_000)
    assert completed.error_detail == nil
  end

  test "background spawn cancel resolves a prepared generation before its reference is stored" do
    %{user: actor} = user_fixture()
    brief = "Cancel before reference"
    prompt = "This generation must never start."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    context = fork_execution_context(parent, actor)
    background_task = create_spawn_background_task!(actor, parent, brief, prompt, :running)
    test_process = self()

    starter =
      Task.async(fn ->
        Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor,
          on_reference: fn reference ->
            send(test_process, {:spawn_prepared, self(), reference})

            receive do
              :continue_spawn_start -> :ok
            after
              5_000 -> {:error, :reference_barrier_timeout}
            end
          end
        )
      end)

    assert_receive {:spawn_prepared, starter_pid, reference}, 5_000
    assert reference.chat_id in fork_child_ids_for_call(actor, parent.call.item_id)

    assert {:ok, %{"status" => "canceled"}} =
             BackgroundTasks.cancel(background_task.id, actor.id)

    send(starter_pid, :continue_spawn_start)
    assert {:error, :invalid_status} = Task.await(starter, 5_000)

    generation_message = Ash.get!(ChatMessage, reference.generation_message_id, actor: actor)
    assert generation_message.status == :canceled
    assert GenerationSupervisor.get_generation_state(generation_message.id) == :not_found

    :ok = GenerationSupervisor.recover_orphaned_generations()
    Process.sleep(100)

    generation_message = Ash.get!(ChatMessage, reference.generation_message_id, actor: actor)
    assert generation_message.status == :canceled
    assert GenerationSupervisor.get_generation_state(generation_message.id) == :not_found
  end

  test "concurrent spawn starts reuse one canonical generation and step" do
    %{user: actor} = user_fixture()
    brief = "Concurrent spawn"
    prompt = "Run exactly once."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    context = fork_execution_context(parent, actor)
    test_process = self()

    starters =
      for label <- [:first, :second] do
        Task.async(fn ->
          Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor,
            on_reference: fn reference ->
              send(test_process, {:spawn_start_ready, label, self(), reference})

              receive do
                {:continue_spawn_start, ^label} -> :ok
              after
                5_000 -> {:error, :start_barrier_timeout}
              end
            end
          )
        end)
      end

    ready =
      for _index <- 1..2 do
        assert_receive {:spawn_start_ready, label, pid, reference}, 5_000
        {label, pid, reference}
      end

    Enum.each(ready, fn {label, pid, _reference} ->
      send(pid, {:continue_spawn_start, label})
    end)

    results = Enum.map(starters, &Task.await(&1, 5_000))
    assert Enum.all?(results, &match?({:ok, _reference}, &1))

    references = Enum.map(results, fn {:ok, reference} -> reference end)
    assert references |> Enum.map(& &1.chat_id) |> Enum.uniq() |> length() == 1
    assert references |> Enum.map(& &1.generation_message_id) |> Enum.uniq() |> length() == 1

    [reference | _rest] = references
    completed = wait_for_status!(reference.generation_message_id, actor, [:done], 6_000)
    assert completed.error_detail == nil
    assert fork_child_ids_for_call(actor, parent.call.item_id) == [reference.chat_id]

    steps =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^reference.generation_message_id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!(actor: actor)

    assert length(steps) == 1
    assert hd(steps).status == :done
  end

  test "background and global spawn recovery serialize on the canonical generation" do
    %{user: actor} = user_fixture()
    brief = "Double recovery"
    prompt = "Recover this generation once."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    context = fork_execution_context(parent, actor)

    assert {:error, {:throw, :stop_before_reference}} =
             Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor,
               on_reference: fn _reference -> throw(:stop_before_reference) end
             )

    [child_chat_id] = fork_child_ids_for_call(actor, parent.call.item_id)
    child = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
    generation_message_id = child.last_message.id

    background_task =
      create_spawn_background_task!(actor, parent, brief, prompt, :running)

    test_process = self()

    recoveries = [
      Task.async(fn ->
        send(test_process, {:recovery_ready, self()})
        receive do: (:run_recovery -> BackgroundTasks.recover())
      end),
      Task.async(fn ->
        send(test_process, {:recovery_ready, self()})
        receive do: (:run_recovery -> GenerationSupervisor.recover_orphaned_generations())
      end)
    ]

    recovery_pids =
      for _index <- 1..2 do
        assert_receive {:recovery_ready, pid}, 5_000
        pid
      end

    Enum.each(recovery_pids, &send(&1, :run_recovery))
    Enum.each(recoveries, &Task.await(&1, 5_000))

    snapshot =
      wait_for_background_status!(background_task.id, actor.id, "completed", 6_000)

    assert snapshot["runner_ref"]["spawn_generation_message_id"] == generation_message_id
    completed = wait_for_status!(generation_message_id, actor, [:done], 6_000)
    assert completed.error_detail == nil
    assert fork_child_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

    steps =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^generation_message_id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!(actor: actor)

    assert length(steps) == 1
    assert hd(steps).status == :done
  end

  test "durable background spawn remains authorized after its parent generation is canceled" do
    %{user: actor} = user_fixture()
    brief = "Detached spawn"
    prompt = "Finish after the parent is canceled."
    parent = create_parent_spawn_call!(actor, brief, prompt)

    assert {:ok, lease} = Lease.acquire(parent.message.id)

    background_task =
      create_spawn_background_task!(actor, parent, brief, prompt, :running,
        generation_fence_token: lease.fence_token
      )

    assert :canceled =
             Persistence.cancel_generating_message!(parent.message.id,
               error_detail: nil
             )

    assert :ok = Lease.release(lease)
    context = BackgroundTasks.execution_context(background_task)
    assert context.generation_fence_token != nil

    assert {:completed, %ExecutionResult{}} =
             Spawn.execute_background(
               background_task,
               parent.tool_instance,
               "spawn",
               %{"brief" => brief, "prompt" => prompt},
               context
             )

    [child_chat_id] = fork_child_ids_for_call(actor, parent.call.item_id)
    child = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
    assert child.last_message.status == :done
  end

  test "background spawn persists spawn refs and completes through its adapter" do
    %{user: actor} = user_fixture()
    brief = "Background spawn"
    prompt = "Complete independently."
    parent = create_parent_spawn_call!(actor, brief, prompt)
    context = fork_execution_context(parent, actor)

    assert {:ok, launch} =
             BackgroundTasks.start_spawn(parent.tool_instance, brief, prompt, context)

    snapshot =
      wait_for_background_status!(launch.raw["background_task_id"], actor.id, "completed", 6_000)

    assert snapshot["kind"] == "spawn"
    assert is_integer(snapshot["target_chat_id"])
    assert snapshot["runner_ref"]["spawn_chat_id"] == snapshot["target_chat_id"]
    assert is_integer(snapshot["runner_ref"]["spawn_prompt_message_id"])

    assert snapshot["runner_ref"]["spawn_generation_message_id"] ==
             get_in(snapshot, ["result", "raw", "spawn", "generation_message_id"])

    assert get_in(snapshot, ["result", "raw", "spawn", "chat_id"]) ==
             snapshot["target_chat_id"]
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

  test "concurrent fork starts reuse one canonical prepared step and generation" do
    %{user: actor} = user_fixture()
    task = "Run one concurrent fork"
    parent = create_parent_fork_call!(actor, task)
    context = fork_execution_context(parent, actor)
    test_process = self()

    starters =
      for label <- [:first, :second] do
        Task.async(fn ->
          Fork.start_or_resume(parent.tool_instance, task, context, actor,
            on_reference: fn reference ->
              send(test_process, {:fork_start_ready, label, self(), reference})

              receive do
                {:continue_fork_start, ^label} -> :ok
              after
                5_000 -> {:error, :start_barrier_timeout}
              end
            end
          )
        end)
      end

    ready =
      for _index <- 1..2 do
        assert_receive {:fork_start_ready, label, pid, reference}, 5_000
        {label, pid, reference}
      end

    assert ready
           |> Enum.map(fn {_label, _pid, reference} -> reference.chat_id end)
           |> Enum.uniq()
           |> length() ==
             1

    assert ready
           |> Enum.map(fn {_label, _pid, reference} -> reference.generation_message_id end)
           |> Enum.uniq()
           |> length() == 1

    Enum.each(ready, fn {label, pid, _reference} ->
      send(pid, {:continue_fork_start, label})
    end)

    results = Enum.map(starters, &Task.await(&1, 5_000))
    assert Enum.all?(results, &match?({:ok, _reference}, &1))

    references = Enum.map(results, fn {:ok, reference} -> reference end)
    assert references |> Enum.map(& &1.chat_id) |> Enum.uniq() |> length() == 1
    assert references |> Enum.map(& &1.generation_message_id) |> Enum.uniq() |> length() == 1

    [reference | _rest] = references
    assert fork_child_ids_for_call(actor, parent.call.item_id) == [reference.chat_id]

    completed = wait_for_status!(reference.generation_message_id, actor, [:done], 6_000)
    assert completed.error_detail == nil
    wait_for_generation_worker_to_stop!(reference.generation_message_id)

    steps =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^reference.generation_message_id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.Query.load([:items])
      |> Ash.read!(actor: actor)

    assert Enum.map(steps, &{&1.sequence, &1.status}) == [{1, :done}, {2, :done}]
    refute Enum.any?(steps, &(&1.status == :canceled))
    assert Enum.count(List.last(steps).items, &(&1.type == :answer)) == 1
  end

  test "concurrent subagent parent-result persistence creates one tool result" do
    %{user: actor} = user_fixture()
    task = "Persist one parent result"
    parent = create_parent_fork_call!(actor, task)
    context = fork_execution_context(parent, actor)
    test_process = self()

    result = %ExecutionResult{
      text: "Canonical result",
      raw: %{"fork" => %{"chat_id" => 123, "generation_message_id" => 456}},
      media: [],
      artifacts: []
    }

    writers =
      for index <- 1..8 do
        Task.async(fn ->
          send(test_process, {:parent_result_writer_ready, index, self()})

          receive do
            {:persist_parent_result, ^index} ->
              Subagent.persist_parent_tool_result(context, result)
          after
            5_000 -> {:error, :write_barrier_timeout}
          end
        end)
      end

    ready =
      for _index <- 1..8 do
        assert_receive {:parent_result_writer_ready, index, pid}, 5_000
        {index, pid}
      end

    Enum.each(ready, fn {index, pid} -> send(pid, {:persist_parent_result, index}) end)
    assert Enum.all?(writers, &(Task.await(&1, 5_000) == :ok))

    parent_message =
      Ash.get!(ChatMessage, parent.message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    tool_results =
      parent_message.steps
      |> List.wrap()
      |> Enum.flat_map(&List.wrap(&1.items))
      |> Enum.filter(fn item ->
        item.type == :tool_result and item.tool_call_item_id == parent.call.item_id
      end)

    assert length(tool_results) == 1
    assert fork_tool_result_raw!(parent_message, parent.call.item_id) == result.raw
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

  test "background fork cancel resolves a prepared generation before its reference is stored" do
    %{user: actor} = user_fixture()
    task = "Cancel fork before reference"
    parent = create_parent_fork_call!(actor, task)
    context = fork_execution_context(parent, actor)
    background_task = create_fork_background_task!(actor, parent, task, :running)
    test_process = self()

    starter =
      Task.async(fn ->
        Fork.start_or_resume(parent.tool_instance, task, context, actor,
          on_reference: fn reference ->
            send(test_process, {:fork_prepared, self(), reference})

            receive do
              :continue_fork_start -> :ok
            after
              5_000 -> {:error, :reference_barrier_timeout}
            end
          end
        )
      end)

    assert_receive {:fork_prepared, starter_pid, reference}, 5_000
    assert reference.chat_id in fork_child_ids_for_call(actor, parent.call.item_id)

    assert {:ok, %{"status" => "canceled"}} =
             BackgroundTasks.cancel(background_task.id, actor.id)

    send(starter_pid, :continue_fork_start)
    assert {:error, :invalid_status} = Task.await(starter, 5_000)

    generation_message = Ash.get!(ChatMessage, reference.generation_message_id, actor: actor)
    assert generation_message.status == :canceled
    assert GenerationSupervisor.get_generation_state(generation_message.id) == :not_found

    :ok = GenerationSupervisor.recover_orphaned_generations()
    Process.sleep(100)

    generation_message = Ash.get!(ChatMessage, reference.generation_message_id, actor: actor)
    assert generation_message.status == :canceled
    assert GenerationSupervisor.get_generation_state(generation_message.id) == :not_found
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
    create_parent_subagent_call!(actor, "fork", %{"task" => task}, "Fork now")
  end

  defp create_parent_spawn_call!(actor, brief, prompt) do
    create_parent_subagent_call!(
      actor,
      "spawn",
      %{"brief" => brief, "prompt" => prompt},
      "Spawn now"
    )
  end

  defp create_parent_subagent_call!(actor, primitive, args, user_prompt) do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    tool_instance = create_agent_management_tool_instance!(actor)
    _function = create_tool_function!(actor, tool_instance, primitive)
    _binding = create_chat_tool_binding!(actor, chat, tool_instance)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, user_prompt, actor: actor)

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
      "messages" => [%{"role" => "user", "content" => user_prompt}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])

    runtime_step =
      RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
      |> add_tool_call_to_runtime_step(
        "#{primitive}_#{System.unique_integer([:positive])}",
        "agent_management__#{primitive}",
        args,
        1
      )
      |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "subagent-step-response"}})
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

  defp create_spawn_background_task!(actor, parent, brief, prompt, status, opts \\ []) do
    context = fork_execution_context(parent, actor)

    execution_context = %{
      "owner_id" => context.owner_id,
      "chat_id" => context.chat_id,
      "message_id" => context.message_id,
      "assistant_message_id" => context.assistant_message_id,
      "step_id" => context.step_id,
      "available_file_external_ids" => context.available_file_external_ids,
      "tool_call_item_id" => context.tool_call_item_id
    }

    execution_context =
      case Keyword.get(opts, :generation_fence_token) do
        token when is_binary(token) -> Map.put(execution_context, "generation_fence_token", token)
        _other -> execution_context
      end

    BackgroundTask
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: "spawn",
        adapter: "spawn",
        status: status,
        function_name: "spawn",
        arguments: %{"brief" => brief, "prompt" => prompt},
        execution_context: execution_context,
        runner_ref: %{},
        tool_instance_id: parent.tool_instance.id,
        source_chat_id: parent.chat.id,
        source_message_id: parent.message.id,
        source_step_id: parent.step_id,
        source_tool_call_item_id: parent.call.item_id,
        started_at: if(status == :running, do: DateTime.utc_now(), else: nil)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_fork_background_task!(actor, parent, task, status) do
    context = fork_execution_context(parent, actor)

    BackgroundTask
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: "fork",
        adapter: "fork",
        status: status,
        function_name: "fork",
        arguments: %{"task" => task},
        execution_context: %{
          "owner_id" => context.owner_id,
          "chat_id" => context.chat_id,
          "message_id" => context.message_id,
          "assistant_message_id" => context.assistant_message_id,
          "step_id" => context.step_id,
          "available_file_external_ids" => context.available_file_external_ids,
          "tool_call_item_id" => context.tool_call_item_id
        },
        runner_ref: %{},
        tool_instance_id: parent.tool_instance.id,
        source_chat_id: parent.chat.id,
        source_message_id: parent.message.id,
        source_step_id: parent.step_id,
        source_tool_call_item_id: parent.call.item_id,
        started_at: if(status == :running, do: DateTime.utc_now(), else: nil)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
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
