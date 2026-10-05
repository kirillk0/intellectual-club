defmodule IntellectualClub.Generation.OrphanedRecoveryTest do
  @moduledoc """
  Recovery of generations whose worker is gone
  (`GenerationSupervisor.recover_orphaned_generations/0`) and the recovery
  coordinator that serializes recovery requests.

  The fork/spawn lifecycle itself is covered by
  `IntellectualClub.Chat.SubagentLifecycleTest`.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.SubagentFixtures

  require Ash.Query

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, ChatMessageStepRequestFile}
  alias IntellectualClub.Chat.{ContentFiles, Spawn, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Generation.{Lease, Persistence, Recovery, RequestImages, RuntimeTrace}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.ToolCall
  alias IntellectualClub.Notifications.WebPushGenerationEvent
  alias IntellectualClub.TestSupport.ImageRecoveryProvider

  setup do
    put_app_env(:generation_auto_retry_backoff_ms, [60_000])
    put_app_env(:generation_auto_retry_jitter_ratio, 0.0)
    :ok
  end

  describe "recover_orphaned_generations/0 for regular generations" do
    test "restarts a generating message from its last unfinished step" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)

      message =
        create_generating_message!(actor, chat,
          step: %{status: :waiting_provider, raw_request: demo_request("Hello")}
        )

      old_step = first_step!(actor, message)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      message = wait_for_status!(message.id, actor, [:done])
      assert {:error, _} = Ash.get(ChatMessageStep, old_step.id, actor: actor)
      final_step = Enum.max_by(message.steps, & &1.sequence)
      assert final_step.sequence == 1
      assert final_step.id != old_step.id
    end

    test "restart preserves an oversized request image rendition" do
      %{user: actor} = user_fixture()

      configuration =
        create_configuration!(actor,
          provider_attrs: %{name: "Image recovery", type: ImageRecoveryProvider.type()},
          model_name: "image-test"
        )

      chat = create_chat!(actor, llm_configuration_id: configuration.id)
      # Wider than the 2000 px request edge, so the request keeps a downscaled rendition.
      {:ok, canonical_file} =
        Files.create_from_binary("orphan-source.png", "image/png", png(2048, 16))

      {:ok, user_message} =
        Threads.add_message_to_end(chat, :user, "",
          actor: actor,
          contents: [%{kind: :media, file_id: canonical_file.id}]
        )

      message = create_generating_message!(actor, chat, parent_id: user_message.id)
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

      %{step: old_step, request: compact_request} =
        Persistence.create_request_step!(message, 1, raw_request,
          request_context: %{adapter_module: ImageRecoveryProvider}
        )

      [old_binding] = request_file_bindings(old_step.id)
      old_rendition_file = Ash.get!(StoredFile, old_binding.file_id, authorize?: false)
      assert old_binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
      assert FilesystemStorage.exists?(old_rendition_file.sha256)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      message = wait_for_status!(message.id, actor, [:done])
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
               RequestImages.hydrate(compact_request, final_step.id,
                 mapper: &ImageRecoveryProvider.map_request_images/3
               )

      assert inspect(hydrated_request) =~ "data:image/png;base64,"
    end

    test "fails a generating message without steps and notifies about it" do
      %{user: actor} = user_fixture()
      message = create_generating_message!(actor, create_chat!(actor))

      :ok = GenerationSupervisor.recover_orphaned_generations()

      message = Ash.get!(ChatMessage, message.id, actor: actor, load: [:steps])
      assert message.status == :error
      assert message.error_detail == "Orphaned generation (worker not found)"
      assert message.steps == []
      message_id = message.id

      assert [%WebPushGenerationEvent{status: :error, suppressed: false}] =
               WebPushGenerationEvent
               |> Ash.Query.filter(chat_message_id == ^message_id)
               |> Ash.read!(actor: actor)
    end

    test "finalizes a generating message whose final step is already completed" do
      %{user: actor} = user_fixture()

      message =
        create_generating_message!(actor, create_chat!(actor),
          step: %{
            status: :done,
            raw_request: demo_request("Hello"),
            raw_response: %{"id" => "completed-final-step"},
            response_final: true
          }
        )

      completed_step = first_step!(actor, message)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      message = wait_for_status!(message.id, actor, [:done])
      assert Ash.get!(ChatMessageStep, completed_step.id, actor: actor).status == :done
      assert Enum.map(message.steps, & &1.id) == [completed_step.id]
    end

    test "continues with a new step after a completed tool step" do
      %{user: actor} = user_fixture()

      %{message: message, step_id: step_id, raw_request: raw_request} =
        create_started_generation!(actor, create_chat!(actor), "Use the tool")

      runtime_step =
        RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
        |> add_runtime_tool_call("call_1", "demo__echo", %{"value" => "one"}, 1)
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "tool-step-response"}})
        |> RuntimeTrace.apply_event({:set_step_response_final, true})

      %{tool_calls: [call]} = Persistence.persist_provider_completed!(message.id, runtime_step)

      _result =
        Persistence.persist_tool_result!(message.id, step_id, call, %{
          text: "tool output",
          result_raw: %{"ok" => true},
          media_contents: [],
          artifact_contents: []
        })

      :ok = Persistence.mark_step_done!(step_id)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      message = wait_for_status!(message.id, actor, [:done])
      steps = Enum.sort_by(message.steps, & &1.sequence)
      assert Enum.map(steps, & &1.sequence) == [1, 2]
      assert hd(steps).id == step_id
      assert hd(steps).status == :done
    end

    test "resumes a native agent sleep from the persisted call timestamp" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      tool_instance = create_tool_instance!(actor, type: "native-agent-management")
      create_chat_tool_binding!(actor, chat, tool_instance)

      %{message: message, step_id: step_id, raw_request: raw_request} =
        create_started_generation!(actor, chat, "Sleep now")

      requested_ms = 120

      runtime_step =
        RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
        |> add_runtime_tool_call(
          "sleep_1",
          "agent_management__sleep",
          %{"seconds" => requested_ms / 1000},
          1
        )
        |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "sleep-step-response"}})
        |> RuntimeTrace.apply_event({:set_step_response_final, true})

      %{tool_calls: [call]} = Persistence.persist_provider_completed!(message.id, runtime_step)
      assert %DateTime{} = call.created_at

      # Part of the requested pause elapses while no worker owns the generation.
      Process.sleep(60)
      :ok = GenerationSupervisor.recover_orphaned_generations()

      message = wait_for_status!(message.id, actor, [:done])
      sleep = sleep_result_payload!(message)
      assert sleep["milliseconds"] == requested_ms
      assert sleep["elapsed_milliseconds"] > 0
      assert sleep["remaining_milliseconds"] < requested_ms
      assert sleep["elapsed_milliseconds"] + sleep["remaining_milliseconds"] == requested_ms
    end

    test "continues transient retry attempt numbering" do
      %{user: actor} = user_fixture()

      configuration =
        create_configuration!(actor,
          provider_attrs: %{
            name: "Recover retry provider",
            type: :responses,
            base_url: "http://127.0.0.1:9"
          },
          model_name: "gpt-4.1-mini",
          note: "",
          timeout_seconds: 1
        )

      chat = create_chat!(actor, llm_configuration_id: configuration.id)

      message =
        create_generating_message!(actor, chat,
          user_text: "Recover attempt",
          llm_configuration_id: configuration.id
        )

      raw_request = %{
        "model" => "gpt-4.1-mini",
        "input" => [%{"role" => "user", "content" => "Recover attempt"}],
        "stream" => true
      }

      step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])
      assert {:ok, lease} = Lease.acquire(message.id)

      %{step_id: orphaned_step_id, step_sequence: 2} =
        Persistence.persist_retry_error_and_start_next_step!(
          message.id,
          step_id,
          raw_request,
          "Temporary network outage",
          attempt: 5,
          retry_delay_ms: 60_000,
          status_code: 503,
          error_kind: "network",
          retryable: true,
          lease: lease
        )

      assert :ok = Lease.release(lease)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      message = wait_for_retry_attempt!(message.id, actor, 6)
      steps = Enum.sort_by(message.steps, & &1.sequence)
      assert Enum.map(steps, & &1.sequence) == [1, 2, 3]
      assert Enum.map(steps, & &1.status) == [:error, :error, :waiting_provider]
      assert Enum.map(Enum.take(steps, 2), &retry_error_attempts/1) == [[5], [6]]
      assert Enum.at(steps, 1).id != orphaned_step_id
      assert message.status == :generating

      :ok = GenerationSupervisor.cancel_generation(message.id)
      assert wait_for_status!(message.id, actor, [:canceled]).status == :canceled
    end
  end

  describe "recover_orphaned_generations/0 for subagent parents" do
    test "reuses an existing generating fork child" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor)
      child_chat = create_fork_child!(actor, parent)

      %{message: child_message} =
        create_started_generation!(actor, child_chat, "Child work", parent: false)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      parent_message = wait_for_status!(parent.message.id, actor, [:done])
      child_message = wait_for_status!(child_message.id, actor, [:done])
      assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat.id]
      raw = tool_result_raw(parent_message, parent.call.item_id)
      assert get_in(raw, ["fork", "chat_id"]) == child_chat.id
      assert get_in(raw, ["fork", "final_message_id"]) == child_message.id
    end

    test "writes a missing parent result with the attachments of a completed fork child" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor)
      child_chat = create_fork_child!(actor, parent)

      {:ok, child_message} =
        Threads.add_message_to_end(child_chat, :assistant, "Already done", actor: actor)

      {:ok, file} =
        Files.create_from_binary("recovered.txt", "text/plain", "Recovered attachment")

      child_step = first_step!(actor, child_message)
      artifact = create_item!(actor, child_step, sequence: 2, type: :artifact)
      create_content!(actor, artifact, kind: :media, file_id: file.id)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      parent_message = wait_for_status!(parent.message.id, actor, [:done])
      assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat.id]
      raw = tool_result_raw(parent_message, parent.call.item_id)
      assert get_in(raw, ["fork", "chat_id"]) == child_chat.id
      assert get_in(raw, ["fork", "final_message_id"]) == child_message.id

      assert {:ok, {_content, stored, "Recovered attachment"}} =
               ContentFiles.load_payload_for_execution(
                 file.external_id,
                 tool_call_context(parent, actor)
               )

      assert stored.id == file.id
    end

    test "repairs a completed fork child that missed its terminal hook" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor)
      child_chat = create_fork_child!(actor, parent)

      %{message: child_message, step_id: step_id, raw_request: raw_request} =
        create_started_generation!(actor, child_chat, "Child work", parent: false)

      runtime_step =
        RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
        |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
        |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Child final answer"})
        |> RuntimeTrace.apply_event({:set_step_response_final, true})

      :ok = Persistence.persist_completed!(child_message.id, runtime_step)
      refute tool_result_raw(load_message!(parent.message.id, actor), parent.call.item_id)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      parent_message = wait_for_status!(parent.message.id, actor, [:done])
      raw = tool_result_raw(parent_message, parent.call.item_id)
      assert get_in(raw, ["fork", "chat_id"]) == child_chat.id
      assert get_in(raw, ["fork", "generation_message_id"]) == child_message.id
      assert get_in(raw, ["fork", "final_message_id"]) == child_message.id
    end

    test "turns a canceled fork child into an error tool result" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor)
      child_chat = create_fork_child!(actor, parent)
      add_canceled_answer!(actor, child_chat)

      :ok = GenerationSupervisor.recover_orphaned_generations()

      assert_canceled_subagent_result!(parent, child_chat, actor)
    end

    test "follows a handoff from the fork child into a canceled generation" do
      %{user: actor} = user_fixture()
      parent = fork_parent!(actor)
      child_chat = create_fork_child!(actor, parent)

      {:ok, fork_generation_message} =
        Threads.add_message_to_end(child_chat, :assistant, "", actor: actor)

      handoff_chat =
        create_subchat!(actor, child_chat, :handoff,
          parent_message_id: fork_generation_message.id
        )

      handoff_generation_message = add_canceled_answer!(actor, handoff_chat)

      persist_handoff_result!(
        actor,
        fork_generation_message,
        handoff_chat,
        handoff_generation_message
      )

      :ok = GenerationSupervisor.recover_orphaned_generations()

      assert_canceled_subagent_result!(parent, child_chat, actor)
    end

    test "background and global recovery of a prepared spawn serialize on its canonical generation" do
      %{user: actor} = user_fixture()
      brief = "Double recovery"
      prompt = "Recover this generation once."

      parent =
        create_parent_call!(actor, :spawn, %{"brief" => brief, "prompt" => prompt},
          user_prompt: "Spawn now"
        )

      context = tool_call_context(parent, actor)

      assert {:error, {:throw, :stop_before_reference}} =
               Spawn.start_or_resume(parent.tool_instance, brief, prompt, context, actor,
                 on_reference: fn _reference -> throw(:stop_before_reference) end
               )

      [child_chat_id] = subchat_ids_for_call(actor, parent.call.item_id)
      child = Ash.get!(Chat, child_chat_id, actor: actor, load: [:last_message])
      generation_message_id = child.last_message.id

      background_task =
        create_subagent_background_task!(actor, parent, :spawn, parent.call.args, :running)

      test_process = self()

      recoveries =
        for recover <- [
              &BackgroundTasks.recover/0,
              &GenerationSupervisor.recover_orphaned_generations/0
            ] do
          Task.async(fn ->
            send(test_process, {:recovery_ready, self()})
            receive do: (:run_recovery -> recover.())
          end)
        end

      ready_pids =
        for _index <- 1..2 do
          assert_receive {:recovery_ready, pid}, 5_000
          pid
        end

      Enum.each(ready_pids, &send(&1, :run_recovery))

      Enum.each(recoveries, &Task.await(&1, 5_000))

      snapshot = wait_for_background_snapshot!(background_task.id, actor.id, "completed")
      assert snapshot["runner_ref"]["spawn_generation_message_id"] == generation_message_id
      completed = wait_for_status!(generation_message_id, actor, [:done])
      assert completed.error_detail == nil
      assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat_id]

      assert [%ChatMessageStep{status: :done}] =
               ChatMessageStep
               |> Ash.Query.filter(chat_message_id == ^generation_message_id)
               |> Ash.read!(actor: actor)
    end
  end

  describe "Recovery coordinator" do
    test "coalesces overlapping requests into one pending recovery" do
      test_pid = self()
      release_ref = make_ref()

      recovery_fun = fn ->
        send(test_pid, {:recovery_started, self()})
        receive do: ({:release, ^release_ref} -> :ok)
      end

      recovery = start_supervised!({Recovery, name: nil, recovery_fun: recovery_fun})

      :ok = Recovery.request(recovery)
      assert_receive {:recovery_started, first_task}, 1_000

      for _request <- 1..3, do: :ok = Recovery.request(recovery)

      assert Recovery.status(recovery) == %{running?: true, pending?: true}
      refute_receive {:recovery_started, _task}, 50

      send(first_task, {:release, release_ref})
      assert_receive {:recovery_started, second_task}, 1_000
      assert Recovery.status(recovery) == %{running?: true, pending?: false}
      refute_receive {:recovery_started, _task}, 50

      send(second_task, {:release, release_ref})

      wait_until(fn -> Recovery.status(recovery) == %{running?: false, pending?: false} end,
        message: "Recovery coordinator did not become idle"
      )
    end
  end

  defp demo_request(text) do
    %{
      "model" => "demo-model",
      "messages" => [%{"role" => "user", "content" => text}],
      "stream" => true
    }
  end

  # Fork children start with a parentless generation (`parent: false`).
  defp create_started_generation!(actor, chat, user_text, opts \\ []) do
    message =
      if Keyword.get(opts, :parent, true) do
        create_generating_message!(actor, chat, user_text: user_text)
      else
        create!(ChatMessage, :create_generating_assistant, %{chat_id: chat.id}, actor)
      end

    raw_request = demo_request(user_text)
    step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])
    %{message: message, step_id: step_id, raw_request: raw_request}
  end

  defp fork_parent!(actor) do
    create_parent_call!(actor, :fork, %{"brief" => "Fork summary", "prompt" => "Recover fork"},
      user_prompt: "Fork now"
    )
  end

  defp create_fork_child!(actor, parent) do
    create_subchat!(actor, parent.chat, :fork,
      note: "Recover fork",
      parent_message_id: parent.message.id,
      parent_tool_call_item_id: parent.call.item_id
    )
  end

  defp add_canceled_answer!(actor, chat) do
    {:ok, message} =
      Threads.add_message_to_end(chat, :assistant, "Stopped",
        actor: actor,
        status: :canceled,
        error_detail: "Canceled by test"
      )

    message
  end

  defp persist_handoff_result!(actor, source_message, handoff_chat, handoff_message) do
    step = actor |> first_step!(source_message) |> Ash.load!([:items], actor: actor)
    sequence = Enum.max([0 | Enum.map(step.items, & &1.sequence)]) + 1
    call_item = create_item!(actor, step, sequence: sequence, type: :tool_call)

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

  defp assert_canceled_subagent_result!(parent, child_chat, actor) do
    parent_message = wait_for_status!(parent.message.id, actor, [:done])
    assert subchat_ids_for_call(actor, parent.call.item_id) == [child_chat.id]
    raw = tool_result_raw(parent_message, parent.call.item_id)
    assert raw["isError"] == true
    assert raw["error"] == "Subagent generation was canceled."
  end

  defp wait_for_status!(message_id, actor, wanted) do
    wait_for_message_status!(message_id, actor, wanted,
      timeout: 6_000,
      load: [steps: [items: [:contents]]],
      stop_worker: true
    )
  end

  defp load_message!(message_id, actor) do
    Ash.get!(ChatMessage, message_id, actor: actor, load: [steps: [items: [:contents]]])
  end

  # Waits until `expected_attempt` is persisted as a retryable error and a
  # later step waits for the provider again.
  defp wait_for_retry_attempt!(message_id, actor, expected_attempt) do
    wait_until(
      fn ->
        message = load_message!(message_id, actor)
        steps = List.wrap(message.steps)

        retry_sequences =
          for step <- steps, expected_attempt in retry_error_attempts(step), do: step.sequence

        next_waiting? =
          Enum.any?(steps, fn step ->
            step.status == :waiting_provider and Enum.any?(retry_sequences, &(&1 < step.sequence))
          end)

        message.status == :generating and next_waiting? and message
      end,
      timeout: 15_000,
      interval: 50,
      message: "Message #{message_id} did not persist retry attempt #{expected_attempt}"
    )
  end

  defp retry_error_attempts(step) do
    for %{type: :error} = item <- List.wrap(step.items),
        %{kind: :opaque, content_json: %{"retryable" => true, "attempt" => attempt}} <-
          List.wrap(item.contents),
        is_integer(attempt),
        do: attempt
  end

  defp sleep_result_payload!(message) do
    sleeps =
      for step <- message.steps,
          %{type: :tool_result} = item <- step.items,
          %{kind: :opaque, content_json: %{"raw" => %{"sleep" => %{} = sleep}}} <- item.contents,
          do: sleep

    assert [sleep | _rest] = sleeps, "Expected persisted sleep tool result"
    sleep
  end

  defp request_file_bindings(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:file)
    |> Ash.read!(authorize?: false)
  end
end
