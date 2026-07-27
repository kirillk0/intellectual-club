defmodule IntellectualClub.Generation.QueueTerminalSemanticsTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.QueueCoordinator
  alias IntellectualClub.Generation.QueueDispatcher
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  for initial_status <- [:error, :canceled] do
    @initial_status initial_status

    test "retrying a #{@initial_status} generation preserves a non-empty backlog and advances one turn" do
      %{user: actor} = user_fixture()

      scripts = [
        {:reply, 200, successful_sse("Recovered answer")},
        {:block, self()}
      ]

      base_url = start_scripted_server!(scripts)
      configuration = create_steering_configuration!(actor, base_url)

      {chat, generation, initial_step} =
        create_generation!(actor, configuration.id, "Retry source")

      assert {:ok, first} =
               QueuedMessages.enqueue_follow_up(
                 chat.id,
                 %{content: "First after retry"},
                 actor
               )

      assert {:ok, second} =
               QueuedMessages.enqueue_follow_up(
                 chat.id,
                 %{content: "Second after retry"},
                 actor
               )

      set_step_status!(initial_step, @initial_status, actor)
      set_generation_status!(generation, @initial_status, actor)

      assert {:blocked, %{status: @initial_status}} =
               QueueDispatcher.generation_finished(generation.id, @initial_status)

      expected_reason = terminal_reason(@initial_status)
      assert_queue_state!(first.id, actor, :blocked, expected_reason)
      assert_queue_state!(second.id, actor, :blocked, expected_reason)

      assert {:ok, %{message_id: generation_id}} =
               GenerationSupervisor.retry_last_step(generation.id,
                 actor: actor,
                 chunk_delay_ms: 0
               )

      assert generation_id == generation.id

      assert_receive {:blocked_provider_request, blocked_request_pid, request_payload}, 5_000
      assert Jason.encode!(request_payload) =~ "First after retry"

      retried = wait_for_status!(generation.id, actor, :done)
      assert retried.status == :done
      assert {:error, _error} = Ash.get(ChatMessageStep, initial_step.id, actor: actor)

      assert {:ok, delivered_first} = QueuedMessages.get(first.id, actor)
      assert {:ok, pending_second} = QueuedMessages.get(second.id, actor)

      assert delivered_first.status == :delivered
      assert is_integer(delivered_first.user_message_id)
      assert is_integer(delivered_first.assistant_message_id)
      assert pending_second.status == :pending
      assert pending_second.blocked_reason == nil
      assert pending_second.anchor_message_id == delivered_first.assistant_message_id

      first_user = load_message_trace!(delivered_first.user_message_id, actor)
      assert canonical_text(first_user) == "First after retry"

      assert :ok = GenerationSupervisor.cancel_generation(delivered_first.assistant_message_id)
      send(blocked_request_pid, :finish)

      assert wait_for_status!(delivered_first.assistant_message_id, actor, :canceled).status ==
               :canceled

      assert_queue_state!(second.id, actor, :blocked, "generation_canceled")
    end
  end

  for {terminal_status, expected_status, expected_reason} <- [
        {:done, :pending, nil},
        {:error, :blocked, "generation_error"},
        {:canceled, :blocked, "generation_canceled"}
      ] do
    @terminal_status terminal_status
    @expected_queue_status expected_status
    @expected_block_reason expected_reason

    test "a pending steer that loses the terminal race becomes a follow-up after #{@terminal_status}" do
      %{user: actor} = user_fixture()
      configuration = create_steering_configuration!(actor, "http://127.0.0.1:9")
      {chat, generation, step} = create_generation!(actor, configuration.id, "Late steer")

      assert {:ok, steer} =
               QueuedMessages.enqueue_steer(
                 generation.id,
                 %{content: "Continue after terminal result"},
                 actor
               )

      set_step_status!(step, @terminal_status, actor)
      set_generation_status!(generation, @terminal_status, actor)

      assert {:ok, %{converted_steers: 1, status: @terminal_status}} =
               QueueCoordinator.settle_generation(generation.id, @terminal_status)

      assert {:ok, converted} = QueuedMessages.get(steer.id, actor)
      assert converted.kind == :follow_up
      assert converted.status == @expected_queue_status
      assert converted.blocked_reason == @expected_block_reason
      assert converted.anchor_message_id == generation.id
      assert converted.target_generation_message_id == nil
      assert converted.steering_item_id == nil

      generation = load_message_trace!(generation.id, actor)
      refute Enum.any?(canonical_items(generation), &(&1.type == :steering))

      case @terminal_status do
        :done ->
          assert {:ok, _context} = QueueCoordinator.prepare_next(chat.id)
          assert {:ok, delivered} = QueuedMessages.get(steer.id, actor)
          assert delivered.status == :delivered

          assert canonical_text(load_message_trace!(delivered.user_message_id, actor)) ==
                   "Continue after terminal result"

        status when status in [:error, :canceled] ->
          assert {:blocked, @expected_block_reason} = QueueCoordinator.prepare_next(chat.id)
      end
    end
  end

  for {terminal_status, expected_status, expected_reason} <- [
        {:done, :pending, nil},
        {:error, :blocked, "generation_error"},
        {:canceled, :blocked, "generation_canceled"}
      ] do
    @enqueue_terminal_status terminal_status
    @enqueued_queue_status expected_status
    @enqueued_block_reason expected_reason

    test "steer enqueued after #{@enqueue_terminal_status} is created directly as a follow-up" do
      %{user: actor} = user_fixture()
      configuration = create_steering_configuration!(actor, "http://127.0.0.1:9")

      {chat, generation, step} =
        create_generation!(actor, configuration.id, "Post-terminal steer")

      set_step_status!(step, @enqueue_terminal_status, actor)
      set_generation_status!(generation, @enqueue_terminal_status, actor)

      assert {:ok, queued_message} =
               QueuedMessages.enqueue_steer(
                 generation.id,
                 %{content: "Arrived after terminal persistence"},
                 actor
               )

      assert queued_message.chat_id == chat.id
      assert queued_message.kind == :follow_up
      assert queued_message.status == @enqueued_queue_status
      assert queued_message.blocked_reason == @enqueued_block_reason
      assert queued_message.anchor_message_id == generation.id
      assert queued_message.target_generation_message_id == nil
      assert queued_message.steering_item_id == nil

      assert QueuedMessages.content_specs(queued_message) == [
               %{kind: :text, content_text: "Arrived after terminal persistence"}
             ]
    end
  end

  for {terminal_status, expected_status, expected_reason} <- [
        {:done, :delivered, nil},
        {:error, :blocked, "generation_error"},
        {:canceled, :blocked, "generation_canceled"}
      ] do
    @recovered_terminal_status terminal_status
    @recovered_queue_status expected_status
    @recovered_block_reason expected_reason

    test "reconciliation recovers a lone late steer after #{@recovered_terminal_status}" do
      %{user: actor} = user_fixture()
      configuration = create_steering_configuration!(actor, "http://127.0.0.1:9")

      {chat, generation, step} =
        create_generation!(actor, configuration.id, "Recovered late steer")

      assert {:ok, steer} =
               QueuedMessages.enqueue_steer(
                 generation.id,
                 %{content: "Recover after process loss"},
                 actor
               )

      set_step_status!(step, @recovered_terminal_status, actor)
      set_generation_status!(generation, @recovered_terminal_status, actor)

      assert chat.id in QueueCoordinator.ready_chat_ids()

      case @recovered_terminal_status do
        :done ->
          assert {:ok, _context} = QueueCoordinator.prepare_next(chat.id)

        status when status in [:error, :canceled] ->
          assert {:blocked, @recovered_block_reason} = QueueCoordinator.prepare_next(chat.id)
      end

      assert {:ok, recovered} = QueuedMessages.get(steer.id, actor)
      assert recovered.kind == :follow_up
      assert recovered.status == @recovered_queue_status
      assert recovered.blocked_reason == @recovered_block_reason
      assert recovered.target_generation_message_id == nil
      assert recovered.anchor_message_id == generation.id
    end
  end

  test "handoff moves a late steer behind the existing backlog and waits for the child generation" do
    %{user: actor} = user_fixture()
    configuration = create_steering_configuration!(actor, "http://127.0.0.1:9")

    {source_chat, source_generation, source_step} =
      create_generation!(actor, configuration.id, "Source generation")

    assert {:ok, first} =
             QueuedMessages.enqueue_follow_up(
               source_chat.id,
               %{content: "Existing follow-up"},
               actor
             )

    assert {:ok, late_steer} =
             QueuedMessages.enqueue_steer(
               source_generation.id,
               %{content: "Late handoff steer"},
               actor
             )

    {child_chat, child_generation, child_step} =
      create_generation!(actor, configuration.id, "Handoff child",
        parent_chat_id: source_chat.id,
        parent_message_id: source_generation.id,
        parent_relation_kind: :handoff,
        subagent: true
      )

    set_step_status!(source_step, :done, actor)
    set_generation_status!(source_generation, :done, actor)

    assert {:ok, %{transferred_count: 2}} =
             QueueCoordinator.transfer_to_handoff(
               source_generation.id,
               child_chat.id,
               child_generation.id
             )

    assert {:ok, []} = QueuedMessages.list_for_chat(source_chat.id, actor)
    assert {:ok, transferred} = QueuedMessages.list_for_chat(child_chat.id, actor)
    assert Enum.map(transferred, & &1.id) == [first.id, late_steer.id]

    assert {:ok, transferred_first} = QueuedMessages.get(first.id, actor)
    assert {:ok, transferred_steer} = QueuedMessages.get(late_steer.id, actor)

    assert transferred_first.kind == :follow_up
    assert transferred_first.anchor_message_id == child_generation.id
    assert transferred_steer.kind == :follow_up
    assert transferred_steer.status == :pending
    assert transferred_steer.anchor_message_id == child_generation.id
    assert transferred_steer.target_generation_message_id == nil

    assert QueuedMessages.content_specs(transferred_steer) == [
             %{kind: :text, content_text: "Late handoff steer"}
           ]

    assert :active = QueueCoordinator.prepare_next(child_chat.id)

    set_step_status!(child_step, :done, actor)
    set_generation_status!(child_generation, :done, actor)

    assert {:ok, %{status: :done}} =
             QueueCoordinator.settle_generation(child_generation.id, :done)

    assert {:ok, next_context} = QueueCoordinator.prepare_next(child_chat.id)
    assert {:ok, delivered_first} = QueuedMessages.get(first.id, actor)
    assert {:ok, pending_steer} = QueuedMessages.get(late_steer.id, actor)

    assert delivered_first.status == :delivered
    assert delivered_first.assistant_message_id == next_context.message_id
    assert pending_steer.status == :pending
    assert pending_steer.anchor_message_id == next_context.message_id
  end

  test "steer submitted after a terminal handoff is queued in the active child chat" do
    %{user: actor} = user_fixture()
    configuration = create_steering_configuration!(actor, "http://127.0.0.1:9")

    {source_chat, source_generation, source_step} =
      create_generation!(actor, configuration.id, "Completed handoff source")

    {child_chat, child_generation, _child_step} =
      create_generation!(actor, configuration.id, "Active handoff child",
        parent_chat_id: source_chat.id,
        parent_message_id: source_generation.id,
        parent_relation_kind: :handoff,
        subagent: true
      )

    set_step_status!(source_step, :done, actor)
    set_generation_status!(source_generation, :done, actor)
    persist_committed_handoff_result!(source_step, child_chat, child_generation, actor)

    assert {:ok, queued_message} =
             QueuedMessages.enqueue_steer(
               source_generation.id,
               %{content: "Continue in the handoff child"},
               actor
             )

    assert queued_message.chat_id == child_chat.id
    assert queued_message.kind == :follow_up
    assert queued_message.status == :pending
    assert queued_message.anchor_message_id == child_generation.id
    assert queued_message.target_generation_message_id == nil

    assert {:ok, []} = QueuedMessages.list_for_chat(source_chat.id, actor)
    assert {:ok, [listed]} = QueuedMessages.list_for_chat(child_chat.id, actor)
    assert listed.id == queued_message.id
    assert :active = QueueCoordinator.prepare_next(child_chat.id)
  end

  test "steer submitted after a committed manual handoff is queued in its child chat" do
    %{user: actor} = user_fixture()
    configuration = create_steering_configuration!(actor, "http://127.0.0.1:9")

    {source_chat, source_generation, source_step} =
      create_generation!(actor, configuration.id, "Completed manual handoff source")

    {child_chat, child_generation, _child_step} =
      create_generation!(actor, configuration.id, "Manual handoff child",
        parent_chat_id: source_chat.id,
        parent_message_id: source_generation.id,
        parent_relation_kind: :handoff,
        subagent: true
      )

    set_step_status!(source_step, :done, actor)
    set_generation_status!(source_generation, :done, actor)

    assert {:ok, queued_message} =
             QueuedMessages.enqueue_steer(
               source_generation.id,
               %{content: "Continue after manual handoff"},
               actor
             )

    assert queued_message.chat_id == child_chat.id
    assert queued_message.kind == :follow_up
    assert queued_message.status == :pending
    assert queued_message.anchor_message_id == child_generation.id
    assert {:ok, []} = QueuedMessages.list_for_chat(source_chat.id, actor)
  end

  test "late steer after canceled uncommitted handoff stays blocked in the source chat" do
    %{user: actor} = user_fixture()
    configuration = create_steering_configuration!(actor, "http://127.0.0.1:9")

    {source_chat, source_generation, source_step} =
      create_generation!(actor, configuration.id, "Canceled handoff source")

    child_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          llm_configuration_id: configuration.id,
          parent_chat_id: source_chat.id,
          parent_message_id: source_generation.id,
          parent_relation_kind: :handoff,
          subagent: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _child_root} =
      Threads.add_message_to_end(child_chat, :user, "Uncommitted handoff", actor: actor)

    set_step_status!(source_step, :canceled, actor)
    set_generation_status!(source_generation, :canceled, actor)

    assert {:ok, queued_message} =
             QueuedMessages.enqueue_steer(
               source_generation.id,
               %{content: "Must remain paused after cancel"},
               actor
             )

    assert queued_message.chat_id == source_chat.id
    assert queued_message.kind == :follow_up
    assert queued_message.status == :blocked
    assert queued_message.blocked_reason == "generation_canceled"
    assert queued_message.anchor_message_id == source_generation.id

    assert {:ok, []} = QueuedMessages.list_for_chat(child_chat.id, actor)
    assert {:blocked, "generation_canceled"} = QueueCoordinator.prepare_next(source_chat.id)
  end

  defmodule ScriptedSSEPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)
      {:ok, body, conn} = read_body(conn)
      payload = decode_payload(body)

      action =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {{:reply, 500, ["No scripted response"]}, []}
        end)

      case action do
        {:reply, status, chunks} ->
          send_chunks(conn, status, chunks)

        {:block, test_pid} ->
          send(test_pid, {:blocked_provider_request, self(), payload})

          receive do
            :finish -> send_chunks(conn, 409, ["Canceled by test"])
          after
            10_000 -> send_chunks(conn, 504, ["Timed out waiting for test"])
          end
      end
    end

    defp decode_payload(body) do
      case Jason.decode(body) do
        {:ok, %{} = payload} -> payload
        _other -> %{"raw_body" => body}
      end
    end

    defp send_chunks(conn, status, chunks) do
      conn =
        conn
        |> put_resp_content_type(if(status < 400, do: "text/event-stream", else: "text/plain"))
        |> send_chunked(status)

      Enum.reduce_while(List.wrap(chunks), conn, fn chunk, conn ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _reason} -> {:halt, conn}
        end
      end)
    end
  end

  defp start_scripted_server!(scripts) do
    agent = start_supervised!({Agent, fn -> scripts end})
    port = free_port()

    start_supervised!({Bandit, plug: {ScriptedSSEPlug, agent: agent}, scheme: :http, port: port})

    wait_for_server!(port)
    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp wait_for_server!(port) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_wait_for_server!(port, deadline)
  end

  defp do_wait_for_server!(port, deadline) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 50) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Scripted provider did not start before timeout")
        else
          Process.sleep(5)
          do_wait_for_server!(port, deadline)
        end
    end
  end

  defp successful_sse(text) do
    sse_chunks([
      %{
        "id" => "chatcmpl-retry",
        "object" => "chat.completion",
        "created" => 1,
        "model" => "queue-terminal-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => text},
            "finish_reason" => "stop"
          }
        ]
      }
    ])
  end

  defp sse_chunks(objects) do
    Enum.map(objects, fn object -> "data: " <> Jason.encode!(object) <> "\n\n" end) ++
      ["data: [DONE]\n\n"]
  end

  defp create_generation!(actor, configuration_id, prompt, chat_attrs \\ []) do
    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        chat_attrs
        |> Map.new()
        |> Map.merge(%{note: "", llm_configuration_id: configuration_id}),
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, prompt, actor: actor)

    generation =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{
          chat_id: chat.id,
          parent_id: user_message.id,
          llm_configuration_id: configuration_id,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: generation.id,
          sequence: 1,
          status: :waiting_provider,
          raw_request: %{
            "model" => "queue-terminal-model",
            "messages" => [%{"role" => "user", "content" => prompt}],
            "stream" => true
          }
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {chat, generation, step}
  end

  defp create_steering_configuration!(actor, base_url) do
    suffix = System.unique_integer([:positive])

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Queue terminal provider #{suffix}",
          type: :openrouter_chat_completion,
          auth_method: :api_key,
          base_url: base_url,
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "queue-terminal-model",
        note: "",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        supports_steering: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp set_generation_status!(message, status, actor) do
    message
    |> Ash.Changeset.for_update(
      :set_generation_state,
      %{
        status: status,
        error_detail: if(status == :error, do: "test error", else: nil),
        finished_at: if(status == :generating, do: nil, else: DateTime.utc_now())
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp set_step_status!(step, status, actor) do
    step
    |> Ash.Changeset.for_update(
      :update,
      %{
        status: status,
        finished_at: if(status == :waiting_provider, do: nil, else: DateTime.utc_now())
      },
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp persist_committed_handoff_result!(step, child_chat, child_generation, actor) do
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
              "generation_message_id" => child_generation.id
            }
          }
        }
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp wait_for_status!(message_id, actor, expected_status) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_wait_for_status!(message_id, actor, expected_status, deadline)
  end

  defp do_wait_for_status!(message_id, actor, expected_status, deadline) do
    message = Ash.get!(ChatMessage, message_id, actor: actor)

    if message.status == expected_status do
      message
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "Message #{message_id} did not reach #{expected_status}; current status is #{message.status}"
        )
      else
        Process.sleep(10)
        do_wait_for_status!(message_id, actor, expected_status, deadline)
      end
    end
  end

  defp assert_queue_state!(id, actor, status, reason) do
    assert {:ok, queued_message} = QueuedMessages.get(id, actor)
    assert queued_message.status == status
    assert queued_message.blocked_reason == reason
  end

  defp terminal_reason(:error), do: "generation_error"
  defp terminal_reason(:canceled), do: "generation_canceled"

  defp load_message_trace!(message_id, actor) do
    Ash.get!(ChatMessage, message_id,
      actor: actor,
      load: [steps: [items: [:contents]]]
    )
  end

  defp canonical_items(message) do
    message.steps
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(fn step -> Enum.sort_by(step.items, & &1.sequence) end)
  end

  defp canonical_text(message) do
    message
    |> canonical_items()
    |> Enum.flat_map(fn item -> Enum.sort_by(item.contents, & &1.sequence) end)
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join(& &1.content_text)
  end
end
