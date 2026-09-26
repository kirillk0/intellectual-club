defmodule IntellectualClub.Generation.RequestImagesTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep,
    ChatMessageStepRequestFile
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.{FilesystemStorage, GarbageCollector}
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.RequestImages.StagedBindings
  alias IntellectualClub.Tools.ExecutionContext

  require Ash.Query

  @invalid_fallback "[Image omitted: attached file could not be validated as an image.]"
  @resize_fallback "[Image omitted: attached image exceeded the native image size limit and could not be resized.]"

  test "prepares one stable pin for all four shapes before INSERT and never updates raw" do
    fixture = request_fixture!(image_payload())
    raw = four_shape_request(fixture.file)
    file_count = count_files()

    {{prepared, step}, queries} =
      capture_queries(fn ->
        assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
        assert prepared.request == raw
        assert [item] = prepared.bindings.items
        assert item.variant_key == "identity:v1"
        assert item.reference_key == to_string(fixture.file.external_id)
        assert count_files() == file_count + 1
        assert [] == bindings_for_step(fixture.source_step.id)
        assert [] == steps_for_message(fixture.target_message.id)

        step = publish!(fixture, prepared)
        assert :ok = RequestImages.validate_snapshot(prepared.request, step.id)
        assert {:ok, ^raw} = RequestImages.materialize_and_persist(raw, step.id)
        assert {:ok, ^raw} = RequestImages.materialize_and_persist(step.id, raw)
        assert saved_step(step.id).raw_request == raw
        assert saved_step(step.id).updated_at == step.updated_at
        assert :ok = RequestImages.discard_staged_bindings(prepared.bindings)
        assert count_files() == file_count + 1
        {prepared, step}
      end)

    refute Enum.any?(queries, &Regex.match?(~r/UPDATE\s+"chat_message_steps"/i, &1))
    assert Enum.count(queries, &Regex.match?(~r/INSERT INTO "chat_message_steps"/i, &1)) == 1
    assert [binding] = bindings_for_step(step.id)
    assert binding.file_id == hd(prepared.bindings.items).file_id
    assert {:ok, wire} = RequestImages.hydrate(prepared.request, step.id)
    assert_wire_payload(wire, fixture.payload, "image/png")

    unbound = create_step!(fixture.target_message.id, 2, fixture.actor, prepared.request)

    assert {:error, {:request_image_binding_not_found, _ref}} =
             RequestImages.hydrate(prepared.request, unbound.id)
  end

  test "prepares without an assistant message or step and uses the source parent scope" do
    fixture = request_fixture!(image_payload(), target_message?: false)

    assert {:ok, prepared} =
             RequestImages.prepare(responses_request(fixture.file), scope(fixture))

    assert [item] = prepared.bindings.items
    assert item.reference_key == to_string(fixture.file.external_id)

    message =
      create_message!(fixture.chat.id, :assistant, fixture.actor, fixture.source_message.id)

    step = publish!(%{fixture | target_message: message}, prepared)
    assert :ok = RequestImages.validate_snapshot(prepared.request, step.id)
  end

  test "prepares one bounded thumbnail for all shapes and keeps the canonical payload" do
    fixture = request_fixture!(oversized_png_payload())

    assert {:ok, prepared} =
             RequestImages.prepare(four_shape_request(fixture.file), scope(fixture))

    assert [item] = prepared.bindings.items
    assert item.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
    assert item.reference_key == to_string(fixture.file.external_id)
    assert {:ok, {_file, resized}} = Files.load_payload(item.file_id)
    assert {"image/png", width, height, _variant} = ExImageInfo.info(resized)
    assert max(width, height) <= 2_000
    assert {:ok, {_file, original}} = Files.load_payload(fixture.file.id)
    assert original == fixture.payload
    assert {"image/png", 3_000, 1_500, _variant} = ExImageInfo.info(original)
    step = publish!(fixture, prepared)
    assert saved_step(step.id).raw_request == prepared.request
    assert {:ok, wire} = RequestImages.hydrate(prepared.request, step.id)
    assert_wire_payload(wire, resized, "image/png")
  end

  test "corrects all MIME fields before INSERT without changing canonical metadata or refs" do
    fixture = request_fixture!(jpeg_payload(), mime_type: "image/png", filename: "declared.png")
    raw = four_shape_request(fixture.file)
    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    refute prepared.request == raw
    [responses, openrouter, anthropic, google] = image_blocks(prepared.request)

    for marker <- [
          responses["image_url"],
          openrouter["image_url"]["url"],
          anthropic["source"]["data"],
          google["data"]
        ] do
      assert marker["$intellectual_club_file"]["mime_type"] == "image/jpeg"

      assert marker["$intellectual_club_file"]["reference_key"] ==
               to_string(fixture.file.external_id)
    end

    assert anthropic["source"]["media_type"] == "image/jpeg"
    assert google["mime_type"] == "image/jpeg"
    assert Ash.get!(StoredFile, fixture.file.id, authorize?: false).mime_type == "image/png"
    assert [item] = prepared.bindings.items
    assert Ash.get!(StoredFile, item.file_id, authorize?: false).mime_type == "image/jpeg"
    step = publish!(fixture, prepared)
    assert :ok = RequestImages.validate_snapshot(prepared.request, step.id)
    assert {:ok, wire} = RequestImages.hydrate(prepared.request, step.id)
    assert_wire_payload(wire, fixture.payload, "image/jpeg")
  end

  test "uses resize fallback in all shapes before publication" do
    fixture =
      request_fixture!(oversized_bmp_header_payload(),
        mime_type: "image/bmp",
        filename: "source.bmp"
      )

    assert {:ok, prepared} =
             RequestImages.prepare(four_shape_request(fixture.file), scope(fixture))

    assert prepared.bindings.items == []
    assert_fallback(prepared.request, @resize_fallback)
    step = publish!(fixture, prepared)
    assert saved_step(step.id).raw_request == prepared.request
  end

  test "invalid new images become provider-native text and preserve Anthropic cache control" do
    fixture = request_fixture!("<html>not an image</html>")
    raw = four_shape_request(fixture.file, anthropic_cache_control?: true)
    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    assert prepared.bindings.items == []
    assert_fallback(prepared.request, @invalid_fallback, anthropic_cache_control?: true)
    refute Jason.encode!(prepared.request) =~ "$intellectual_club_file"
    assert count_files() == 1
  end

  test "independent preparations own independent files with the same stable reference" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)

    prepared =
      1..2
      |> Task.async_stream(fn _ -> RequestImages.prepare(raw, scope(fixture)) end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, prepared}} -> prepared end)

    assert [first, second] = prepared
    assert first.request == second.request
    assert hd(first.bindings.items).reference_key == hd(second.bindings.items).reference_key
    refute hd(first.bindings.items).file_id == hd(second.bindings.items).file_id
    assert count_files() == 3
    assert :ok = RequestImages.discard_staged_bindings(first.bindings)
    step = publish!(fixture, second)
    assert :ok = RequestImages.validate_snapshot(second.request, step.id)
    assert count_files() == 2
  end

  test "compatibility validation never writes raw, backfills missing pins or removes stale pins" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    step = create_step!(fixture.target_message.id, 1, fixture.actor, raw)
    ref = to_string(fixture.file.external_id)
    count = count_files()

    {_, queries} =
      capture_queries(fn ->
        assert {:error, {:request_image_binding_not_found, ^ref}} =
                 RequestImages.materialize_and_persist(raw, step.id)

        assert {:error, :request_snapshot_mismatch} =
                 RequestImages.materialize_and_persist(%{"input" => []}, step.id)

        assert saved_step(step.id).raw_request == raw
        assert saved_step(step.id).updated_at == step.updated_at
        assert count_files() == count
        assert bindings_for_step(step.id) == []

        assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
        empty_step = create_step!(fixture.target_message.id, 2, fixture.actor, %{"input" => []})
        assert :ok = RequestImages.attach_staged_bindings(prepared.bindings, empty_step.id)

        assert {:error, {:unreferenced_request_image_binding, ^ref}} =
                 RequestImages.validate_snapshot(%{"input" => []}, empty_step.id)

        assert [_binding] = bindings_for_step(empty_step.id)
        assert count_files() == count + 1
      end)

    refute Enum.any?(queries, &Regex.match?(~r/UPDATE\s+"chat_message_steps"/i, &1))
  end

  test "ignores markers in parameters, tool arguments and opaque result maps without DB work" do
    marker = RequestImages.marker(Ash.UUID.generate(), "image/png")

    raw = %{
      "custom_parameter" => %{"type" => "input_image", "image_url" => marker},
      "tools" => [%{"arguments" => %{"type" => "image", "data" => marker}}],
      "input" => [
        %{"type" => "function_call", "arguments" => %{"type" => "image", "data" => marker}},
        %{"type" => "function_result", "result" => %{"type" => "image", "data" => marker}},
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "opaque",
              "content" => [%{"type" => "input_image", "image_url" => marker}]
            }
          ]
        }
      ]
    }

    {_, queries} =
      capture_queries(fn ->
        assert {:ok, %{request: ^raw, bindings: %StagedBindings{items: []}}} =
                 RequestImages.prepare(raw, %ExecutionContext{}, source_step_id: -1)

        assert {:ok, ^raw} = RequestImages.hydrate(raw, nil)
        assert {:ok, ^raw} = RequestImages.hydrate(raw, -1)
      end)

    assert queries == []
  end

  test "walks image blocks in structured function results" do
    fixture = request_fixture!(image_payload())

    raw = %{
      "input" => [
        %{"type" => "function_result", "result" => image_blocks(four_shape_request(fixture.file))}
      ]
    }

    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    assert [_item] = prepared.bindings.items
    step = publish!(fixture, prepared)
    assert {:ok, wire} = RequestImages.hydrate(prepared.request, step.id)
    assert_wire_blocks(hd(wire["input"])["result"], fixture.payload, "image/png")
  end

  test "legacy inline encodings in all shapes and text-only requests are a DB-free pass-through" do
    data = Base.encode64(image_payload())

    legacy = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "input_image", "image_url" => "data:image/png;base64," <> data},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> data}},
            %{
              "type" => "image",
              "source" => %{"type" => "base64", "media_type" => "image/png", "data" => data}
            },
            %{"type" => "image", "mime_type" => "image/png", "data" => data}
          ]
        }
      ]
    }

    {_, queries} =
      capture_queries(fn ->
        for raw <- [legacy, %{"input" => []}, %{"input" => "hello"}] do
          assert {:ok, %{request: ^raw, bindings: %StagedBindings{items: []}}} =
                   RequestImages.prepare(raw, %ExecutionContext{step_id: -1}, source_step_id: -1)

          assert {:ok, ^raw} = RequestImages.hydrate(raw, nil)
        end
      end)

    assert queries == []

    ref = Ash.UUID.generate()

    assert {:error, {:request_image_binding_not_found, ^ref}} =
             RequestImages.hydrate(
               responses_request(%{external_id: ref, mime_type: "image/png"}),
               nil
             )
  end

  test "ordinary history reuse and pin copying survive canonical deletion without changing raw" do
    fixture = request_fixture!(image_payload())

    assert {:ok, prepared} =
             RequestImages.prepare(four_shape_request(fixture.file), scope(fixture))

    source = publish!(fixture, prepared)
    [source_binding] = bindings_for_step(source.id)
    Ash.destroy!(fixture.content, actor: fixture.actor)
    assert {:error, _} = Ash.get(StoredFile, fixture.file.id, authorize?: false)

    copy = create_step!(fixture.target_message.id, 2, fixture.actor, prepared.request)
    assert :ok = RequestImages.validate_snapshot(prepared.request, source.id)
    assert :ok = RequestImages.clone_bindings(source.id, copy.id)
    [copy_binding] = bindings_for_step(copy.id)
    refute copy_binding.file_id == source_binding.file_id
    assert copy_binding.file.sha256 == source_binding.file.sha256
    assert saved_step(source.id).raw_request == prepared.request
    assert saved_step(copy.id).raw_request == prepared.request
    assert saved_step(source.id).updated_at == source.updated_at
    assert saved_step(copy.id).updated_at == copy.updated_at

    assert {:ok, reused} = RequestImages.prepare(prepared.request, scope(fixture))
    reuse = publish!(fixture, reused, 3)
    assert reused.request == prepared.request
    [reuse_binding] = bindings_for_step(reuse.id)
    assert reuse_binding.file_id not in [source_binding.file_id, copy_binding.file_id]
    assert {:ok, wire} = RequestImages.hydrate(reused.request, reuse.id)
    assert_wire_payload(wire, fixture.payload, "image/png")
    Ash.destroy!(source, actor: fixture.actor)
    Ash.destroy!(copy, actor: fixture.actor)
    assert FilesystemStorage.exists?(source_binding.file.sha256)
    Ash.destroy!(reuse, actor: fixture.actor)
    assert {:ok, :deleted} = GarbageCollector.collect_sha256(source_binding.file.sha256)
    refute FilesystemStorage.exists?(source_binding.file.sha256)
  end

  test "copy conflicts never accept different pin bytes or change either saved request" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    source = publish!(fixture, prepared)
    ref = to_string(fixture.file.external_id)
    other_raw = responses_request(%{external_id: ref, mime_type: "image/jpeg"})
    target = create_step!(fixture.target_message.id, 2, fixture.actor, other_raw)
    assert {:ok, other_file} = Files.create_from_binary("other.jpg", "image/jpeg", jpeg_payload())
    target_binding = create_binding!(target.id, other_file.id, ref, ref, "identity:v1")
    count = count_files()

    assert {:error, {:conflicting_staged_binding, ^ref, _source_ref, "identity:v1"}} =
             RequestImages.clone_bindings(source.id, target.id)

    assert count_files() == count
    assert [binding] = bindings_for_step(target.id)
    assert binding.id == target_binding.id
    assert binding.file_id == other_file.id
    assert saved_step(source.id).raw_request == raw
    assert saved_step(target.id).raw_request == other_raw
    assert saved_step(source.id).updated_at == source.updated_at
    assert saved_step(target.id).updated_at == target.updated_at
    assert :ok = RequestImages.validate_snapshot(raw, source.id)
    assert :ok = RequestImages.validate_snapshot(other_raw, target.id)
  end

  test "exact inherited refs use source-local pins after canonical deletion" do
    fixture = request_fixture!(jpeg_payload(), mime_type: "image/png")

    assert {:ok, prepared} =
             RequestImages.prepare(four_shape_request(fixture.file), scope(fixture))

    source = publish!(fixture, prepared)
    [source_binding] = bindings_for_step(source.id)
    Ash.destroy!(fixture.content, actor: fixture.actor)

    assert {:ok, inherited} =
             RequestImages.prepare(prepared.request, scope(fixture), source_step_id: source.id)

    assert inherited.request == prepared.request
    assert [item] = inherited.bindings.items
    refute item.file_id == source_binding.file_id
    assert item.reference_key == to_string(source_binding.reference_key)
    step = publish!(fixture, inherited, 2)
    assert :ok = RequestImages.validate_snapshot(inherited.request, step.id)
    assert saved_step(source.id).updated_at == source.updated_at
    assert {:ok, wire} = RequestImages.hydrate(inherited.request, step.id)
    assert_wire_payload(wire, fixture.payload, "image/jpeg")
  end

  test "missing exact source pin fails despite a canonical file and another usable pin" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    _other = publish!(fixture, prepared)
    source = create_step!(fixture.target_message.id, 2, fixture.actor, raw)
    count = count_files()
    ref = to_string(fixture.file.external_id)

    assert {:error, {:request_image_binding_not_found, ^ref}} =
             RequestImages.prepare(raw, scope(fixture), source_step_id: source.id)

    assert count_files() == count
    assert saved_step(source.id).raw_request == raw
    assert bindings_for_step(source.id) == []
  end

  test "inherited binding source, MIME, variant, size and payload failures cannot fall back" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    ref = to_string(fixture.file.external_id)

    invalid_pins = [
      {image_payload(), "identity:v1", Ash.UUID.generate(),
       {:request_image_binding_source_mismatch, ref}},
      {jpeg_payload(), "identity:v1", ref, {:request_image_binding_mime_mismatch, ref}},
      {image_payload(), "unknown:v1", ref,
       {:unsupported_request_image_binding_variant, "unknown:v1"}},
      {oversized_png_payload(), "identity:v1", ref, {:request_image_binding_oversized, ref}},
      {"invalid bytes", "identity:v1", ref, :invalid_image_payload}
    ]

    invalid_pins
    |> Enum.with_index(1)
    |> Enum.each(fn {{payload, variant, source_ref, expected_error}, sequence} ->
      source = create_step!(fixture.target_message.id, sequence, fixture.actor, raw)
      assert {:ok, file} = Files.create_from_binary("pin.png", "image/png", payload)
      create_binding!(source.id, file.id, ref, source_ref, variant)
      count = count_files()

      assert {:error, ^expected_error} =
               RequestImages.prepare(raw, scope(fixture), source_step_id: source.id)

      assert count_files() == count
      assert saved_step(source.id).raw_request == raw
      assert [_binding] = bindings_for_step(source.id)
    end)
  end

  test "a missing inherited rendition payload fails even when canonical bytes are available" do
    fixture = request_fixture!(oversized_png_payload())

    assert {:ok, prepared} =
             RequestImages.prepare(responses_request(fixture.file), scope(fixture))

    source = publish!(fixture, prepared)
    [binding] = bindings_for_step(source.id)
    assert {:ok, {_file, bytes}} = Files.load_payload(binding.file_id)
    {:ok, path} = FilesystemStorage.path_for(binding.file.sha256)
    File.rm!(path)

    try do
      assert {:error, :payload_not_found} =
               RequestImages.prepare(prepared.request, scope(fixture), source_step_id: source.id)

      assert {:error, :payload_not_found} =
               RequestImages.validate_snapshot(prepared.request, source.id)

      assert {:ok, {_file, original}} = Files.load_payload(fixture.file.id)
      assert original == fixture.payload

      File.write!(path, image_payload())

      assert {:error, :request_image_payload_integrity_mismatch} =
               RequestImages.prepare(prepared.request, scope(fixture), source_step_id: source.id)

      assert {:error, :request_image_payload_integrity_mismatch} =
               RequestImages.validate_snapshot(prepared.request, source.id)
    after
      File.rm(path)
      assert {:ok, :created} = FilesystemStorage.store(binding.file.sha256, bytes)
    end
  end

  test "repeated inherited descriptors and hydration cannot change source identity or MIME" do
    fixture = request_fixture!(image_payload())

    assert {:ok, prepared} =
             RequestImages.prepare(four_shape_request(fixture.file), scope(fixture))

    source = publish!(fixture, prepared)
    [responses, openrouter, anthropic, google] = image_blocks(prepared.request)
    ref = to_string(fixture.file.external_id)

    changed_mime =
      put_in(google, ["data", "$intellectual_club_file", "mime_type"], "image/jpeg")
      |> Map.put("mime_type", "image/jpeg")

    raw = put_blocks(prepared.request, [responses, openrouter, anthropic, changed_mime])

    assert {:error, {:request_image_binding_mime_mismatch, ^ref}} =
             RequestImages.prepare(raw, scope(fixture), source_step_id: source.id)

    assert {:error, {:request_image_binding_mime_mismatch, ^ref}} =
             RequestImages.hydrate(raw, source.id)

    wrong_outer_mime = Map.put(google, "mime_type", "image/jpeg")
    raw = put_blocks(prepared.request, [responses, openrouter, anthropic, wrong_outer_mime])

    assert {:error, {:request_image_block_mime_mismatch, ^ref}} =
             RequestImages.prepare(raw, scope(fixture), source_step_id: source.id)

    changed_source =
      put_in(
        responses,
        ["image_url", "$intellectual_club_file", "source_file_external_id"],
        Ash.UUID.generate()
      )

    raw = put_blocks(prepared.request, [changed_source])

    assert {:error, {:request_image_binding_source_mismatch, ^ref}} =
             RequestImages.prepare(raw, scope(fixture), source_step_id: source.id)

    assert saved_step(source.id).raw_request == prepared.request
  end

  test "preparation cleans already staged new files when an inherited pin fails later" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    source = create_step!(fixture.target_message.id, 1, fixture.actor, raw)

    {file, _content} =
      attach_content!(fixture.source_step, fixture.actor, jpeg_payload(), 2, "image/jpeg")

    request = put_blocks(raw, image_blocks(responses_request(file)) ++ image_blocks(raw))
    count = count_files()
    ref = to_string(fixture.file.external_id)

    assert {:error, {:request_image_binding_not_found, ^ref}} =
             RequestImages.prepare(request, scope(fixture), source_step_id: source.id)

    assert count_files() == count
    assert bindings_for_step(source.id) == []
    assert {:ok, {_file, bytes}} = Files.load_payload(file.id)
    assert bytes == jpeg_payload()
  end

  test "prepare plus attach rolls back atomically and discards only unowned staged files" do
    fixture = request_fixture!(image_payload())
    assert {:ok, first} = RequestImages.prepare(responses_request(fixture.file), scope(fixture))
    source = publish!(fixture, first)

    assert {:ok, staged} =
             RequestImages.prepare(first.request, scope(fixture), source_step_id: source.id)

    [item] = staged.bindings.items
    count = count_files()

    assert {:error, :publication_failed} =
             Repo.transaction(fn ->
               replacement =
                 create_step!(fixture.target_message.id, 2, fixture.actor, staged.request)

               assert :ok =
                        RequestImages.attach_staged_bindings_transactional(
                          staged.bindings,
                          replacement.id
                        )

               Repo.rollback(:publication_failed)
             end)

    assert Enum.map(steps_for_message(fixture.target_message.id), & &1.id) == [source.id]
    assert count_files() == count
    assert :ok = RequestImages.discard_staged_bindings(staged.bindings)
    assert :ok = RequestImages.discard_staged_bindings(staged.bindings)
    assert {:error, _} = Ash.get(StoredFile, item.file_id, authorize?: false)
    assert :ok = RequestImages.validate_snapshot(first.request, source.id)
    assert saved_step(source.id).updated_at == source.updated_at
    assert count_files() == count - 1
  end

  test "filesystem GC discovers a resized payload after a successful nested create is rolled back" do
    fixture = request_fixture!(oversized_png_payload())
    raw = responses_request(fixture.file)
    source_before = saved_step(fixture.source_step.id)
    file_count = count_files()
    parent = self()

    assert {:error, :late_outer_failure} =
             Repo.transaction(fn ->
               %{step: step} =
                 IntellectualClub.Generation.Persistence.create_request_step!(
                   fixture.target_message,
                   1,
                   raw
                 )

               [binding] = bindings_for_step(step.id)
               assert binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
               send(parent, {:staged_outer_file, binding.file_id, binding.file.sha256, step.id})
               Repo.rollback(:late_outer_failure)
             end)

    assert_receive {:staged_outer_file, file_id, sha256, step_id}
    assert steps_for_message(fixture.target_message.id) == []
    assert bindings_for_step(step_id) == []
    assert {:error, _} = Ash.get(StoredFile, file_id, authorize?: false)
    assert count_files() == file_count
    assert FilesystemStorage.exists?(sha256)
    assert {:ok, %{deleted: deleted}} = GarbageCollector.collect()
    assert deleted > 0
    refute FilesystemStorage.exists?(sha256)
    assert FilesystemStorage.exists?(fixture.file.sha256)
    source_after = saved_step(fixture.source_step.id)
    assert source_after.updated_at == source_before.updated_at
    assert source_after.raw_request == source_before.raw_request
  end

  test "exact image pins are inherited from reconstructed patch steps" do
    fixture = request_fixture!(image_payload())

    request =
      Map.put(responses_request(fixture.file), "opaque_padding", String.duplicate("x", 4096))

    first =
      IntellectualClub.Generation.Persistence.create_request_step!(
        fixture.target_message,
        1,
        request
      )

    second =
      IntellectualClub.Generation.Persistence.create_request_step!(
        fixture.target_message,
        2,
        Map.put(first.request, "round", 2),
        previous_request: first.request,
        previous_step: first.step,
        source_step_id: first.step.id
      )

    assert second.step.request_mode == :patch
    assert :ok = RequestImages.validate_snapshot(second.request, second.step.id)

    # The exact previous pin, not canonical lookup, must serve the third request.
    fixture.content
    |> Ash.Changeset.for_update(:update, %{file_id: nil}, actor: fixture.actor)
    |> Ash.update!(actor: fixture.actor)

    assert :ok = Files.delete_file_and_maybe_payload(fixture.file.id)

    third =
      IntellectualClub.Generation.Persistence.create_request_step!(
        fixture.target_message,
        3,
        Map.put(second.request, "round", 3),
        previous_request: second.request,
        previous_step: second.step,
        source_step_id: second.step.id
      )

    assert third.step.request_mode == :patch
    assert :ok = RequestImages.validate_snapshot(third.request, third.step.id)
    assert {:ok, wire} = RequestImages.hydrate(third.request, third.step.id)
    assert inspect(wire) =~ "data:image/png;base64,"
  end

  test "transactional attachment errors can roll back partial bindings without losing staged ownership" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    assert {:ok, first} = RequestImages.prepare(raw, scope(fixture))
    assert {:ok, second} = RequestImages.prepare(raw, scope(fixture))
    staged = %StagedBindings{items: first.bindings.items ++ second.bindings.items}

    assert {:error, _reason} =
             Repo.transaction(fn ->
               step = create_step!(fixture.target_message.id, 1, fixture.actor, raw)

               assert {:error, {:attach_staged_binding_failed, _ref, _reason}} =
                        RequestImages.attach_staged_bindings_transactional(staged, step.id)

               Repo.rollback(:attach_failed)
             end)

    assert steps_for_message(fixture.target_message.id) == []
    assert :ok = RequestImages.discard_staged_bindings(staged)
    assert count_files() == 1
  end

  test "staging source-local copies inside a failed replacement transaction preserves the source" do
    fixture = request_fixture!(image_payload())

    assert {:ok, prepared} =
             RequestImages.prepare(responses_request(fixture.file), scope(fixture))

    source = publish!(fixture, prepared)
    [binding] = bindings_for_step(source.id)

    assert {:error, :forced_retry_failure} =
             Repo.transaction(fn ->
               assert {:ok, staged} = RequestImages.stage_bindings(source.id)
               Ash.destroy!(source, actor: fixture.actor)

               replacement =
                 create_step!(fixture.target_message.id, 1, fixture.actor, prepared.request)

               assert :ok =
                        RequestImages.attach_staged_bindings_transactional(staged, replacement.id)

               Repo.rollback(:forced_retry_failure)
             end)

    assert [restored] = bindings_for_step(source.id)
    assert restored.id == binding.id
    assert :ok = RequestImages.validate_snapshot(prepared.request, source.id)
    assert {:ok, {_file, payload}} = Files.load_payload(restored.file_id)
    assert payload == fixture.payload
  end

  test "discarded prepared rendition cleanup commits logically and remains retryable by GC" do
    fixture = request_fixture!(oversized_png_payload())

    assert {:ok, prepared} =
             RequestImages.prepare(responses_request(fixture.file), scope(fixture))

    [item] = prepared.bindings.items
    assert {:ok, {file, payload}} = Files.load_payload(item.file_id)
    replace_payload_with_directory!(file.sha256)

    try do
      assert :ok = RequestImages.discard_staged_bindings(prepared.bindings)
      assert {:error, _} = Ash.get(StoredFile, file.id, authorize?: false)
      assert {:error, _} = GarbageCollector.collect_sha256(file.sha256)
    after
      restore_payload!(file.sha256, payload)
    end

    assert {:ok, :deleted} = GarbageCollector.collect_sha256(file.sha256)
    assert {:ok, {_file, original}} = Files.load_payload(fixture.file.id)
    assert original == fixture.payload
  end

  test "preparation never stages a corrupt existing rendition blob and cleans its new logical row" do
    fixture = request_fixture!(oversized_png_payload())
    raw = responses_request(fixture.file)
    assert {:ok, first} = RequestImages.prepare(raw, scope(fixture))
    [item] = first.bindings.items
    assert {:ok, {file, payload}} = Files.load_payload(item.file_id)
    {:ok, path} = FilesystemStorage.path_for(file.sha256)
    File.write!(path, "corrupt rendition")
    count = count_files()

    try do
      assert {:error,
              {:created_request_image_invalid,
               {:error, :request_image_payload_integrity_mismatch}}} =
               RequestImages.prepare(raw, scope(fixture))

      assert count_files() == count
      assert steps_for_message(fixture.target_message.id) == []
      assert File.read!(path) == "corrupt rendition"
    after
      File.rm(path)
      assert {:ok, :created} = FilesystemStorage.store(file.sha256, payload)
      assert :ok = RequestImages.discard_staged_bindings(first.bindings)
    end
  end

  test "canonical and reusable pins remain owner and chat scoped" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    source = publish!(fixture, prepared)
    other_chat = create_chat!(fixture.actor)
    other_scope = %ExecutionContext{owner_id: fixture.actor.id, chat_id: other_chat.id}
    assert {:ok, denied} = RequestImages.prepare(raw, other_scope)
    assert denied.bindings.items == []
    assert [%{"type" => "input_text", "text" => @invalid_fallback}] = image_blocks(denied.request)

    assert {:error, :request_image_source_out_of_scope} =
             RequestImages.prepare(raw, other_scope, source_step_id: source.id)

    %{user: other_actor} = user_fixture()

    assert {:error, :request_image_source_out_of_scope} =
             RequestImages.prepare(
               raw,
               %ExecutionContext{owner_id: other_actor.id, chat_id: fixture.chat.id},
               source_step_id: source.id
             )

    assert {:ok, denied} =
             RequestImages.prepare(raw, %ExecutionContext{
               owner_id: other_actor.id,
               chat_id: fixture.chat.id
             })

    assert denied.bindings.items == []
  end

  test "explicit available files resolve with no chat while nil scope grants no implicit access" do
    assert {:ok, file} = Files.create_from_binary("available.png", "image/png", image_payload())
    raw = responses_request(file)
    assert {:ok, denied} = RequestImages.prepare(raw, %ExecutionContext{})
    assert denied.bindings.items == []

    assert {:ok, prepared} =
             RequestImages.prepare(raw, %ExecutionContext{
               available_file_external_ids: [to_string(file.external_id)]
             })

    assert prepared.request == raw
    assert [_item] = prepared.bindings.items
    assert :ok = RequestImages.discard_staged_bindings(prepared.bindings)
  end

  test "handoff descendants may reuse ancestor pins" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    source = publish!(fixture, prepared)
    Ash.destroy!(fixture.content, actor: fixture.actor)

    child =
      create_chat!(fixture.actor, %{
        parent_chat_id: fixture.chat.id,
        parent_message_id: fixture.target_message.id,
        parent_relation_kind: :handoff
      })

    child_scope = %ExecutionContext{owner_id: fixture.actor.id, chat_id: child.id}

    for opts <- [[], [source_step_id: source.id]] do
      assert {:ok, inherited} = RequestImages.prepare(raw, child_scope, opts)
      assert inherited.request == raw
      assert [_item] = inherited.bindings.items
      assert :ok = RequestImages.discard_staged_bindings(inherited.bindings)
    end
  end

  test "linked forks permit exact prefix pins but never future parent refs or snapshots" do
    fixture = request_fixture!(image_payload())
    raw = responses_request(fixture.file)
    assert {:ok, prepared} = RequestImages.prepare(raw, scope(fixture))
    anchor = publish!(fixture, prepared)
    call = create_tool_call!(anchor, fixture.actor)

    future_message =
      create_message!(fixture.chat.id, :user, fixture.actor, fixture.target_message.id)

    future_content_step = create_step!(future_message.id, 1, fixture.actor)

    {future_file, _content} =
      attach_content!(future_content_step, fixture.actor, jpeg_payload(), 1, "image/jpeg")

    future_raw = responses_request(future_file)
    assert {:ok, future} = RequestImages.prepare(future_raw, scope(fixture))
    future_step = publish!(fixture, future, 2)
    fork = linked_fork!(fixture, anchor, call)
    fork_scope = %ExecutionContext{owner_id: fixture.actor.id, chat_id: fork.id}

    assert {:ok, denied} = RequestImages.prepare(future_raw, fork_scope)
    assert denied.bindings.items == []
    assert [%{"type" => "input_text", "text" => @invalid_fallback}] = image_blocks(denied.request)

    assert {:error, :request_image_source_out_of_scope} =
             RequestImages.prepare(future_raw, fork_scope, source_step_id: future_step.id)

    Ash.destroy!(fixture.content, actor: fixture.actor)
    assert {:ok, inherited} = RequestImages.prepare(raw, fork_scope, source_step_id: anchor.id)
    assert inherited.request == raw
    assert [_item] = inherited.bindings.items
    assert :ok = RequestImages.discard_staged_bindings(inherited.bindings)
  end

  defp request_fixture!(payload, opts \\ []) do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    source_message = create_message!(chat.id, :user, actor)
    source_step = create_step!(source_message.id, 1, actor)

    {file, content} =
      attach_content!(
        source_step,
        actor,
        payload,
        1,
        Keyword.get(opts, :mime_type, "image/png"),
        Keyword.get(opts, :filename, "source.png")
      )

    target_message =
      if Keyword.get(opts, :target_message?, true),
        do: create_message!(chat.id, :assistant, actor, source_message.id)

    %{
      actor: actor,
      chat: chat,
      source_message: source_message,
      source_step: source_step,
      target_message: target_message,
      content: content,
      file: file,
      payload: payload
    }
  end

  defp scope(fixture) do
    %ExecutionContext{
      owner_id: fixture.actor.id,
      chat_id: fixture.chat.id,
      message_id: fixture.source_message.id,
      assistant_message_id: nil
    }
  end

  defp create_chat!(actor, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(:create, Map.put_new(attrs, :note, ""), actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_message!(chat_id, role, actor, parent_id \\ nil) do
    ChatMessage
    |> Ash.Changeset.for_create(
      :add_message,
      %{chat_id: chat_id, role: role, parent_id: parent_id, status: :done, token_count: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_step!(message_id, sequence, actor, raw \\ %{}) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: message_id,
        sequence: sequence,
        status: :done,
        raw_request: raw,
        response_final: true
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp publish!(fixture, prepared, sequence \\ 1) do
    assert {:ok, step} =
             Repo.transaction(fn ->
               step =
                 create_step!(
                   fixture.target_message.id,
                   sequence,
                   fixture.actor,
                   prepared.request
                 )

               assert :ok =
                        RequestImages.attach_staged_bindings_transactional(
                          prepared.bindings,
                          step.id
                        )

               step
             end)

    step
  end

  defp attach_content!(step, actor, payload, sequence, mime_type, filename \\ "source.png") do
    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: sequence, type: :input},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, file} = Files.create_from_binary(filename, mime_type, payload)

    content =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_item_id: item.id, sequence: 1, kind: :media, file_id: file.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {file, content}
  end

  defp create_binding!(step_id, file_id, ref, source_ref, variant) do
    ChatMessageStepRequestFile
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_step_id: step_id,
        file_id: file_id,
        reference_key: ref,
        source_file_external_id: source_ref,
        variant_key: variant
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_tool_call!(step, actor) do
    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :opaque,
        content_json: %{
          "call_id" => "fork_images",
          "name" => "fork_chat",
          "arguments" => %{"task" => "inspect images"}
        }
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    item
  end

  defp linked_fork!(fixture, anchor, call) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: "",
        parent_chat_id: fixture.chat.id,
        parent_message_id: fixture.target_message.id,
        parent_tool_call_item_id: call.id,
        parent_relation_kind: :fork
      },
      actor: fixture.actor
    )
    |> Ash.Changeset.force_change_attribute(:fork_source_step_id, anchor.id)
    |> Ash.Changeset.force_change_attribute(:fork_task, "inspect images")
    |> Ash.create!(actor: fixture.actor)
  end

  defp four_shape_request(file, opts \\ []) do
    data_url = RequestImages.marker(to_string(file.external_id), file.mime_type, :data_url)
    base64 = RequestImages.marker(to_string(file.external_id), file.mime_type, :base64)

    anthropic = %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => file.mime_type, "data" => base64}
    }

    anthropic =
      if Keyword.get(opts, :anthropic_cache_control?, false),
        do: Map.put(anthropic, "cache_control", %{"type" => "ephemeral"}),
        else: anthropic

    %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "input_image", "image_url" => data_url},
            %{"type" => "image_url", "image_url" => %{"url" => data_url}},
            anthropic,
            %{"type" => "image", "mime_type" => file.mime_type, "data" => base64}
          ]
        }
      ]
    }
  end

  defp responses_request(file) do
    marker = RequestImages.marker(to_string(file.external_id), file.mime_type)

    %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_image", "image_url" => marker}]
        }
      ]
    }
  end

  defp image_blocks(request), do: hd(request["messages"] || request["input"])["content"]

  defp put_blocks(request, blocks) do
    key = if Map.has_key?(request, "messages"), do: "messages", else: "input"
    Map.update!(request, key, fn [container] -> [Map.put(container, "content", blocks)] end)
  end

  defp assert_wire_payload(wire, payload, mime_type),
    do: assert_wire_blocks(image_blocks(wire), payload, mime_type)

  defp assert_wire_blocks([responses, openrouter, anthropic, google], payload, mime_type) do
    assert responses["image_url"] == "data:#{mime_type};base64," <> Base.encode64(payload)
    assert openrouter["image_url"]["url"] == responses["image_url"]
    assert Base.decode64!(anthropic["source"]["data"]) == payload
    assert anthropic["source"]["media_type"] == mime_type
    assert Base.decode64!(google["data"]) == payload
    assert google["mime_type"] == mime_type
  end

  defp assert_fallback(request, text, opts \\ []) do
    [responses, openrouter, anthropic, google] = image_blocks(request)
    assert responses == %{"type" => "input_text", "text" => text}
    assert openrouter == %{"type" => "text", "text" => text}

    expected_anthropic =
      if Keyword.get(opts, :anthropic_cache_control?, false),
        do: %{"type" => "text", "text" => text, "cache_control" => %{"type" => "ephemeral"}},
        else: %{"type" => "text", "text" => text}

    assert anthropic == expected_anthropic
    assert google == %{"type" => "text", "text" => text}
  end

  defp bindings_for_step(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false, load: [:file])
  end

  defp steps_for_message(message_id) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^message_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp saved_step(id), do: Ash.get!(ChatMessageStep, id, authorize?: false, load: [:raw_request])
  defp count_files, do: StoredFile |> Ash.read!(authorize?: false) |> length()

  defp capture_queries(fun) do
    tag = make_ref()
    handler = {__MODULE__, tag}

    :ok =
      :telemetry.attach(
        handler,
        [:intellectual_club, :repo, :query],
        &__MODULE__.record_query/4,
        {self(), tag}
      )

    try do
      result = fun.()
      {result, collect_queries(tag, [])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def record_query(_event, _measurements, metadata, {pid, tag}),
    do: send(pid, {tag, metadata.query})

  defp collect_queries(tag, queries) do
    receive do
      {^tag, query} -> collect_queries(tag, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp oversized_png_payload do
    IntellectualClub.ImageFixtures.png(3_000, 1_500)
  end

  defp jpeg_payload do
    IntellectualClub.ImageFixtures.jpeg_2x1()
  end

  defp oversized_bmp_header_payload do
    width = 3_000
    height = 1_500
    row_size = div(width * 3 + 3, 4) * 4
    image_size = row_size * height
    file_size = 54 + image_size

    <<"BM", file_size::little-32, 0::little-16, 0::little-16, 54::little-32, 40::little-32,
      width::little-signed-32, height::little-signed-32, 1::little-16, 24::little-16,
      0::little-32, image_size::little-32, 2_835::little-signed-32, 2_835::little-signed-32,
      0::little-32, 0::little-32>>
  end

  defp replace_payload_with_directory!(sha256) do
    {:ok, payload_path} = FilesystemStorage.path_for(sha256)
    File.rm!(payload_path)
    File.mkdir!(payload_path)
    File.write!(Path.join(payload_path, "sentinel"), "not removable as a blob")
  end

  defp restore_payload!(sha256, payload) do
    {:ok, payload_path} = FilesystemStorage.path_for(sha256)
    File.rm_rf!(payload_path)
    assert {:ok, :created} = FilesystemStorage.store(sha256, payload)
  end
end
