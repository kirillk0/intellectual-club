defmodule IntellectualClub.Tools.Drivers.NativeAgentManagementTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Tools.Drivers.NativeAgentManagement
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ToolFunction
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "exposes fixed management functions" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    functions = NativeAgentManagement.fixed_functions(tool_instance)

    assert Enum.map(functions, & &1["name"]) == [
             "handoff",
             "fork",
             "fork_background",
             "spawn",
             "spawn_background",
             "check_background_task_status",
             "cancel_background_task",
             "sleep"
           ]

    assert %{"schema" => handoff_schema} =
             Enum.find(functions, &(&1["name"] == "handoff"))

    assert handoff_schema["required"] == ["summary"]
    assert Enum.find(functions, &(&1["name"] == "handoff"))["enabled_by_default"] == true

    assert %{"schema" => fork_schema} =
             fork_function = Enum.find(functions, &(&1["name"] == "fork"))

    assert fork_function["enabled"] == false
    assert fork_function["enabled_by_default"] == false
    assert fork_schema["required"] == ["task"]
    assert fork_schema["properties"]["task"]["type"] == "string"
    assert String.contains?(fork_function["description"], "exactly one task")
    assert String.contains?(fork_function["description"], "copied model becomes the subagent")
    assert String.contains?(fork_function["description"], "discard every pending intention")
    assert String.contains?(fork_function["description"], "must not continue")
    assert String.contains?(fork_function["description"], "becomes this tool call's result")

    assert String.contains?(
             fork_schema["properties"]["task"]["description"],
             "the only task"
           )

    background_functions =
      Enum.filter(functions, fn function ->
        function["name"] in [
          "fork_background",
          "check_background_task_status",
          "cancel_background_task"
        ]
      end)

    assert Enum.all?(background_functions, &(&1["enabled"] == false))
    assert Enum.all?(background_functions, &(&1["enabled_by_default"] == false))

    fork_background = Enum.find(functions, &(&1["name"] == "fork_background"))
    assert fork_background["is_background_function"] == true
    assert fork_background["schema"]["required"] == ["task"]
    assert String.contains?(fork_background["description"], "exactly one task")
    assert String.contains?(fork_background["description"], "copied model becomes the subagent")
    assert String.contains?(fork_background["description"], "discard every pending intention")
    assert String.contains?(fork_background["description"], "must not continue")
    assert String.contains?(fork_background["description"], "background task id")

    for name <- ["spawn", "spawn_background"] do
      function = Enum.find(functions, &(&1["name"] == name))
      assert function["enabled"] == false
      assert function["enabled_by_default"] == false
      assert Map.get(function, "is_background_function", false) == (name == "spawn_background")
      assert function["schema"]["required"] == ["brief", "prompt"]
      assert function["schema"]["additionalProperties"] == false
    end

    check_background =
      Enum.find(functions, &(&1["name"] == "check_background_task_status"))

    assert check_background["provides_background_task_status"] == true
    refute Map.get(check_background, "is_background_function", false)
    assert check_background["schema"]["required"] == ["background_task_id"]
    assert check_background["schema"]["properties"]["background_task_id"]["format"] == "uuid"
    assert check_background["schema"]["properties"]["cursor"]["type"] == "string"

    cancel_background = Enum.find(functions, &(&1["name"] == "cancel_background_task"))
    assert cancel_background["schema"]["required"] == ["background_task_id"]

    assert %{"schema" => sleep_schema} =
             Enum.find(functions, &(&1["name"] == "sleep"))

    assert sleep_schema["required"] == ["seconds"]
    assert sleep_schema["properties"]["seconds"]["type"] == "number"
    assert Enum.find(functions, &(&1["name"] == "sleep"))["enabled_by_default"] == true
  end

  test "uses generic subchat configuration keys" do
    assert NativeAgentManagement.default_config() == %{
             "nested_subchats_limit" => 0,
             "allow_handoff_in_subchats" => false
           }

    schema = NativeAgentManagement.config_schema()
    properties = schema["properties"]

    assert Map.keys(properties) |> Enum.sort() ==
             ["allow_handoff_in_subchats", "nested_subchats_limit"]

    assert properties["nested_subchats_limit"]["title"] == "Nested subchats limit"
    assert properties["allow_handoff_in_subchats"]["title"] == "Allow handoff in subchats"
  end

  test "fork is rejected by executor while disabled by default" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    result =
      Executor.execute_llm_tool(
        %{"agent_management" => tool_instance},
        "agent_management__fork",
        %{"task" => "Check one thing."},
        %ExecutionContext{owner_id: actor.id}
      )

    assert result.text == "Tool function `fork` is disabled."
    assert result.raw["isError"] == true
    assert result.raw["code"] == "tool_function_disabled"
  end

  test "spawn functions are rejected by executor while disabled by default" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    for name <- ["spawn", "spawn_background"] do
      result =
        Executor.execute_llm_tool(
          %{"agent_management" => tool_instance},
          "agent_management__#{name}",
          %{"brief" => "Research", "prompt" => "Check one thing."},
          %ExecutionContext{owner_id: actor.id}
        )

      assert result.text == "Tool function `#{name}` is disabled."
      assert result.raw["isError"] == true
      assert result.raw["code"] == "tool_function_disabled"
    end
  end

  test "spawn validates brief and prompt before generation context" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    assert {:error, "brief is required"} =
             NativeAgentManagement.execute(
               tool_instance,
               "spawn",
               %{"brief" => "  ", "prompt" => "Do work"},
               %ExecutionContext{owner_id: actor.id}
             )

    assert {:error, "prompt is required"} =
             NativeAgentManagement.execute(
               tool_instance,
               "spawn_background",
               %{"brief" => "Work", "prompt" => "  "},
               %ExecutionContext{owner_id: actor.id}
             )

    assert {:error, "brief must be a string"} =
             NativeAgentManagement.execute(
               tool_instance,
               "spawn",
               %{"brief" => 42, "prompt" => "Do work"},
               %ExecutionContext{owner_id: actor.id}
             )

    assert {:error, "spawn arguments contain unsupported fields"} =
             NativeAgentManagement.execute(
               tool_instance,
               "spawn",
               %{"brief" => "Work", "prompt" => "Do work", "extra" => true},
               %ExecutionContext{owner_id: actor.id}
             )
  end

  test "background management functions are rejected by executor while disabled by default" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    calls = [
      {"agent_management__fork_background", %{"task" => "Check one thing."}},
      {"agent_management__check_background_task_status",
       %{"background_task_id" => Ash.UUID.generate()}},
      {"agent_management__cancel_background_task", %{"background_task_id" => Ash.UUID.generate()}}
    ]

    Enum.each(calls, fn {name, args} ->
      result =
        Executor.execute_llm_tool(
          %{"agent_management" => tool_instance},
          name,
          args,
          %ExecutionContext{owner_id: actor.id}
        )

      assert result.raw["isError"] == true
      assert result.raw["code"] == "tool_function_disabled"
    end)
  end

  test "background subagent launch rejects an exhausted nesting limit before queueing" do
    %{user: actor} = user_fixture()
    root = create_chat!(actor, "Root")
    source = create_subagent_chat!(actor, root)

    tool_instance =
      create_tool_instance!(actor, %{
        "nested_subchats_limit" => 0,
        "allow_handoff_in_subchats" => true
      })

    calls = [
      {"fork_background", %{"task" => "Check one thing."}},
      {"spawn_background", %{"brief" => "Research", "prompt" => "Check one thing."}}
    ]

    Enum.each(calls, fn {name, args} ->
      enable_fixed_function!(tool_instance, name, actor)

      result =
        Executor.execute_llm_tool(
          %{"agent_management" => tool_instance},
          "agent_management__#{name}",
          args,
          %ExecutionContext{owner_id: actor.id, chat_id: source.id}
        )

      assert result.text ==
               "Nested subchat is disabled for this subagent. " <>
                 "Increase nested_subchats_limit to allow it."

      assert result.raw["isError"] == true
    end)

    assert [] =
             BackgroundTask |> Ash.Query.filter(owner_id == ^actor.id) |> Ash.read!(actor: actor)
  end

  test "background status check preserves terminal media and artifacts" do
    %{user: actor} = user_fixture()

    task =
      BackgroundTask
      |> Ash.Changeset.for_create(
        :create,
        %{
          kind: "test",
          adapter: "test",
          status: :running,
          function_name: "test",
          arguments: %{},
          execution_context: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    media = [
      %{
        file_id: 41,
        file_external_id: "media-file",
        filename: "image.png",
        mime_type: "image/png",
        size_bytes: 128,
        sha256: "media-digest"
      }
    ]

    artifacts = [
      %{
        file_id: 42,
        file_external_id: "artifact-file",
        filename: "result.txt",
        mime_type: "text/plain",
        size_bytes: 4,
        sha256: "artifact-digest"
      }
    ]

    assert {:ok, event} = BackgroundTasks.append_event(task, :stdout, "partial output")

    assert {:ok, _task} =
             BackgroundTasks.mark_completed(task, %ExecutionResult{
               text: "Finished",
               raw: %{"ok" => true},
               media: media,
               artifacts: artifacts
             })

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(
               create_tool_instance!(actor),
               "check_background_task_status",
               %{"background_task_id" => task.id},
               %ExecutionContext{owner_id: actor.id}
             )

    assert result.media == media
    assert result.artifacts == artifacts
    assert result.text =~ "completed"
    assert get_in(result.raw, ["background_task", "result", "text"]) == "Finished"

    snapshot = decode_background_snapshot!(result.text)

    assert snapshot["background_task_id"] == task.id
    assert snapshot["kind"] == "test"
    assert snapshot["status"] == "completed"
    assert snapshot["status_detail"] == nil
    assert is_binary(snapshot["created_at"])
    assert Map.has_key?(snapshot, "started_at")
    assert is_binary(snapshot["finished_at"])
    assert is_binary(snapshot["updated_at"])

    assert snapshot["progress"] == [
             %{
               "cursor" => Integer.to_string(event.id),
               "type" => "stdout",
               "text" => "partial output"
             }
           ]

    assert snapshot["result"]["text"] == "Finished"
    assert snapshot["error"] == nil
    assert result.raw["background_task_request"] == %{"operation" => "check", "cursor" => nil}
  end

  test "background cancellation exposes a complete structured snapshot in text" do
    %{user: actor} = user_fixture()

    task =
      BackgroundTask
      |> Ash.Changeset.for_create(
        :create,
        %{
          kind: "test",
          adapter: "test",
          status: :queued,
          function_name: "test",
          arguments: %{},
          execution_context: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(
               create_tool_instance!(actor),
               "cancel_background_task",
               %{"background_task_id" => task.id},
               %ExecutionContext{owner_id: actor.id}
             )

    snapshot = decode_background_snapshot!(result.text)

    assert snapshot["background_task_id"] == task.id
    assert snapshot["status"] == "canceled"
    assert snapshot["cancel_requested"] == true
    assert snapshot["progress"] == []
    assert snapshot["result"] == nil
    assert snapshot["error"] == nil
    assert Map.has_key?(snapshot, "status_detail")
    assert Map.has_key?(snapshot, "created_at")
    assert Map.has_key?(snapshot, "finished_at")
    assert result.raw["background_task_request"] == %{"operation" => "cancel", "cursor" => nil}
  end

  test "background status text preserves a structured terminal error" do
    %{user: actor} = user_fixture()

    task =
      BackgroundTask
      |> Ash.Changeset.for_create(
        :create,
        %{
          kind: "ssh_command",
          adapter: "test",
          status: :running,
          function_name: "run_command",
          arguments: %{},
          execution_context: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:ok, _task} =
             BackgroundTasks.mark_failed(
               task,
               "execution_lost",
               %{"message" => "SSH channel disconnected", "transport" => "ssh"},
               "unknown"
             )

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(
               create_tool_instance!(actor),
               "check_background_task_status",
               %{"background_task_id" => task.id, "cursor" => "17"},
               %ExecutionContext{owner_id: actor.id}
             )

    snapshot = decode_background_snapshot!(result.text)

    assert snapshot["status"] == "failed"
    assert snapshot["result"] == nil
    assert snapshot["error"]["code"] == "execution_lost"
    assert snapshot["error"]["outcome"] == "unknown"
    assert snapshot["error"]["message"] == "SSH channel disconnected"

    assert result.raw["background_task_request"] == %{"operation" => "check", "cursor" => "17"}
  end

  test "repeated checks of oversized terminal results do not request the same cursor forever" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    for kind <- ["fork", "ssh_command", "outlet_function"] do
      task =
        BackgroundTask
        |> Ash.Changeset.for_create(
          :create,
          %{
            kind: kind,
            adapter: "test",
            status: :running,
            function_name: "test",
            arguments: %{},
            execution_context: %{}
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      assert {:ok, _task} =
               BackgroundTasks.mark_completed(task, %ExecutionResult{
                 text: String.duplicate("terminal answer ", 2_000),
                 raw: %{
                   "exit_code" => 0,
                   "stdout" => String.duplicate("command output ", 2_000)
                 }
               })

      assert {:ok, %ExecutionResult{} = first_check} =
               NativeAgentManagement.execute(
                 tool_instance,
                 "check_background_task_status",
                 %{"background_task_id" => task.id},
                 %ExecutionContext{owner_id: actor.id}
               )

      first_limited = Executor.limit_execution_result(first_check, 600)
      first_snapshot = first_limited.raw["background_task"]

      assert first_snapshot["status"] == "completed"
      assert first_snapshot["page_consumed"] == true
      assert first_snapshot["result"]["truncated"] == true
      refute Map.has_key?(first_snapshot, "retry")
      refute first_limited.text =~ "RETRY THE STATUS CHECK"

      assert {:ok, %ExecutionResult{} = repeated_check} =
               NativeAgentManagement.execute(
                 tool_instance,
                 "check_background_task_status",
                 %{
                   "background_task_id" => task.id,
                   "cursor" => first_snapshot["next_cursor"]
                 },
                 %ExecutionContext{owner_id: actor.id}
               )

      repeated_limited = Executor.limit_execution_result(repeated_check, 600)
      repeated_snapshot = repeated_limited.raw["background_task"]

      assert repeated_snapshot["status"] == "completed"
      assert repeated_snapshot["page_consumed"] == true
      assert repeated_snapshot["next_cursor"] == first_snapshot["next_cursor"]
      refute Map.has_key?(repeated_snapshot, "retry")
      refute repeated_limited.text =~ "RETRY THE STATUS CHECK"

      assert repeated_limited.raw["background_task_request"] == %{
               "operation" => "check",
               "cursor" => first_snapshot["next_cursor"]
             }
    end
  end

  test "handoff creates child chat and starts generation" do
    %{user: actor} = user_fixture()
    source = create_chat!(actor, "Tool source")
    {:ok, user_message} = Threads.add_message_to_end(source, :user, "Start", actor: actor)

    {:ok, assistant} =
      Threads.add_message(source, :assistant, "Working", actor: actor, parent_id: user_message.id)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.id,
      message_id: assistant.id,
      assistant_message_id: assistant.id
    }

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(
               create_tool_instance!(actor),
               "handoff",
               %{"summary" => "Continue in the new chat."},
               context
             )

    payload = result.raw["handoff"]
    assert is_integer(payload["chat_id"])
    assert is_integer(payload["message_id"])
    assert is_integer(payload["generation_message_id"])

    target =
      Chat
      |> Ash.get!(payload["chat_id"], actor: actor, load: [:last_message])

    assert target.parent_chat_id == source.id
    assert target.parent_message_id == assistant.id
    assert target.parent_relation_kind == :handoff

    [first_message | _] = messages_for_chat!(target.id, actor)

    first_message_types =
      first_message.steps
      |> Enum.flat_map(& &1.items)
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(& &1.type)

    assert first_message_types == [:handoff_history, :handoff_message]

    first_message_text = History.project_user_input_text(first_message)
    assert String.starts_with?(first_message_text, "History")
    assert String.contains?(first_message_text, "Continue in the new chat.")
    assert String.contains?(first_message_text, "Start")
    assert String.contains?(first_message_text, "Working")

    stored_text =
      first_message.steps
      |> Enum.flat_map(& &1.items)
      |> Enum.flat_map(& &1.contents)
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.map_join("\n", &(&1.content_text || ""))

    refute String.contains?(stored_text, "Work continued")
    refute String.contains?(stored_text, "<details>")
    refute String.contains?(stored_text, "<summary>")

    assert wait_until(fn ->
             generation_message =
               Ash.get!(ChatMessage, payload["generation_message_id"], actor: actor)

             generation_message.status == :done
           end)
  end

  test "handoff requires summary and execution context" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    assert {:error, message} =
             NativeAgentManagement.execute(tool_instance, "handoff", %{}, %ExecutionContext{})

    assert String.contains?(message, "summary")

    assert {:error, "Handoff requires generation execution context."} =
             NativeAgentManagement.execute(tool_instance, "handoff", %{"summary" => "ok"}, nil)
  end

  test "handoff cannot create a child from a stale parent generation epoch" do
    %{user: actor} = user_fixture()
    source = create_chat!(actor, "Stale handoff source")
    {:ok, user_message} = Threads.add_message_to_end(source, :user, "Start", actor: actor)

    assistant =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: source.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:ok, lease} = Lease.acquire(assistant.id)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.id,
      message_id: assistant.id,
      assistant_message_id: assistant.id,
      generation_fence_token: lease.fence_token
    }

    assert :canceled = Persistence.cancel_generating_message!(assistant.id, error_detail: nil)
    assert :ok = Lease.release(lease)

    assert {:error, "parent_generation_stale"} =
             NativeAgentManagement.execute(
               create_tool_instance!(actor),
               "handoff",
               %{"summary" => "Must not continue."},
               context
             )

    assert [] =
             Chat
             |> Ash.Query.filter(
               parent_chat_id == ^source.id and parent_relation_kind == :handoff
             )
             |> Ash.read!(actor: actor)
  end

  test "sleep pauses without execution context" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(tool_instance, "sleep", %{"seconds" => 0.02}, nil)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 15
    assert result.text == "Paused for 0.02 seconds."
    assert result.raw["sleep"]["seconds"] == 0.02
    assert result.raw["sleep"]["milliseconds"] == 20
    assert result.raw["sleep"]["elapsed_milliseconds"] == 0
    assert result.raw["sleep"]["remaining_milliseconds"] == 20
  end

  test "sleep skips already elapsed persisted duration" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    context = %ExecutionContext{
      tool_call_created_at: DateTime.add(DateTime.utc_now(), -1, :second)
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(tool_instance, "sleep", %{"seconds" => 0.2}, context)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 80
    assert result.raw["sleep"]["seconds"] == 0.2
    assert result.raw["sleep"]["milliseconds"] == 200
    assert result.raw["sleep"]["elapsed_milliseconds"] == 200
    assert result.raw["sleep"]["remaining_milliseconds"] == 0
  end

  test "sleep validates duration" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    assert {:error, message} =
             NativeAgentManagement.execute(tool_instance, "sleep", %{"seconds" => -1}, nil)

    assert String.contains?(message, "seconds")

    assert {:error, message} =
             NativeAgentManagement.execute(tool_instance, "sleep", %{}, nil)

    assert String.contains?(message, "seconds")
  end

  defp create_chat!(actor, _title) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, %{note: ""}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_subagent_chat!(actor, parent) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: "",
        parent_chat_id: parent.id,
        parent_relation_kind: :spawn,
        subagent: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_tool_instance!(actor, config \\ %{}) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-agent-management",
        name: "Agent management",
        description: "",
        alias: "agent_management",
        config: config,
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp enable_fixed_function!(tool_instance, name, actor) do
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

  defp decode_background_snapshot!(text) do
    [json] = String.split(text, "Background task snapshot:\n", parts: 2, trim: true) |> tl()
    Jason.decode!(json)
  end

  defp messages_for_chat!(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(steps: [items: [:contents]])
    |> Ash.read!(actor: actor)
  end

  defp wait_until(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_wait_until(fun, deadline)
      else
        false
      end
    end
  end
end
