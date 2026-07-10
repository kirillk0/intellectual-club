defmodule IntellectualClub.Generation.SteeringWorkerTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Worker

  defmodule InterruptibleAdapter do
    @moduledoc false

    def inject_steering(raw_request, steering_items, _context) do
      messages = Map.get(raw_request, "messages", [])

      steering_messages =
        Enum.map(steering_items, fn item ->
          %{"role" => "user", "content" => Map.fetch!(item, :text)}
        end)

      raw_request = Map.put(raw_request, "messages", messages ++ steering_messages)
      %{raw_request: raw_request, request_snapshot: request_snapshot(raw_request)}
    end

    def request_snapshot(raw_request) do
      %{model_input: Map.get(raw_request, "messages", []), system_prompt: "", history_length: nil}
    end

    def stream_generate(%{context: context, request_payload: request_payload}, emit) do
      attempt = Agent.get_and_update(context.attempts, fn value -> {value + 1, value + 1} end)
      send(context.test_pid, {:stream_started, attempt, self(), request_payload})

      if attempt == 1 do
        stale_emitter =
          spawn(fn ->
            receive do
              :emit ->
                emit.(
                  {:response_complete,
                   %{
                     raw_request: request_payload,
                     raw_response: %{"id" => "stale", "output" => []}
                   }}
                )
            end
          end)

        send(context.test_pid, {:stale_emitter, stale_emitter})
      end

      emit.({:trace, {:set_text, "answer", :answer, 1, "Discarded partial answer"}})

      receive do
        {:complete, answer} ->
          emit.({:trace, {:set_text, "answer", :answer, 1, answer}})

          emit.(
            {:response_complete,
             %{
               raw_request: request_payload,
               raw_response: %{"id" => "completed", "output" => []}
             }}
          )
      end

      :ok
    end
  end

  defmodule RetryThenWaitAdapter do
    @moduledoc false

    def inject_steering(raw_request, steering_items, context) do
      InterruptibleAdapter.inject_steering(raw_request, steering_items, context)
    end

    def stream_generate(%{context: context, request_payload: request_payload}, emit) do
      attempt = Agent.get_and_update(context.attempts, fn value -> {value + 1, value + 1} end)
      send(context.test_pid, {:retry_stream_started, attempt, self(), request_payload})

      if attempt == 1 do
        stale_emitter =
          spawn(fn ->
            receive do
              :emit ->
                emit.({:trace, {:set_text, "answer", :answer, 1, "Stale retry answer"}})

                emit.(
                  {:response_complete,
                   %{
                     raw_request: request_payload,
                     raw_response: %{"id" => "stale-retry", "output" => []}
                   }}
                )
            end
          end)

        send(context.test_pid, {:retry_stale_emitter, stale_emitter})

        emit.(
          {:response_error,
           %{
             retryable: true,
             error_kind: "network",
             status_code: 503,
             error_text: "First retryable failure",
             raw_request: request_payload
           }}
        )
      else
        receive do
          {:fail, error_text} ->
            emit.(
              {:response_error,
               %{
                 retryable: true,
                 error_kind: "network",
                 status_code: 503,
                 error_text: error_text,
                 raw_request: request_payload
               }}
            )

          {:complete, answer} ->
            emit.({:trace, {:set_text, "answer", :answer, 1, answer}})

            emit.(
              {:response_complete,
               %{
                 raw_request: request_payload,
                 raw_response: %{"id" => "retry-complete", "output" => []}
               }}
            )
        end
      end

      :ok
    end
  end

  defmodule PartialTerminalAdapter do
    @moduledoc false

    def inject_steering(raw_request, steering_items, context) do
      InterruptibleAdapter.inject_steering(raw_request, steering_items, context)
    end

    def stream_generate(%{context: context, request_payload: request_payload}, emit) do
      emit.({:trace, {:set_text, "reasoning", :reasoning, 1, "Partial reasoning"}})
      emit.({:trace, {:set_text, "answer", :answer, 1, "Partial answer"}})
      send(context.test_pid, {:partial_terminal_ready, context.message_id, self()})

      case context.terminal_mode do
        :error ->
          emit.(
            {:response_error,
             %{
               retryable: false,
               error_kind: "provider",
               status_code: 400,
               error_text: "Stream failed",
               raw_request: request_payload,
               raw_response: %{"id" => "partial-error"},
               usage: %{"input_tokens" => 30, "output_tokens" => 7}
             }}
          )

        :wait ->
          receive do
            :finish -> :ok
          end
      end

      :ok
    end
  end

  test "manual cancel and terminal stream error preserve partial runtime output" do
    %{user: actor} = user_fixture()

    for {terminal_mode, expected_status} <- [wait: :canceled, error: :error] do
      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, user_message} =
        Threads.add_message_to_end(chat, :user, "Initial request", actor: actor)

      assistant_message =
        ChatMessage
        |> Ash.Changeset.for_create(
          :create_generating_assistant,
          %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      raw_request = %{
        "model" => "test-model",
        "messages" => [%{"role" => "user", "content" => "Initial request"}],
        "stream" => true
      }

      step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

      context = %{
        owner_id: actor.id,
        chat_id: chat.id,
        message_id: assistant_message.id,
        step_id: step_id,
        provider_type: "test",
        adapter_module: PartialTerminalAdapter,
        request_payload: raw_request,
        timeout_ms: 5_000,
        chunk_delay_ms: 0,
        supports_steering: true,
        terminal_mode: terminal_mode,
        test_pid: self()
      }

      pid =
        start_supervised!(%{
          id: {Worker, assistant_message.id},
          start: {Worker, :start_link, [%{context: context}]},
          restart: :temporary
        })

      monitor_ref = Process.monitor(pid)

      assert_receive {:partial_terminal_ready, message_id, _stream_task}, 1_000
      assert message_id == assistant_message.id

      if terminal_mode == :wait do
        _state_after_partial = Worker.get_current_state(pid)
        Worker.cancel(pid)
      end

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      assert message.status == expected_status
      assert message.token_count > 0
      assert [step] = message.steps
      assert step.status == expected_status
      assert item_text(Enum.find(step.items, &(&1.type == :reasoning))) == "Partial reasoning"
      assert item_text(Enum.find(step.items, &(&1.type == :answer))) == "Partial answer"

      if terminal_mode == :error do
        assert step.raw_response == %{"id" => "partial-error"}
        assert step.input_tokens == 30
        assert step.output_tokens == 7
        assert item_text(Enum.find(step.items, &(&1.type == :error))) == "Stream failed"
      end
    end
  end

  test "steering interrupts provider, ignores stale events and restarts the same step" do
    %{user: actor} = user_fixture()
    {:ok, attempts} = start_supervised({Agent, fn -> 0 end})

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Initial request", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "Initial request"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: assistant_message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: InterruptibleAdapter,
      request_payload: raw_request,
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      supports_steering: true,
      attempts: attempts,
      test_pid: self()
    }

    pid = start_supervised!({Worker, %{context: context}})
    monitor_ref = Process.monitor(pid)

    assert_receive {:stream_started, 1, _first_task, ^raw_request}, 1_000
    assert_receive {:stale_emitter, stale_emitter}, 1_000

    test_pid = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      send(test_pid, {:duplicate_worker_result, Worker.start_link(%{context: context})})
    end)

    assert_receive {:duplicate_worker_result, {:error, {:already_running, ^pid}}}, 1_000

    assert {:ok, %{step_id: ^step_id}} = Worker.steer(pid, "Change direction")

    assert_receive {:stream_started, 2, second_task, restarted_request}, 1_000

    assert List.last(restarted_request["messages"]) == %{
             "role" => "user",
             "content" => "Change direction"
           }

    send(stale_emitter, :emit)
    assert %{status: :generating} = Worker.get_current_state(pid)

    send(second_task, {:complete, "Restarted answer"})
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000

    message =
      Ash.get!(ChatMessage, assistant_message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    assert message.status == :done
    assert [step] = message.steps
    assert step.id == step_id

    assert Enum.map(Enum.sort_by(step.items, & &1.sequence), & &1.type) == [:steering, :answer]

    steering = Enum.find(step.items, &(&1.type == :steering))
    answer = Enum.find(step.items, &(&1.type == :answer))

    assert item_text(steering) == "Change direction"
    assert item_text(answer) == "Restarted answer"
    refute item_text(answer) =~ "Discarded partial answer"
  end

  test "steering during retry backoff invalidates stale stream and timer events" do
    previous_backoff = Application.get_env(:intellectual_club, :generation_auto_retry_backoff_ms)
    previous_jitter = Application.get_env(:intellectual_club, :generation_auto_retry_jitter_ratio)

    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [60_000])
    Application.put_env(:intellectual_club, :generation_auto_retry_jitter_ratio, 0.0)

    on_exit(fn ->
      restore_env(:generation_auto_retry_backoff_ms, previous_backoff)
      restore_env(:generation_auto_retry_jitter_ratio, previous_jitter)
    end)

    %{user: actor} = user_fixture()
    {:ok, attempts} = start_supervised({Agent, fn -> 0 end})

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Initial request", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "Initial request"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: assistant_message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: RetryThenWaitAdapter,
      request_payload: raw_request,
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      supports_steering: true,
      attempts: attempts,
      test_pid: self()
    }

    pid = start_supervised!({Worker, %{context: context}})
    monitor_ref = Process.monitor(pid)

    assert_receive {:retry_stream_started, 1, _first_task, ^raw_request}, 1_000
    assert_receive {:retry_stale_emitter, stale_emitter}, 1_000
    _message = wait_for_step_count!(assistant_message.id, actor, 2, 2_000)

    send(stale_emitter, :emit)
    Process.sleep(50)

    assert %{status: :generating} = Worker.get_current_state(pid)

    assert {:ok, %{}} = Worker.steer(pid, "Retry with steering")
    assert_receive {:retry_stream_started, 2, second_task, _request}, 1_000

    send(pid, :retry_current_step)
    refute_receive {:retry_stream_started, 3, _task, _request}, 100

    send(second_task, {:fail, "Second retryable failure"})
    message = wait_for_step_count!(assistant_message.id, actor, 3, 2_000)

    steps = Enum.sort_by(message.steps, & &1.sequence)
    assert retry_attempt(Enum.at(steps, 1)) == 2

    Worker.cancel(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000
  end

  defp item_text(item) do
    item.contents
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", &to_string(&1.content_text || ""))
  end

  defp wait_for_step_count!(message_id, actor, count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_step_count!(message_id, actor, count, deadline)
  end

  defp do_wait_for_step_count!(message_id, actor, count, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    if length(message.steps) >= count do
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_step_count!(message_id, actor, count, deadline)
      else
        flunk("Generation did not persist #{count} steps")
      end
    end
  end

  defp retry_attempt(step) do
    step.items
    |> Enum.flat_map(& &1.contents)
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.map(& &1.content_json)
    |> Enum.find_value(fn
      %{"attempt" => attempt, "retryable" => true} -> attempt
      _other -> nil
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)
end
