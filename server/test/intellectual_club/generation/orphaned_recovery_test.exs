defmodule IntellectualClub.Generation.OrphanedRecoveryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

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

    message = wait_for_retry_attempt!(generating_message.id, actor, 6, 4_000)
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

    attempts =
      message.steps
      |> List.wrap()
      |> Enum.flat_map(&retry_error_attempts/1)

    if message.status == :generating and expected_attempt in attempts do
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_wait_for_retry_attempt(message_id, actor, expected_attempt, deadline)
      else
        flunk("Message did not persist expected retry attempt")
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

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)
end
