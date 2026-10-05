defmodule IntellectualClub.Generation.RequestImageLifecycleTest do
  @moduledoc """
  Request images across the generation worker lifecycle: transport-only
  hydration, steering, auto-retry and tool follow-up steps, and retry step
  replacement in persistence.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Generation.RequestImageCacheTestHelpers

  require Ash.Query

  alias IntellectualClub.Chat.{ChatMessage, ChatMessageStep, ChatMessageStepRequestFile}
  alias IntellectualClub.Chat.{QueuedMessages, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Generation.{Lease, Persistence, RequestImages, StepRequests, Worker}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.GenerationContext.ImageLifecycleAdapters, as: Adapters

  setup do
    put_app_env(:generation_auto_retry_backoff_ms, [0])
    put_app_env(:generation_auto_retry_jitter_ratio, 0.0)
    :ok
  end

  describe "Worker" do
    test "hydrates only for transport and steering pins an independent immutable file" do
      %{actor: actor, message: message, raw_request: raw_request, step_id: step_id} =
        generation = create_generation!(png_1x1())

      telemetry = observe_image_cache()
      context = worker_context(generation, Adapters.Steering, request_images: true)
      pid = start_worker_with_lease!(message.id, context)
      monitor_ref = Process.monitor(pid)

      assert_receive {:image_request, 1, _task, ^step_id, compact_request, wire_request}, 2_000
      assert compact_request == raw_request
      assert image_url(wire_request) =~ "data:image/png;base64,"
      refute inspect(compact_request) =~ ";base64,"
      assert_public_state_compact(pid, message.id, raw_request)
      assert_warm_cache_counters(telemetry)
      [initial_binding] = bindings_for_step(step_id)

      assert {:ok, queued} =
               QueuedMessages.enqueue_steer(message.id, "Use the image carefully", actor)

      Worker.queue_changed(pid)

      assert_receive {:image_request, 2, _task, receiving_step_id, steered_request, steered_wire},
                     2_000

      refute receiving_step_id == step_id
      assert {:ok, %{status: :delivered}} = QueuedMessages.get(queued.id, actor)
      assert image_url(steered_wire) == image_url(wire_request)
      assert_public_state_compact(pid, message.id, steered_request)
      assert_warm_cache_counters(telemetry)

      [steered_binding] = bindings_for_step(receiving_step_id)
      refute steered_binding.id == initial_binding.id
      refute steered_binding.file_id == initial_binding.file_id
      assert steered_binding.reference_key == initial_binding.reference_key
      assert steered_binding.file.sha256 == initial_binding.file.sha256
      assert [preserved_binding] = bindings_for_step(step_id)
      assert preserved_binding.id == initial_binding.id

      Worker.cancel(pid)
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000

      persisted_step = load_step_raw!(step_id, actor)
      assert image_url(persisted_step.raw_request) == image_url(raw_request)
      refute inspect(persisted_step.raw_request) =~ ";base64,"
    end

    # Without prepared request images the worker hydrates cold once; with them
    # (as after a fresh publication) every hydration is served from the cache.
    for {name, adapter, worker_opts, prepared?} <- [
          {"an auto-retry", Adapters.RetryOnce, [], false},
          {"a tool follow-up", Adapters.ToolFollowup, [request_images: true, max_tool_rounds: 0],
           true}
        ] do
      test "#{name} reuses the wire cache and pins a separate logical file for its new step" do
        %{actor: actor, message: message, raw_request: raw_request, step_id: first_step_id} =
          generation = create_generation!(png_1x1())

        telemetry = observe_image_cache()
        context = worker_context(generation, unquote(adapter), unquote(worker_opts))
        pid = start_worker_with_lease!(message.id, context)
        monitor_ref = Process.monitor(pid)

        assert_receive {:image_request, 1, _task, ^first_step_id, first_request, first_wire},
                       2_000

        assert_receive {:image_request, 2, _task, second_step_id, second_request, second_wire},
                       2_000

        assert second_step_id != first_step_id
        assert image_url(second_request) == image_url(first_request)
        assert first_wire == second_wire
        refute inspect(first_request) =~ ";base64,"
        assert_public_state_compact(pid, message.id, second_request)

        if unquote(prepared?) do
          assert_warm_cache_counters(telemetry)
        else
          assert %{loaded_bytes: loaded, miss: 1, hit: hits, encoded_bytes: encoded} =
                   image_cache_counters(telemetry)

          assert loaded == byte_size(png_1x1())
          assert encoded == byte_size(image_url(first_wire))
          assert hits > 0
        end

        Worker.cancel(pid)
        assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000

        [first_binding] = bindings_for_step(first_step_id)
        [second_binding] = bindings_for_step(second_step_id)
        assert first_binding.reference_key == second_binding.reference_key
        assert first_binding.source_file_external_id == second_binding.source_file_external_id
        assert first_binding.file_id != second_binding.file_id
        assert first_binding.file.sha256 == second_binding.file.sha256

        for step_id <- [first_step_id, second_step_id] do
          assert image_url(load_step_raw!(step_id, actor).raw_request) == image_url(raw_request)
        end
      end
    end
  end

  describe "Persistence.replace_steps_for_retry!/6" do
    test "atomically replaces an oversized rendition pin without losing its blob" do
      %{actor: actor, message: message, raw_request: raw_request, step_id: old_step_id} =
        create_generation!(oversized_image_payload())

      assert :ok =
               RequestImages.validate_snapshot(raw_request, old_step_id,
                 mapper: &Adapters.Steering.map_request_images/3
               )

      compact_request = raw_request

      [old_binding] = bindings_for_step(old_step_id)
      old_file_id = old_binding.file_id
      rendition_sha = old_binding.file.sha256

      assert old_binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
      assert FilesystemStorage.exists?(rendition_sha)

      new_step_id =
        Persistence.replace_steps_for_retry!(message.id, 1, compact_request, [], nil,
          request_context: %{adapter_module: Adapters.Steering}
        )

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

      replacement = load_step_raw!(new_step_id, actor)
      assert replacement.sequence == 1
      assert replacement.status == :waiting_provider
      assert replacement.raw_request == compact_request
    end

    test "a rollback after staged attachment preserves the old step and rendition" do
      %{actor: actor, message: message, raw_request: raw_request, step_id: old_step_id} =
        create_generation!(oversized_image_payload())

      assert :ok =
               RequestImages.validate_snapshot(raw_request, old_step_id,
                 mapper: &Adapters.Steering.map_request_images/3
               )

      compact_request = raw_request

      [old_binding] = bindings_for_step(old_step_id)
      rendition_sha = old_binding.file.sha256
      file_count_before = count_files_for_sha(rendition_sha)

      assert_raise BadMapError, fn ->
        Persistence.replace_steps_for_retry!(message.id, 1, compact_request, [42], nil,
          request_context: %{adapter_module: Adapters.Steering}
        )
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
  end

  defp assert_warm_cache_counters(telemetry) do
    assert %{loaded_bytes: 0, miss: 0, encoded_bytes: 0, hit: hits} =
             image_cache_counters(telemetry)

    assert hits > 0
  end

  defp assert_public_state_compact(pid, message_id, request) do
    state = :sys.get_state(pid)
    assert state.runtime_step.raw_request == request
    assert state.context.request_payload == request
    assert_wire_cache(state.image_cache, png_1x1())
    refute inspect(request) =~ ";base64,"

    snapshot = Worker.get_current_state(pid)
    assert {:ok, stored_snapshot} = GenerationSupervisor.poll_generation(message_id)

    for public <- [snapshot, stored_snapshot] do
      refute Map.has_key?(public, :image_cache)
      refute Map.has_key?(public, :request_images)
      refute inspect(public) =~ Base.encode64(png_1x1())
    end
  end

  defp create_generation!(payload) do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    {:ok, source_file} = Files.create_from_binary("request-image.png", "image/png", payload)

    {:ok, user_message} =
      Threads.add_message_to_end(chat, :user, "Inspect the attached image",
        actor: actor,
        contents: [
          %{kind: :text, content_text: "Inspect the attached image"},
          %{kind: :media, file_id: source_file.id}
        ]
      )

    message = create_generating_message!(actor, chat, parent_id: user_message.id, token_count: 0)
    marker = RequestImages.marker(to_string(source_file.external_id), "image/png", :data_url)

    raw_request = %{
      "model" => "test-model",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => marker}]
        }
      ]
    }

    %{step: step, request: raw_request, request_images: request_images} =
      Persistence.create_request_step!(message, 1, raw_request,
        request_context: %{adapter_module: Adapters.Steering}
      )

    %{
      actor: actor,
      message: message,
      raw_request: raw_request,
      request_images: request_images,
      step_id: step.id
    }
  end

  # `request_images: true` hands the worker the request images prepared at publication.
  defp worker_context(generation, adapter, opts) do
    %{
      owner_id: generation.actor.id,
      chat_id: generation.message.chat_id,
      message_id: generation.message.id,
      step_id: generation.step_id,
      provider_type: "test",
      adapter_module: adapter,
      request_payload: generation.raw_request,
      request_images: if(opts[:request_images], do: generation.request_images),
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      attempts: start_supervised!({Agent, fn -> 0 end}),
      test_pid: self(),
      max_tool_rounds: Keyword.get(opts, :max_tool_rounds, 8),
      context_length: nil,
      context_soft_limit_percent: nil,
      tool_instances_by_alias: %{},
      tools_payload: []
    }
  end

  defp start_worker_with_lease!(message_id, context) do
    assert {:ok, lease} = Lease.acquire(message_id)

    start_supervised!(%{
      id: {Worker, message_id, make_ref()},
      start: {Worker, :start_link, [%{context: context, lease: lease, lease_owner: self()}]},
      restart: :temporary
    })
  end

  defp bindings_for_step(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:file)
    |> Ash.read!(authorize?: false)
  end

  defp load_step_raw!(step_id, actor) do
    ChatMessageStep
    |> Ash.Query.filter(id == ^step_id)
    |> Ash.Query.select([:id, :sequence, :status, :raw_request, :raw_response])
    |> Ash.read_one!(actor: actor)
    |> Map.put(:raw_request, StepRequests.request_for_step!(step_id, actor: actor))
  end

  defp count_files_for_sha(sha256) do
    StoredFile
    |> Ash.Query.filter(sha256 == ^sha256)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp image_url(request),
    do: get_in(request, ["input", Access.at(0), "content", Access.at(0), "image_url"])

  defp oversized_image_payload, do: IntellectualClub.ImageFixtures.png(2_100, 10)
end
