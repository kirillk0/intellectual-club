defmodule IntellectualClub.Generation.RequestImageLifecycleTest do
  @moduledoc """
  Request images across the generation worker lifecycle: transport-only
  hydration, steering, auto-retry and tool follow-up steps, the reaction to a
  provider rejecting an image, facts about images accepted by the LLM
  configuration, and retry step replacement in persistence.
  """

  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1, with_log: 1]
  import IntellectualClub.Generation.RequestImageCacheTestHelpers
  import IntellectualClub.SqlCapture, only: [capture_queries: 1, selects_from: 2]

  import IntellectualClub.Test.GenerationRuntime,
    only: [command: 2, inject_sql_failure!: 4, with_generation_lease: 2]

  require Ash.Query

  alias IntellectualClub.Chat.{ChatMessage, ChatMessageStep, ChatMessageStepRequestFile}
  alias IntellectualClub.Chat.{QueuedMessages, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.{FilesystemStorage, ImageProviderVerdicts}
  alias IntellectualClub.Generation.{Lease, Persistence, RequestImages, StepRequests, Worker}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.GenerationContext.ImageLifecycleAdapters, as: Adapters
  alias IntellectualClub.Test.GenerationRuntime.Barrier
  alias IntellectualClub.TestSupport.ProviderImageRejections

  @steps_load [steps: [items: [:contents]]]

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

  describe "Worker reaction to a provider rejecting an image" do
    for {name, meta} <- ProviderImageRejections.rejections() do
      @meta meta
      test "#{name} marks the image rejected by the configuration and retries once with text in its place" do
        %{step_id: step_id, files: [file]} = generation = create_generation!(png_1x1())
        pid = start_rejection_worker!(generation, [{:error, @meta}])

        assert_receive {:image_request, 1, _task, ^step_id, _request, wire}, 2_000
        assert image_url(wire) =~ "data:image/png;base64,"
        assert_receive {:image_request, 2, _task, retry_step_id, retry_request, retry_wire}, 2_000
        assert retry_step_id != step_id
        text = assert_rejected_text(retry_request, file)
        assert first_block(retry_wire) == %{"type" => "input_text", "text" => text}
        assert_worker_down!(pid)

        assert %{} = facts = image_provider_verdicts(file.sha256)
        assert [{configuration_id, {:rejected, details}}] = Map.to_list(facts)
        assert configuration_id == generation.configuration_id
        assert details =~ ~r/\Atest: \S/

        message = load_message!(generation)
        assert message.status == :done
        assert [failed, retry] = ordered_steps(message)
        assert {failed.status, retry.status} == {:error, :done}
        assert failed.id == step_id

        assert {retry_text, %{"retry_reason" => "image_rejected", "attempt" => 1}} =
                 retry_error!(failed)

        assert retry_text =~ "The provider rejected an image on attempt 1."
        assert bindings_for_step(retry.id) == []
      end
    end

    test "an error inside a completed response is handled like an error event" do
      %{step_id: step_id, files: [file]} = generation = create_generation!(png_1x1())

      raw =
        ~s({"type":"error","error":{"type":"invalid_request_error",) <>
          ~s("message":"Could not process image"}})

      raw_response = %{
        "error" => %{
          "code" => 400,
          "message" => "Provider returned error",
          "metadata" => %{"raw" => raw}
        }
      }

      pid = start_rejection_worker!(generation, [{:error_response, raw_response}])
      assert_receive {:image_request, 1, _task, ^step_id, _request, _wire}, 2_000
      assert_receive {:image_request, 2, _task, _retry_step_id, retry_request, _wire}, 2_000
      assert_rejected_text(retry_request, file)
      assert_worker_down!(pid)

      assert rejected?(file, generation)
      assert load_message!(generation).status == :done
    end

    for prepared? <- [true, false] do
      @prepared? prepared?
      test "only sent images the configuration has not accepted are blamed (prepared state: #{prepared?})" do
        generation = create_generation!(png_1x1(), extra_images: [png(2, 2)])
        %{files: [accepted, added]} = generation

        :ok =
          ImageProviderVerdicts.record_accepted([accepted.sha256], generation.configuration_id)

        step = followup_step!(generation, [accepted, added])

        pid =
          start_rejection_worker!(step, [{:error, image_rejection()}], request_images: @prepared?)

        assert_receive {:image_request, 1, _task, _step_id, _request, first_wire}, 2_000
        assert [%{"type" => "input_image"}, %{"type" => "input_image"}] = blocks(first_wire)
        assert_receive {:image_request, 2, _task, _retry_step_id, retry_request, wire}, 2_000
        assert_worker_down!(pid)

        assert rejected?(added, generation)
        assert accepted?(accepted, generation)
        [kept, replaced] = blocks(retry_request)
        assert kept["type"] == "input_image"
        assert hd(blocks(wire))["image_url"] =~ "data:image/png;base64,"
        assert replaced["type"] == "input_text"
        assert replaced["text"] =~ "file_id=#{added.external_id}"
        assert load_message!(generation).status == :done
      end

      test "all sent images are blamed when the configuration accepted every one before (prepared state: #{prepared?})" do
        %{files: [file]} = generation = create_generation!(png_1x1())
        :ok = ImageProviderVerdicts.record_accepted([file.sha256], generation.configuration_id)
        step = followup_step!(generation, [file])

        {retry_request, log} =
          with_log(fn ->
            pid =
              start_rejection_worker!(step, [{:error, image_rejection()}],
                request_images: @prepared?
              )

            assert_receive {:image_request, 2, _task, _retry_step_id, retry_request, _wire},
                           2_000

            assert_worker_down!(pid)
            retry_request
          end)

        assert log =~ "image-rejection retry"
        assert log =~ "marked_images=1 fallback=true"
        assert rejected?(file, generation)
        assert_rejected_text(retry_request, file)
        assert load_message!(generation).status == :done
      end
    end

    test "a new generation reusing accepted history images blames only its new image" do
      %{files: [history]} = generation = create_generation!(png_1x1())
      pid = start_rejection_worker!(generation, [])
      assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
      assert_worker_down!(pid)
      assert accepted?(history, generation)

      next = next_generation!(generation, [png(2, 2)])
      %{files: [^history, added]} = next
      pid = start_rejection_worker!(next, [{:error, image_rejection()}])

      assert_receive {:image_request, 1, _task, step_id, _request, wire}, 2_000
      assert step_id == next.step_id
      assert [%{"type" => "input_image"}, %{"type" => "input_image"}] = blocks(wire)
      assert_receive {:image_request, 2, _task, _retry_step_id, retry_request, retry_wire}, 2_000
      assert_worker_down!(pid)

      assert rejected?(added, next)

      assert image_provider_verdicts(history.sha256) == %{
               next.configuration_id => {:accepted, nil}
             }

      assert [%{"type" => "input_image"}, %{"type" => "input_text", "text" => text}] =
               blocks(retry_request)

      assert text =~ "file_id=#{added.external_id}"

      assert [%{"image_url" => "data:image/png;base64," <> _}, %{"type" => "input_text"}] =
               blocks(retry_wire)

      assert load_message!(next).status == :done
    end

    test "an image rejected by one configuration is still sent by a generation with another one" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      pid = start_rejection_worker!(generation, [{:error, image_rejection()}])
      assert_receive {:image_request, 2, _task, _retry_step_id, _request, _wire}, 2_000
      assert_worker_down!(pid)
      assert rejected?(file, generation)

      %{id: other_id} = create_configuration!(generation.actor)
      other = next_generation!(generation, [], configuration_id: other_id)
      pid = start_rejection_worker!(other, [])

      assert_receive {:image_request, 1, _task, _step_id, _request, wire}, 2_000
      assert image_url(wire) =~ "data:image/png;base64,"
      assert_worker_down!(pid)

      facts = image_provider_verdicts(file.sha256)
      assert Enum.sort(Map.keys(facts)) == Enum.sort([generation.configuration_id, other_id])
      assert {:rejected, _details} = facts[generation.configuration_id]
      assert facts[other_id] == {:accepted, nil}

      assert load_message!(other).status == :done
    end

    test "an image hydration replaced with text is not blamed; the images actually sent are" do
      generation = create_generation!(png_1x1(), extra_images: [png(2, 2)])
      %{files: [sent, omitted]} = generation
      step = followup_step!(generation, [sent, omitted])
      assert map_size(step.request_images.images) == 2

      # Another Worker rejected it after this step was prepared.
      :ok =
        ImageProviderVerdicts.mark_rejected(
          [omitted.sha256],
          generation.configuration_id,
          "test: elsewhere"
        )

      pid = start_rejection_worker!(step, [{:error, image_rejection()}])

      assert_receive {:image_request, 1, _task, _step_id, _request, wire}, 2_000
      assert [%{"type" => "input_image"}, %{"type" => "input_text"}] = blocks(wire)
      assert_receive {:image_request, 2, _task, _retry_step_id, retry_request, _wire}, 2_000
      assert_worker_down!(pid)

      assert rejected?(sent, generation)

      assert image_provider_verdicts(omitted.sha256) == %{
               generation.configuration_id => {:rejected, "test: elsewhere"}
             }

      assert [%{"type" => "input_text"}, %{"type" => "input_text"}] = blocks(retry_request)
      assert load_message!(generation).status == :done
    end

    test "a rejection of an attempt that sent no images does not blame images of an earlier attempt" do
      %{message: message, files: [file]} = generation = create_generation!(png_1x1())
      Barrier.gate_persistence(message.id, auto_retry: :start)
      transient = %{image_rejection() | status_code: 503, retryable: true}

      pid =
        start_rejection_worker!(generation, [{:error, transient}, {:error, image_rejection()}])

      assert_receive {:image_request, 1, _task, _step_id, _request, wire}, 2_000
      assert image_url(wire) =~ "data:image/png;base64,"
      writer = Barrier.await_persistence(:auto_retry, :start)

      :ok =
        ImageProviderVerdicts.mark_rejected([file.sha256], generation.configuration_id, "test")

      Barrier.release(writer)

      assert_receive {:image_request, 2, _task, _retry_step_id, retry_request, _wire}, 2_000
      assert_rejected_text(retry_request, file)
      assert_worker_down!(pid)
      refute_received {:image_request, 3, _task, _step_id, _request, _wire}

      assert image_provider_verdicts(file.sha256) == %{
               generation.configuration_id => {:rejected, "test"}
             }

      message = load_message!(generation)
      assert message.status == :error
      assert [:error, :error] == message |> ordered_steps() |> Enum.map(& &1.status)
    end

    test "a second rejection in the same generation fails it without further marks" do
      generation = create_generation!(png_1x1(), extra_images: [png(2, 2)])
      %{files: [accepted, added]} = generation
      :ok = ImageProviderVerdicts.record_accepted([accepted.sha256], generation.configuration_id)
      step = followup_step!(generation, [accepted, added])
      rejection = image_rejection()
      pid = start_rejection_worker!(step, [{:error, rejection}, {:error, rejection}])

      assert_receive {:image_request, 2, _task, _retry_step_id, _request, _wire}, 2_000
      assert_worker_down!(pid)
      refute_received {:image_request, 3, _task, _step_id, _request, _wire}

      assert rejected?(added, generation)
      assert accepted?(accepted, generation)
      message = load_message!(generation)
      assert message.status == :error
      assert message.error_detail =~ rejection.error_text
      assert [:done, :error, :error] == message |> ordered_steps() |> Enum.map(& &1.status)
    end

    test "a Worker restarted on an image-rejection retry step does not retry again" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      retry = persist_retry!(generation, generation, 1, :image_rejected)
      restarted = %{generation | step_id: retry.step_id, raw_request: retry.raw_request}

      pid =
        start_rejection_worker!(restarted, [{:error, image_rejection()}], request_images: false)

      assert_receive {:image_request, 1, _task, step_id, _request, _wire}, 2_000
      assert step_id == retry.step_id
      assert_worker_down!(pid)
      refute_received {:image_request, 2, _task, _step_id, _request, _wire}

      refute rejected?(file, generation)
      assert load_message!(generation).status == :error
    end

    test "a Worker restarted after a transient retry that followed an image-rejection retry does not retry again" do
      generation = create_generation!(png_1x1(), extra_images: [png(2, 2)])
      %{files: [inherited, added]} = generation
      step = followup_step!(generation, [inherited, added])

      :ok =
        ImageProviderVerdicts.mark_rejected([added.sha256], generation.configuration_id, "test")

      image_retry = persist_retry!(generation, step, 1, :image_rejected)
      transient = persist_retry!(generation, image_retry, 2, nil)
      restarted = %{generation | step_id: transient.step_id, raw_request: transient.raw_request}

      pid =
        start_rejection_worker!(restarted, [{:error, image_rejection()}], request_images: false)

      assert_receive {:image_request, 1, _task, step_id, _request, wire}, 2_000
      assert step_id == transient.step_id
      assert [%{"type" => "input_image"}, %{"type" => "input_text"}] = blocks(wire)
      assert_worker_down!(pid)
      refute_received {:image_request, 2, _task, _step_id, _request, _wire}

      refute rejected?(inherited, generation)
      message = load_message!(generation)
      assert message.status == :error

      assert [:done, :error, :error, :error] ==
               message |> ordered_steps() |> Enum.map(& &1.status)
    end

    for retry <- [:retry_last_step, :retry_from_step] do
      @retry retry
      test "a manual retry (#{retry}) after an image-rejection retry marks a newly rejected image and retries once with text in its place" do
        %{files: [earlier, added]} = generation = failed_after_image_rejection_retry!()
        put_provider_script!([{:error, image_rejection()}])

        assert {:ok, %{manual_retry?: true}} = manual_retry(@retry, generation)

        assert_receive {:image_request, 1, _task, step_id, _request, wire}, 2_000
        assert step_sequence(step_id) == 3
        assert [%{"type" => "input_text"}, %{"type" => "input_image"}] = blocks(wire)
        assert_receive {:image_request, 2, _task, retry_step_id, retry_request, retry_wire}, 2_000
        assert step_sequence(retry_step_id) == 4
        assert [earlier_text, added_text] = blocks(retry_request)
        assert_rejected_text_block(earlier_text, earlier)
        assert_rejected_text_block(added_text, added)
        assert blocks(retry_wire) == [earlier_text, added_text]

        message = await_terminal_message!(generation)
        refute_received {:image_request, 3, _task, _step_id, _request, _wire}
        assert message.status == :done
        assert rejected?(added, generation)
        assert [_, _, failed, _] = steps = ordered_steps(message)
        assert [:error, :done, :error, :done] == Enum.map(steps, & &1.status)
        assert {_text, %{"retry_reason" => "image_rejected"}} = retry_error!(failed)
      end
    end

    test "a second rejection within a manual retry fails it without a second image-rejection retry" do
      %{files: [_earlier, added]} = generation = failed_after_image_rejection_retry!()
      rejection = image_rejection()
      put_provider_script!([{:error, rejection}, {:error, rejection}])

      assert {:ok, %{manual_retry?: true}} = manual_retry(:retry_last_step, generation)

      assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
      assert_receive {:image_request, 2, _task, _retry_step_id, _request, _wire}, 2_000
      message = await_terminal_message!(generation)
      refute_received {:image_request, 3, _task, _step_id, _request, _wire}

      assert rejected?(added, generation)
      assert message.status == :error
      assert message.error_detail =~ rejection.error_text

      assert [:error, :done, :error, :error] ==
               message |> ordered_steps() |> Enum.map(& &1.status)
    end

    test "recovery of a generation after an image-rejection retry does not retry a newly rejected image" do
      %{actor: actor, files: [_earlier, added]} = step = after_image_rejection_retry!()
      rejection = image_rejection()
      put_provider_script!([{:error, rejection}])

      assert {:ok, %{manual_retry?: false}} =
               GenerationSupervisor.resume_orphaned_message(step.message.id, actor: actor)

      assert_receive {:image_request, 1, _task, step_id, _request, wire}, 2_000
      assert step_id != step.step_id
      assert step_sequence(step_id) == 3
      assert [%{"type" => "input_text"}, %{"type" => "input_image"}] = blocks(wire)
      message = await_terminal_message!(step)
      refute_received {:image_request, 2, _task, _step_id, _request, _wire}

      refute rejected?(added, step)
      assert message.status == :error
      assert message.error_detail =~ rejection.error_text
      assert [:error, :done, :error] == message |> ordered_steps() |> Enum.map(& &1.status)
    end

    for {name, meta} <- ProviderImageRejections.unrelated() do
      @meta meta
      test "#{name} ends the generation without marking images" do
        %{files: [file]} = generation = create_generation!(png_1x1())
        pid = start_rejection_worker!(generation, [{:error, @meta}])

        assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
        assert_worker_down!(pid)
        refute_received {:image_request, 2, _task, _step_id, _request, _wire}

        assert image_provider_verdicts(file.sha256) == %{}
        message = load_message!(generation)
        assert message.status == :error
        assert [%{status: :error}] = ordered_steps(message)
      end
    end

    test "a rate-limited image error keeps the transient retry and marks nothing" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      rejection = %{image_rejection() | status_code: 429, retryable: true}
      pid = start_rejection_worker!(generation, [{:error, rejection}])

      assert_receive {:image_request, 2, _task, _step_id, retry_request, _wire}, 2_000
      assert first_block(retry_request)["type"] == "input_image"
      assert_worker_down!(pid)

      refute rejected?(file, generation)
      message = load_message!(generation)
      assert message.status == :done
      [failed, _retry] = ordered_steps(message)
      assert {retry_text, metadata} = retry_error!(failed)
      assert retry_text =~ "Transient provider error on attempt 1."
      refute Map.has_key?(metadata, "retry_reason")
    end

    for prepared? <- [true, false] do
      @prepared? prepared?
      test "a request without images fails as before (prepared state: #{prepared?})" do
        generation = create_generation!(nil)
        rejection = image_rejection()

        pid =
          start_rejection_worker!(generation, [{:error, rejection}], request_images: @prepared?)

        assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
        assert_worker_down!(pid)
        refute_received {:image_request, 2, _task, _step_id, _request, _wire}

        message = load_message!(generation)
        assert message.status == :error
        assert message.error_detail =~ rejection.error_text
      end
    end

    test "a generation without an LLM configuration fails without an image retry" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      rejection = image_rejection()

      pid =
        start_rejection_worker!(%{generation | configuration_id: nil}, [{:error, rejection}])

      assert_receive {:image_request, 1, _task, _step_id, _request, wire}, 2_000
      assert image_url(wire) =~ "data:image/png;base64,"
      assert_worker_down!(pid)
      refute_received {:image_request, 2, _task, _step_id, _request, _wire}

      assert image_provider_verdicts(file.sha256) == %{}
      message = load_message!(generation)
      assert message.status == :error
      assert message.error_detail =~ rejection.error_text
    end

    test "a failed mark ends the generation with the provider error" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      inject_sql_failure!("image_provider_verdicts", "BEFORE INSERT", "TRUE", "22023")
      rejection = image_rejection()
      pid = start_rejection_worker!(generation, [{:error, rejection}])

      assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
      assert_worker_down!(pid)
      refute_received {:image_request, 2, _task, _step_id, _request, _wire}

      assert image_provider_verdicts(file.sha256) == %{}
      message = load_message!(generation)
      assert message.status == :error
      assert message.error_detail =~ rejection.error_text
      assert [%{status: :error}] = ordered_steps(message)
    end

    test "cancel during the retry publication cancels the retry step before it is sent" do
      %{message: message, files: [file]} = generation = create_generation!(png_1x1())
      Barrier.gate_persistence(message.id, image_rejection_retry: :stop)
      pid = start_rejection_worker!(generation, [{:error, image_rejection()}])
      monitor_ref = Process.monitor(pid)

      writer = Barrier.await_persistence(:image_rejection_retry, :stop)
      assert rejected?(file, generation)
      cancel_ref = command(pid, :cancel_and_wait)
      assert :sys.get_state(pid).cancel_requested?
      Barrier.release(writer)

      assert_receive {^cancel_ref, :ok}, 2_000
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000
      refute_received {:image_request, 2, _task, _step_id, _request, _wire}

      message = load_message!(generation)
      assert message.status == :canceled
      assert [:error, :canceled] == message |> ordered_steps() |> Enum.map(& &1.status)
    end

    test "an inherited pin above the edge limit is continued as text" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      [binding] = bindings_for_step(generation.step_id)
      {:ok, large} = Files.create_from_binary("large.png", "image/png", oversized_png())
      Ash.destroy!(binding, authorize?: false)
      create_binding!(generation.step_id, large.id, file)

      step = followup_step!(generation, [file])
      assert step.request_images.images == %{}
      text = first_block(step.raw_request)["text"]
      assert text =~ "file_id=#{file.external_id}"
      assert text =~ "3000x1500 px"
      assert text =~ "exceeds the image input limits"

      pid = start_rejection_worker!(step, [], request_images: false)
      assert_receive {:image_request, 1, _task, _step_id, _request, wire}, 2_000
      assert first_block(wire) == %{"type" => "input_text", "text" => text}
      assert_worker_down!(pid)
      assert load_message!(generation).status == :done
    end
  end

  describe "Worker recording images accepted by the configuration" do
    test "a completed attempt records its sent images as accepted after the step is done" do
      generation = create_generation!(png_1x1(), extra_images: [png(2, 2)])
      %{files: [first, second]} = generation
      step = followup_step!(generation, [first, second])
      pid = start_rejection_worker!(step, [])

      assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
      assert_worker_down!(pid)

      for file <- [first, second], do: assert(accepted?(file, generation))
      assert load_message!(generation).status == :done
    end

    @tag :whitebox
    test "sending images the configuration already accepted writes no facts" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      :ok = ImageProviderVerdicts.record_accepted([file.sha256], generation.configuration_id)

      {_result, queries} =
        capture_queries(fn ->
          pid = start_rejection_worker!(generation, [])
          assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
          assert_worker_down!(pid)
        end)

      assert load_message!(generation).status == :done
      assert Enum.filter(queries, &(&1 =~ ~r/INTO "image_provider_verdicts"/)) == []
      assert length(selects_from(queries, "image_provider_verdicts")) == 1
    end

    test "a failed acceptance record is logged and the generation completes" do
      %{files: [file]} = generation = create_generation!(png_1x1())
      inject_sql_failure!("image_provider_verdicts", "BEFORE INSERT", "TRUE", "22023")

      log =
        capture_log(fn ->
          pid = start_rejection_worker!(generation, [])
          assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
          assert_worker_down!(pid)
        end)

      assert log =~ "accepted request images not recorded"
      assert image_provider_verdicts(file.sha256) == %{}
      assert load_message!(generation).status == :done
    end
  end

  describe "Persistence.replace_steps_for_retry!/6" do
    test "atomically replaces a legacy rendition pin without losing its blob" do
      %{actor: actor, message: message, raw_request: raw_request, step_id: old_step_id} =
        create_generation!(png_1x1())

      pin_legacy_thumbnail!(old_step_id, png(20, 10))

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
        create_generation!(png_1x1())

      pin_legacy_thumbnail!(old_step_id, png(20, 10))

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

  # The user message carries `payload` and `:extra_images`; the step 1 request
  # references only `payload` (none when it is `nil`). The generation uses a new
  # LLM configuration (`configuration_id`). With `supervised: true` the chat and
  # the message use it with `Adapters.RegisteredImageRejection`, so the
  # supervisor can retry or recover the generation.
  defp create_generation!(payload, opts \\ []) do
    %{user: actor} = user_fixture()

    {chat, configuration} =
      if Keyword.get(opts, :supervised, false) do
        configuration =
          create_configuration!(actor,
            provider_attrs: %{type: Adapters.RegisteredImageRejection.type()}
          )

        {create_chat!(actor, llm_configuration_id: configuration.id), configuration}
      else
        chat = create_chat!(actor)
        {chat, create_configuration!(actor)}
      end

    payloads = if payload, do: [payload | Keyword.get(opts, :extra_images, [])], else: []
    files = attach_images!(actor, chat, payloads)
    generation = %{actor: actor, configuration_id: configuration.id}
    publish_generation!(generation, chat, Enum.take(files, 1), files)
  end

  # A later generation in the chat of `generation` whose new user message carries
  # `payloads`; its step 1 request references the images of the step 1 request of
  # `generation` followed by the new ones, without a source step.
  defp next_generation!(generation, payloads, opts \\ []) do
    chat =
      Ash.get!(IntellectualClub.Chat.Chat, generation.message.chat_id, actor: generation.actor)

    sent = Enum.take(generation.files, 1)
    files = attach_images!(generation.actor, chat, payloads, length(generation.files) + 1)

    generation
    |> Map.put(
      :configuration_id,
      Keyword.get(opts, :configuration_id, generation.configuration_id)
    )
    |> publish_generation!(chat, sent ++ files, sent ++ files)
  end

  defp attach_images!(actor, chat, payloads, first_index \\ 1) do
    files =
      payloads
      |> Enum.with_index(first_index)
      |> Enum.map(fn {bytes, index} ->
        {:ok, file} = Files.create_from_binary("request-image-#{index}.png", "image/png", bytes)
        file
      end)

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Inspect the attached image",
        actor: actor,
        contents: [
          %{kind: :text, content_text: "Inspect the attached image"}
          | Enum.map(files, &%{kind: :media, file_id: &1.id})
        ]
      )

    files
  end

  defp publish_generation!(generation, chat, sent, files) do
    [user_message | _older] =
      IntellectualClub.Chat.ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id and role == :user)
      |> Ash.Query.sort(id: :desc)
      |> Ash.read!(authorize?: false)

    message =
      create_generating_message!(generation.actor, chat,
        parent_id: user_message.id,
        llm_configuration_id: chat.llm_configuration_id,
        token_count: 0
      )

    %{step: step, request: raw_request, request_images: request_images} =
      Persistence.create_request_step!(message, 1, image_request(sent),
        request_context: request_context(generation, Adapters.Steering)
      )

    Map.merge(generation, %{
      message: message,
      files: files,
      raw_request: raw_request,
      request_images: request_images,
      step_id: step.id
    })
  end

  # As the generation context hands it to request preparation.
  defp request_context(generation, adapter \\ Adapters.ImageRejection),
    do: %{adapter_module: adapter, llm_configuration_id: generation.configuration_id}

  defp image_request([]) do
    %{
      "model" => "test-model",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Inspect nothing"}]
        }
      ]
    }
  end

  defp image_request(files) do
    blocks =
      Enum.map(files, fn file ->
        marker = RequestImages.marker(to_string(file.external_id), "image/png", :data_url)
        %{"type" => "input_image", "image_url" => marker}
      end)

    %{
      "model" => "test-model",
      "input" => [%{"type" => "message", "role" => "user", "content" => blocks}]
    }
  end

  # Completes the step of `generation` and publishes the next one, prepared from
  # it, that sends `files`.
  defp followup_step!(generation, files) do
    :ok = Persistence.mark_step_done!(generation.step_id)

    result =
      with_generation_lease(generation.message.id, fn lease ->
        Persistence.complete_step_and_start_next!(
          generation.message.id,
          generation.step_id,
          step_sequence(generation.step_id) + 1,
          image_request(files),
          lease: lease,
          request_context: request_context(generation)
        )
      end)

    %{
      generation
      | step_id: result.step_id,
        raw_request: result.raw_request,
        request_images: result.request_images
    }
  end

  # Publishes the automatic retry of `step` (`reason` `:image_rejected` or `nil`
  # for a transient error) as the Worker does.
  defp persist_retry!(generation, step, attempt, reason) do
    with_generation_lease(generation.message.id, fn lease ->
      Persistence.persist_retry_error_and_start_next_step!(
        generation.message.id,
        step.step_id,
        step.raw_request,
        if(reason, do: "Could not process image", else: "Temporary provider error"),
        attempt: attempt,
        retry_delay_ms: 0,
        status_code: if(reason, do: 400, else: 503),
        retryable: true,
        retry_reason: reason,
        request_context: request_context(generation),
        lease: lease
      )
    end)
  end

  # The step's prepared image state is handed over unless `request_images: false`,
  # as for a Worker restarted by recovery.
  defp start_rejection_worker!(generation, outcomes, opts \\ []) do
    context =
      generation
      |> worker_context(Adapters.ImageRejection,
        request_images: Keyword.get(opts, :request_images, true)
      )
      |> Map.merge(%{
        test_outcomes: outcomes,
        initial_step_sequence: step_sequence(generation.step_id)
      })

    start_worker_with_lease!(generation.message.id, context)
  end

  # A supervised generation whose step 1 image (`earlier`) was rejected and
  # retried as text (step 2), and whose step 3, waiting for the provider, sends
  # a new image (`added`) after it, as a later tool result would.
  defp after_image_rejection_retry! do
    generation = create_generation!(png_1x1(), extra_images: [png(2, 2)], supervised: true)
    %{files: [earlier, added]} = generation

    :ok =
      ImageProviderVerdicts.mark_rejected([earlier.sha256], generation.configuration_id, "test")

    retry = persist_retry!(generation, generation, 1, :image_rejected)

    generation
    |> Map.merge(%{step_id: retry.step_id, raw_request: retry.raw_request})
    |> followup_step!([earlier, added])
  end

  # `after_image_rejection_retry!/0` whose step 3 failed: the provider rejected
  # the new image too, after the image-rejection retry of the generation, so
  # nothing was marked and every retry as before would fail the same way.
  defp failed_after_image_rejection_retry! do
    %{files: [_earlier, added]} = step = after_image_rejection_retry!()
    pid = start_rejection_worker!(step, [{:error, image_rejection()}])

    assert_receive {:image_request, 1, _task, _step_id, _request, _wire}, 2_000
    assert_worker_down!(pid)
    refute_received {:image_request, 2, _task, _step_id, _request, _wire}

    refute rejected?(added, step)
    assert load_message!(step).status == :error
    step
  end

  # The provider outcomes of Workers the supervisor starts for this test.
  defp put_provider_script!(outcomes) do
    attempts = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))

    Adapters.RegisteredImageRejection.put_script(%{
      test_outcomes: outcomes,
      attempts: attempts,
      test_pid: self()
    })
  end

  # A manual retry by the user of the failed step of `generation`.
  defp manual_retry(:retry_last_step, generation),
    do: GenerationSupervisor.retry_last_step(generation.message.id, actor: generation.actor)

  defp manual_retry(:retry_from_step, generation) do
    GenerationSupervisor.retry_from_step(generation.message.id, generation.step_id,
      actor: generation.actor
    )
  end

  # The message once the Worker the supervisor started for it has finished.
  defp await_terminal_message!(generation) do
    wait_for_message_status!(generation.message.id, generation.actor, [:done, :error],
      load: @steps_load,
      stop_worker: true
    )
  end

  defp step_sequence(step_id), do: Ash.get!(ChatMessageStep, step_id, authorize?: false).sequence

  defp image_rejection do
    {_name, meta} =
      Enum.find(ProviderImageRejections.rejections(), fn {name, _meta} ->
        name =~ "Anthropic processing failure"
      end)

    meta
  end

  defp assert_worker_down!(pid) do
    monitor_ref = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 2_000
  end

  defp assert_rejected_text(request, file) do
    assert_rejected_text_block(first_block(request), file)
  end

  defp assert_rejected_text_block(block, file) do
    assert %{"type" => "input_text", "text" => text} = block
    assert text =~ "file_id=#{file.external_id}"
    assert text =~ "was rejected by the model provider"
    text
  end

  defp rejected?(file, generation), do: provider_status(file, generation) == :rejected
  defp accepted?(file, generation), do: provider_status(file, generation) == :accepted

  defp provider_status(file, generation) do
    {:ok, facts} = ImageProviderVerdicts.load([file.sha256], generation.configuration_id)
    Map.get(facts, file.sha256)
  end

  defp load_message!(generation),
    do: Ash.get!(ChatMessage, generation.message.id, actor: generation.actor, load: @steps_load)

  defp ordered_steps(message), do: Enum.sort_by(message.steps, & &1.sequence)

  # The retry error item of `step`: `{text, metadata}`.
  defp retry_error!(step) do
    assert [item] = Enum.filter(step.items, &(&1.type == :error))
    assert [metadata] = for(%{kind: :opaque} = content <- item.contents, do: content.content_json)
    {item_text(item), metadata}
  end

  defp create_binding!(step_id, file_id, source_file) do
    ref = to_string(source_file.external_id)

    ChatMessageStepRequestFile
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_step_id: step_id,
        file_id: file_id,
        reference_key: ref,
        source_file_external_id: ref,
        variant_key: "identity:v1"
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # `request_images: true` hands the worker the request images prepared at publication.
  defp worker_context(generation, adapter, opts) do
    %{
      owner_id: generation.actor.id,
      chat_id: generation.message.chat_id,
      message_id: generation.message.id,
      step_id: generation.step_id,
      provider_type: "test",
      llm_configuration_id: generation.configuration_id,
      adapter_module: adapter,
      request_payload: generation.raw_request,
      request_images: if(opts[:request_images], do: generation.request_images),
      timeout_ms: 5_000,
      chunk_delay_ms: 0,
      attempts: start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref())),
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

  defp image_url(request), do: first_block(request)["image_url"]
  defp first_block(request), do: hd(blocks(request))
  defp blocks(request), do: get_in(request, ["input", Access.at(0), "content"])
end
