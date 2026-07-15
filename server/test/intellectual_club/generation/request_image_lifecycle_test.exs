defmodule IntellectualClub.Generation.RequestImageLifecycleTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatMessageStepRequestFile
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.Worker

  require Ash.Query

  defmodule SteeringAdapter do
    @moduledoc false

    alias IntellectualClub.Generation.RequestImages

    def inject_steering(raw_request, steering_items, _context) do
      steering_input =
        Enum.map(steering_items, fn item ->
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => Map.fetch!(item, :text)}]
          }
        end)

      raw_request = Map.update(raw_request, "input", steering_input, &(&1 ++ steering_input))
      %{raw_request: raw_request, request_snapshot: request_snapshot(raw_request)}
    end

    def request_snapshot(raw_request) do
      %{model_input: Map.get(raw_request, "input", []), system_prompt: "", history_length: nil}
    end

    def stream_generate(opts, emit) do
      context = Map.fetch!(opts, :context)
      logical_request = Map.fetch!(opts, :request_payload)
      step_id = Map.fetch!(opts, :request_step_id)
      attempt = Agent.get_and_update(context.attempts, &{&1 + 1, &1 + 1})
      {:ok, wire_request} = RequestImages.hydrate(logical_request, step_id)

      send(
        context.test_pid,
        {:steering_request, attempt, self(), step_id, logical_request, wire_request}
      )

      receive do
        :complete ->
          emit.({:trace, {:set_text, "answer", :answer, 1, "Completed after steering."}})

          emit.(
            {:response_complete,
             %{
               raw_request: logical_request,
               raw_response: %{"id" => "steering-complete", "output" => []}
             }}
          )
      end

      :ok
    end
  end

  defmodule RetryOnceAdapter do
    @moduledoc false

    def stream_generate(opts, emit) do
      context = Map.fetch!(opts, :context)
      logical_request = Map.fetch!(opts, :request_payload)
      step_id = Map.fetch!(opts, :request_step_id)
      attempt = Agent.get_and_update(context.attempts, &{&1 + 1, &1 + 1})

      send(context.test_pid, {:retry_request, attempt, step_id, logical_request})

      if attempt == 1 do
        emit.(
          {:response_error,
           %{
             retryable: true,
             error_kind: "network",
             status_code: 503,
             error_text: "Retry once",
             raw_request: logical_request
           }}
        )
      else
        receive do
          :complete ->
            emit.({:trace, {:set_text, "answer", :answer, 1, "Recovered."}})

            emit.(
              {:response_complete,
               %{
                 raw_request: logical_request,
                 raw_response: %{"id" => "retry-complete", "output" => []}
               }}
            )
        end
      end

      :ok
    end
  end

  defmodule ToolFollowupAdapter do
    @moduledoc false

    def build_followup_request(opts) do
      runtime_step = Map.fetch!(opts, :runtime_step)

      %{
        runtime_step: runtime_step,
        raw_request: runtime_step.raw_request,
        request_snapshot: request_snapshot(runtime_step.raw_request)
      }
    end

    def request_snapshot(raw_request) do
      %{model_input: Map.get(raw_request, "input", []), system_prompt: "", history_length: nil}
    end

    def stream_generate(opts, emit) do
      context = Map.fetch!(opts, :context)
      logical_request = Map.fetch!(opts, :request_payload)
      step_id = Map.fetch!(opts, :request_step_id)
      attempt = Agent.get_and_update(context.attempts, &{&1 + 1, &1 + 1})

      send(context.test_pid, {:tool_request, attempt, step_id, logical_request})

      if attempt == 1 do
        call_id = "call_image_followup"
        args_json = Jason.encode!(%{"value" => "one"})

        emit.({:trace, {:ensure_item, "tc:" <> call_id, :tool_call, 1}})

        emit.(
          {:trace,
           {:set_opaque, "tc:" <> call_id, :tool_call, 10_000,
            %{
              "tool_call_id" => call_id,
              "call_id" => call_id,
              "name" => "demo__echo",
              "raw" => %{
                "id" => call_id,
                "type" => "function",
                "function" => %{"name" => "demo__echo", "arguments" => args_json}
              }
            }}}
        )

        emit.(
          {:response_complete,
           %{
             raw_request: logical_request,
             raw_response: %{"id" => "tool-step", "output" => []}
           }}
        )
      else
        receive do
          :complete ->
            emit.({:trace, {:set_text, "answer", :answer, 1, "Follow-up completed."}})

            emit.(
              {:response_complete,
               %{
                 raw_request: logical_request,
                 raw_response: %{"id" => "followup-complete", "output" => []}
               }}
            )
        end
      end

      :ok
    end
  end

  setup do
    previous_backoff = Application.get_env(:intellectual_club, :generation_auto_retry_backoff_ms)
    previous_jitter = Application.get_env(:intellectual_club, :generation_auto_retry_jitter_ratio)

    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [0])
    Application.put_env(:intellectual_club, :generation_auto_retry_jitter_ratio, 0.0)

    on_exit(fn ->
      restore_env(:generation_auto_retry_backoff_ms, previous_backoff)
      restore_env(:generation_auto_retry_jitter_ratio, previous_jitter)
    end)

    :ok
  end

  test "Worker persists compact raw, hydrates only for transport, and reuses a binding on steering" do
    %{actor: actor, assistant_message: message, raw_request: raw_request, step_id: step_id} =
      create_generation!(image_payload())

    {:ok, attempts} = start_supervised({Agent, fn -> 0 end})

    context =
      worker_context(actor, message, step_id, raw_request, SteeringAdapter,
        attempts: attempts,
        supports_steering: true
      )

    pid = start_supervised!({Worker, %{context: context}})
    monitor_ref = Process.monitor(pid)

    assert_receive {:steering_request, 1, _first_task, ^step_id, compact_request, wire_request},
                   2_000

    assert compact_request == raw_request
    assert compact_image_url(compact_request) == compact_image_url(raw_request)
    assert wire_image_url(wire_request) =~ "data:image/png;base64,"
    refute inspect(compact_request) =~ ";base64,"

    [initial_binding] = bindings_for_step(step_id)

    assert {:ok, %{step_id: ^step_id}} = Worker.steer(pid, "Use the image carefully")

    assert_receive {:steering_request, 2, _second_task, ^step_id, steered_request,
                    steered_wire_request},
                   2_000

    assert wire_image_url(steered_wire_request) == wire_image_url(wire_request)
    refute inspect(steered_request) =~ ";base64,"

    [steered_binding] = bindings_for_step(step_id)
    assert steered_binding.id == initial_binding.id
    assert steered_binding.file_id == initial_binding.file_id

    Worker.cancel(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000

    persisted_step = Ash.get!(ChatMessageStep, step_id, actor: actor)
    assert compact_image_url(persisted_step.raw_request) == compact_image_url(raw_request)
    refute inspect(persisted_step.raw_request) =~ ";base64,"
  end

  test "auto-retry pins the stable image reference with a separate logical file per step" do
    %{actor: actor, assistant_message: message, raw_request: raw_request, step_id: first_step_id} =
      create_generation!(image_payload())

    {:ok, attempts} = start_supervised({Agent, fn -> 0 end})

    context =
      worker_context(actor, message, first_step_id, raw_request, RetryOnceAdapter,
        attempts: attempts
      )

    pid = start_supervised!({Worker, %{context: context}})
    monitor_ref = Process.monitor(pid)

    assert_receive {:retry_request, 1, ^first_step_id, first_request}, 2_000
    assert_receive {:retry_request, 2, second_step_id, second_request}, 2_000
    assert second_step_id != first_step_id
    assert compact_image_url(second_request) == compact_image_url(first_request)

    Worker.cancel(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000

    [first_binding] = bindings_for_step(first_step_id)
    [second_binding] = bindings_for_step(second_step_id)

    assert first_binding.reference_key == second_binding.reference_key
    assert first_binding.source_file_external_id == second_binding.source_file_external_id
    assert first_binding.file_id != second_binding.file_id
    assert first_binding.file.sha256 == second_binding.file.sha256

    assert Enum.all?([first_step_id, second_step_id], fn id ->
             step = Ash.get!(ChatMessageStep, id, actor: actor)
             compact_image_url(step.raw_request) == compact_image_url(raw_request)
           end)
  end

  test "tool follow-up pins the same reference with an independent logical file" do
    %{actor: actor, assistant_message: message, raw_request: raw_request, step_id: first_step_id} =
      create_generation!(image_payload())

    {:ok, attempts} = start_supervised({Agent, fn -> 0 end})

    context =
      worker_context(actor, message, first_step_id, raw_request, ToolFollowupAdapter,
        attempts: attempts,
        max_tool_rounds: 0
      )

    pid = start_supervised!({Worker, %{context: context}})
    monitor_ref = Process.monitor(pid)

    assert_receive {:tool_request, 1, ^first_step_id, first_request}, 2_000
    assert_receive {:tool_request, 2, second_step_id, second_request}, 2_000
    assert second_step_id != first_step_id
    assert compact_image_url(second_request) == compact_image_url(first_request)

    Worker.cancel(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000

    [first_binding] = bindings_for_step(first_step_id)
    [second_binding] = bindings_for_step(second_step_id)

    assert first_binding.reference_key == second_binding.reference_key
    assert first_binding.file_id != second_binding.file_id
    assert first_binding.file.sha256 == second_binding.file.sha256
  end

  test "manual retry atomically replaces an oversized rendition without losing its blob" do
    %{actor: actor, assistant_message: message, raw_request: raw_request, step_id: old_step_id} =
      create_generation!(oversized_image_payload())

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, old_step_id)

    [old_binding] = bindings_for_step(old_step_id)
    old_file_id = old_binding.file_id
    rendition_sha = old_binding.file.sha256

    assert old_binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
    assert FilesystemStorage.exists?(rendition_sha)

    new_step_id =
      Persistence.replace_steps_for_retry!(message.id, 1, compact_request)

    assert new_step_id != old_step_id
    assert {:error, _error} = Ash.get(ChatMessageStep, old_step_id, actor: actor)
    assert {:error, _error} = Ash.get(StoredFile, old_file_id, authorize?: false)

    [new_binding] = bindings_for_step(new_step_id)

    assert new_binding.reference_key == old_binding.reference_key
    assert new_binding.source_file_external_id == old_binding.source_file_external_id
    assert new_binding.variant_key == old_binding.variant_key
    assert new_binding.file_id != old_binding.file_id
    assert new_binding.file.sha256 == rendition_sha
    assert FilesystemStorage.exists?(rendition_sha)

    replacement = Ash.get!(ChatMessageStep, new_step_id, actor: actor)
    assert replacement.sequence == 1
    assert replacement.status == :waiting_provider
    assert replacement.raw_request == compact_request
  end

  test "retry replacement rollback after staged attachment preserves the old step and rendition" do
    %{actor: actor, assistant_message: message, raw_request: raw_request, step_id: old_step_id} =
      create_generation!(oversized_image_payload())

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, old_step_id)

    [old_binding] = bindings_for_step(old_step_id)
    rendition_sha = old_binding.file.sha256
    file_count_before = count_files_for_sha(rendition_sha)

    assert_raise BadMapError, fn ->
      Persistence.replace_steps_for_retry!(message.id, 1, compact_request, [42])
    end

    assert Ash.get!(ChatMessageStep, old_step_id, actor: actor).id == old_step_id

    [restored_binding] = bindings_for_step(old_step_id)
    assert restored_binding.id == old_binding.id
    assert restored_binding.file_id == old_binding.file_id
    assert restored_binding.file.sha256 == rendition_sha
    assert count_files_for_sha(rendition_sha) == file_count_before
    assert FilesystemStorage.exists?(rendition_sha)

    message = Ash.get!(ChatMessage, message.id, actor: actor, load: [:steps])
    assert Enum.map(message.steps, &{&1.id, &1.sequence}) == [{old_step_id, 1}]
  end

  defp create_generation!(payload) do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, source_file} = Files.create_from_binary("request-image.png", "image/png", payload)

    {:ok, user_message} =
      Threads.add_message_to_end(chat, :user, "Inspect the attached image",
        actor: actor,
        contents: [
          %{kind: :text, content_text: "Inspect the attached image"},
          %{kind: :media, file_id: source_file.id}
        ]
      )

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = responses_request(source_file)
    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    %{
      actor: actor,
      chat: chat,
      assistant_message: assistant_message,
      source_file: source_file,
      raw_request: raw_request,
      step_id: step_id
    }
  end

  defp worker_context(actor, message, step_id, raw_request, adapter, opts) do
    %{
      owner_id: actor.id,
      chat_id: message.chat_id,
      message_id: message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: adapter,
      request_payload: raw_request,
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      supports_steering: Keyword.get(opts, :supports_steering, false),
      attempts: Keyword.fetch!(opts, :attempts),
      test_pid: self(),
      max_tool_rounds: Keyword.get(opts, :max_tool_rounds, 8),
      context_length: nil,
      context_soft_limit_percent: nil,
      tool_instances_by_alias: %{},
      tools_payload: []
    }
  end

  defp responses_request(source_file) do
    marker = RequestImages.marker(to_string(source_file.external_id), "image/png", :data_url)

    %{
      "model" => "test-model",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => marker}]
        }
      ]
    }
  end

  defp bindings_for_step(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:file)
    |> Ash.read!(authorize?: false)
  end

  defp count_files_for_sha(sha256) do
    StoredFile
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp compact_image_url(request),
    do: get_in(request, ["input", Access.at(0), "content", Access.at(0), "image_url"])

  defp wire_image_url(request),
    do: get_in(request, ["input", Access.at(0), "content", Access.at(0), "image_url"])

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp oversized_image_payload do
    assert {:ok, image} = Image.new(2_100, 10)
    assert {:ok, payload} = Image.write(image, :memory, suffix: ".png")
    payload
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)
end
