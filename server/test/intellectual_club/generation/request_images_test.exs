defmodule IntellectualClub.Generation.RequestImagesTest do
  @moduledoc """
  `IntellectualClub.Generation.RequestImages`: pinning request images to
  step-local files, provider-shape normalization and text replacements, content
  verdicts and request limits, inherited and legacy pins, staged file ownership,
  access scope and the hydrated wire cache.

  Most scenarios send one request with the same image in all four provider
  shapes (Responses, OpenRouter, Anthropic, Google) and assert every shape.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Generation.RequestImageCacheTestHelpers
  import IntellectualClub.SqlCapture, only: [capture_queries: 1, selects_from: 2]

  require Ash.Query

  alias IntellectualClub.Chat.{ChatMessageStep, ChatMessageStepRequestFile}
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.{FilesystemStorage, GarbageCollector, ImageProviderVerdicts}
  alias IntellectualClub.Files.ImageVerdict
  alias IntellectualClub.Generation.{Persistence, RequestImages, RequestImagesTestAdapter}
  alias IntellectualClub.Generation.RequestImages.StagedBindings
  alias IntellectualClub.ImageProcessor
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Tools.ExecutionContext

  @unavailable_fallback "[Image omitted: attached file could not be validated as an image.]"
  @thumbnail_variant "thumbnail:max-edge=2000:preserve-format:v1"
  @legacy_exact_variant "legacy_exact:v1"

  describe "prepare/3 and publication" do
    test "pins atom-valued image blocks normalized at the provider boundary" do
      fixture = request_fixture!(png_1x1())
      marker = RequestImages.marker(to_string(fixture.file.external_id), "image/png")
      raw = %{input: [%{role: :user, content: [%{type: :input_image, image_url: marker}]}]}

      %{step: step, request: request} =
        Persistence.create_request_step!(fixture.target_message, 1, raw,
          request_context: %{adapter_module: IntellectualClub.Llm.Providers.Responses}
        )

      assert [_binding] = bindings_for_step(step.id)
      assert hd(hd(request["input"])["content"])["type"] == "input_image"
      assert {:ok, wire} = hydrate(request, step.id)
      assert hd(hd(wire["input"])["content"])["image_url"] =~ "data:image/png;base64,"
    end

    test "prepares one stable pin for all four shapes before INSERT and never updates raw" do
      fixture = request_fixture!(png_1x1())
      raw = four_shape_request(fixture.file)
      file_count = count_files()

      {{prepared, step}, queries} =
        capture_queries(fn ->
          assert {:ok, prepared} = prepare(raw, scope(fixture))
          assert prepared.request == raw
          assert [item] = prepared.bindings.items
          assert item.variant_key == "identity:v1"
          assert item.reference_key == to_string(fixture.file.external_id)
          assert count_files() == file_count + 1
          assert [] == bindings_for_step(fixture.source_step.id)
          assert [] == steps_for_message(fixture.target_message.id)

          step = publish!(fixture, prepared)
          assert :ok = validate_snapshot(prepared.request, step.id)
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
      assert {:ok, wire} = hydrate(prepared.request, step.id)
      assert_wire_payload(wire, fixture.payload, "image/png")

      unbound =
        create_request_step!(fixture.actor, fixture.target_message.id, 2, prepared.request)

      assert {:error, {:request_image_binding_not_found, _ref}} =
               hydrate(prepared.request, unbound.id)
    end

    test "prepares without an assistant message or step and uses the source parent scope" do
      fixture = request_fixture!(png_1x1(), target_message?: false)

      assert {:ok, prepared} =
               prepare(responses_request(fixture.file), scope(fixture))

      assert [item] = prepared.bindings.items
      assert item.reference_key == to_string(fixture.file.external_id)

      message =
        create_message!(fixture.actor, fixture.chat.id,
          role: :assistant,
          parent_id: fixture.source_message.id,
          token_count: 0
        )

      step = publish!(%{fixture | target_message: message}, prepared)
      assert :ok = validate_snapshot(prepared.request, step.id)
    end

    test "image state records the content and provenance of every pin" do
      fixture = request_fixture!(png_1x1())
      ref = to_string(fixture.file.external_id)
      assert {:ok, first} = prepare(responses_request(fixture.file), scope(fixture))
      assert first.image_state.images == %{ref => %{sha256: fixture.file.sha256, origin: :new}}
      source = publish!(fixture, first)

      {other, _content} =
        attach_content!(fixture.source_step, fixture.actor, jpeg_payload(), 2, "image/jpeg")

      blocks = image_blocks(first.request) ++ image_blocks(responses_request(other))

      assert {:ok, next} =
               prepare(put_blocks(first.request, blocks), scope(fixture),
                 source_step_id: source.id
               )

      assert next.image_state.images == %{
               ref => %{sha256: fixture.file.sha256, origin: :inherited},
               to_string(other.external_id) => %{sha256: other.sha256, origin: :new}
             }

      assert {:ok, reused} = prepare(first.request, scope(fixture))

      assert reused.image_state.images == %{
               ref => %{sha256: fixture.file.sha256, origin: :reused}
             }

      for prepared <- [next, reused],
          do: assert(:ok = RequestImages.discard_staged_bindings(prepared.bindings))
    end

    test "independent preparations own independent files with the same stable reference" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)

      prepared =
        1..2
        |> Task.async_stream(fn _ -> prepare(raw, scope(fixture)) end,
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
      assert :ok = validate_snapshot(second.request, step.id)
      assert count_files() == 2
    end
  end

  describe "new image normalization" do
    test "images over the edge limit become text naming the file and are never resized" do
      fixture = request_fixture!(oversized_png(), filename: "wide.png")
      file_count = count_files()

      assert {:ok, prepared} =
               prepare(four_shape_request(fixture.file), scope(fixture))

      assert prepared.bindings.items == []
      assert prepared.image_state.images == %{}
      assert count_files() == file_count
      text = assert_omitted(prepared.request, fixture.file, "exceeds the image input limits")
      assert text =~ ~s("wide.png")
      assert text =~ "3000x1500 px"
      # Limits are checked on the headers first, so no verdict is computed.
      assert verdict(fixture.file) == nil
      assert {:ok, {_file, original}} = Files.load_payload(fixture.file.id)
      assert original == fixture.payload
      step = publish!(fixture, prepared)
      assert {:ok, wire} = hydrate(prepared.request, step.id)
      assert wire == prepared.request
    end

    test "images over the byte limit become text even within the edge limit" do
      fixture = request_fixture!(padded_png(8, 8, ImageProcessor.max_payload_bytes()))
      assert {:ok, prepared} = prepare(four_shape_request(fixture.file), scope(fixture))
      assert prepared.bindings.items == []

      text =
        assert_omitted(
          prepared.request,
          fixture.file,
          "exceeds the image input limits of 2000 px per side and 7.5 MB"
        )

      assert text =~ "8x8 px, 7.5 MB"
    end

    test "corrects all MIME fields before INSERT without changing canonical metadata or refs" do
      fixture = request_fixture!(jpeg_payload(), mime_type: "image/png", filename: "declared.png")
      raw = four_shape_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
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
      assert :ok = validate_snapshot(prepared.request, step.id)
      assert {:ok, wire} = hydrate(prepared.request, step.id)
      assert_wire_payload(wire, fixture.payload, "image/jpeg")
    end

    test "formats providers do not accept become text naming the file" do
      fixture =
        request_fixture!(oversized_bmp_header_payload(),
          mime_type: "image/bmp",
          filename: "source.bmp"
        )

      assert {:ok, prepared} =
               prepare(four_shape_request(fixture.file), scope(fixture))

      assert prepared.bindings.items == []
      assert_omitted(prepared.request, fixture.file, "could not be validated as an image")
      assert %{status: :invalid, reason: "unsupported_format:bmp"} = verdict(fixture.file)
      step = publish!(fixture, prepared)
      assert saved_step(step.id).raw_request == prepared.request
    end

    test "truncated images with matching hashes become text before publication" do
      fixture = request_fixture!(truncated_png())
      raw = four_shape_request(fixture.file, anthropic_cache_control?: true)
      assert {:ok, %{width: 20, height: 10}} = ImageProcessor.header(fixture.payload)

      assert {:ok, prepared} = prepare(raw, scope(fixture))
      assert prepared.bindings.items == []

      text =
        assert_omitted(prepared.request, fixture.file, "could not be validated as an image",
          anthropic_cache_control?: true
        )

      assert %{status: :invalid, reason: "png:" <> _} = verdict(fixture.file)
      assert count_files() == 1
      step = publish!(fixture, prepared)
      assert {:ok, wire} = hydrate(prepared.request, step.id)
      refute Jason.encode!(wire) =~ "$intellectual_club_file"
      assert_fallback(wire, text, anthropic_cache_control?: true)
    end

    test "invalid new images become provider-native text and preserve Anthropic cache control" do
      fixture = request_fixture!("<html>not an image</html>")
      raw = four_shape_request(fixture.file, anthropic_cache_control?: true)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      assert prepared.bindings.items == []

      text =
        assert_omitted(prepared.request, fixture.file, "could not be validated as an image",
          anthropic_cache_control?: true
        )

      assert text =~ ~s("source.png")
      refute Jason.encode!(prepared.request) =~ "$intellectual_club_file"
      assert count_files() == 1
    end
  end

  describe "content verdicts" do
    test "a verdict is computed once per content and reused by later preparations and hydration" do
      fixture = request_fixture!(png_1x1())
      assert verdict(fixture.file) == nil
      assert {:ok, prepared} = prepare(four_shape_request(fixture.file), scope(fixture))
      stored = verdict(fixture.file)

      assert %{
               status: :valid,
               mime_type: "image/png",
               width: 1,
               height: 1,
               check_version: version
             } =
               stored

      assert version == ImageProcessor.check_version()
      step = publish!(fixture, prepared)

      {copy, _content} =
        attach_content!(fixture.source_step, fixture.actor, png_1x1(), 2, "image/png", "copy.png")

      assert {:ok, again} = prepare(responses_request(copy), scope(fixture))
      assert [_item] = again.bindings.items
      assert {:ok, _wire} = hydrate(prepared.request, step.id)
      assert {:ok, _staged} = prepare(prepared.request, scope(fixture), source_step_id: step.id)
      assert verdict(fixture.file) == stored
      assert ImageVerdict |> Ash.read!(authorize?: false) |> length() == 1
    end

    test "a remembered current verdict is trusted instead of decoding the payload again" do
      fixture = request_fixture!(png_1x1())

      image_verdict!(fixture.file.sha256,
        status: :invalid,
        mime_type: nil,
        width: nil,
        height: nil,
        reason: "remembered"
      )

      assert {:ok, prepared} = prepare(four_shape_request(fixture.file), scope(fixture))
      assert prepared.bindings.items == []
      assert_omitted(prepared.request, fixture.file, "could not be validated as an image")
    end

    test "a stale verdict is recomputed before the image is sent" do
      fixture = request_fixture!(png_1x1())
      image_verdict!(fixture.file.sha256, check_version: 0, status: :invalid, reason: "old")
      assert {:ok, prepared} = prepare(responses_request(fixture.file), scope(fixture))
      assert [_item] = prepared.bindings.items
      assert %{status: :valid, check_version: version} = verdict(fixture.file)
      assert version == ImageProcessor.check_version()
      assert :ok = RequestImages.discard_staged_bindings(prepared.bindings)
    end

    @tag :whitebox
    test "verdicts of all inherited pins and hydrated bindings load with one query" do
      fixture = request_fixture!(png_1x1())

      files =
        for {payload, sequence} <- Enum.with_index([png(2, 1), png(3, 1), jpeg_payload()], 2) do
          mime_type = if sequence == 4, do: "image/jpeg", else: "image/png"

          {file, _content} =
            attach_content!(fixture.source_step, fixture.actor, payload, sequence, mime_type)

          file
        end

      blocks = Enum.flat_map([fixture.file | files], &image_blocks(responses_request(&1)))
      raw = put_blocks(responses_request(fixture.file), blocks)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      source = publish!(fixture, prepared)
      verdict_query? = &Regex.match?(~r/FROM "image_verdicts"/, &1)

      {_, queries} =
        capture_queries(fn ->
          assert {:ok, inherited} = prepare(raw, scope(fixture), source_step_id: source.id)
          assert length(inherited.bindings.items) == 4
          assert :ok = RequestImages.discard_staged_bindings(inherited.bindings)
        end)

      assert Enum.count(queries, verdict_query?) == 1

      {_, queries} = capture_queries(fn -> assert {:ok, _wire} = hydrate(raw, source.id) end)
      assert Enum.count(queries, verdict_query?) == 1
    end
  end

  describe "request walking" do
    for {name, kind} <- [
          {"image-shaped markers in parameters, tool arguments and results",
           :non_content_markers},
          {"legacy inline encodings in all four shapes", :legacy_inline},
          {"a request without input items", :empty_input},
          {"a text-only request", :text_input},
          {"image blocks without an explicit provider mapper", :no_mapper}
        ] do
      test "#{name} pass through without database work" do
        {raw, scope, opts} = pass_through_case(unquote(kind))

        {_, queries} =
          capture_queries(fn ->
            assert {:ok, %{request: ^raw, bindings: %StagedBindings{items: []}}} =
                     RequestImages.prepare(raw, scope, opts)

            for step_id <- [nil, -1] do
              assert {:ok, ^raw} =
                       RequestImages.hydrate(raw, step_id, Keyword.take(opts, [:mapper]))
            end
          end)

        assert queries == []
      end
    end

    test "hydration without a step cannot resolve a file marker" do
      ref = Ash.UUID.generate()

      assert {:error, {:request_image_binding_not_found, ^ref}} =
               hydrate(responses_request(%{external_id: ref, mime_type: "image/png"}), nil)
    end

    test "walks image blocks in structured function results" do
      fixture = request_fixture!(png_1x1())

      raw = %{
        "input" => [
          %{
            "type" => "function_result",
            "result" => image_blocks(four_shape_request(fixture.file))
          }
        ]
      }

      assert {:ok, prepared} = prepare(raw, scope(fixture))
      assert [_item] = prepared.bindings.items
      step = publish!(fixture, prepared)
      assert {:ok, wire} = hydrate(prepared.request, step.id)
      assert_wire_blocks(hd(wire["input"])["result"], fixture.payload, "image/png")
    end
  end

  describe "validate_snapshot/3" do
    test "never writes raw, backfills missing pins or removes stale pins" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)

      step =
        create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)

      ref = to_string(fixture.file.external_id)
      count = count_files()

      {_, queries} =
        capture_queries(fn ->
          assert {:error, {:request_image_binding_not_found, ^ref}} =
                   validate_snapshot(raw, step.id)

          assert {:error, :request_snapshot_mismatch} =
                   validate_snapshot(%{"input" => []}, step.id)

          assert saved_step(step.id).raw_request == raw
          assert saved_step(step.id).updated_at == step.updated_at
          assert count_files() == count
          assert bindings_for_step(step.id) == []

          assert {:ok, prepared} = prepare(raw, scope(fixture))

          empty_step =
            create_request_step!(fixture.actor, fixture.target_message.id, 2, %{"input" => []})

          assert :ok = RequestImages.attach_staged_bindings(prepared.bindings, empty_step.id)

          assert {:error, {:unreferenced_request_image_binding, ^ref}} =
                   validate_snapshot(%{"input" => []}, empty_step.id)

          assert [_binding] = bindings_for_step(empty_step.id)
          assert count_files() == count + 1
        end)

      refute Enum.any?(queries, &Regex.match?(~r/UPDATE\s+"chat_message_steps"/i, &1))
    end
  end

  describe "pin inheritance and copies" do
    test "ordinary history reuse and pin copying survive canonical deletion without changing raw" do
      fixture = request_fixture!(png_1x1())

      assert {:ok, prepared} =
               prepare(four_shape_request(fixture.file), scope(fixture))

      source = publish!(fixture, prepared)
      [source_binding] = bindings_for_step(source.id)
      Ash.destroy!(fixture.content, actor: fixture.actor)
      assert {:error, _} = Ash.get(StoredFile, fixture.file.id, authorize?: false)

      copy =
        create_request_step!(fixture.actor, fixture.target_message.id, 2, prepared.request)

      assert :ok = validate_snapshot(prepared.request, source.id)
      assert :ok = RequestImages.clone_bindings(source.id, copy.id)
      [copy_binding] = bindings_for_step(copy.id)
      refute copy_binding.file_id == source_binding.file_id
      assert copy_binding.file.sha256 == source_binding.file.sha256
      assert saved_step(source.id).raw_request == prepared.request
      assert saved_step(copy.id).raw_request == prepared.request
      assert saved_step(source.id).updated_at == source.updated_at
      assert saved_step(copy.id).updated_at == copy.updated_at

      assert {:ok, reused} = prepare(prepared.request, scope(fixture))
      reuse = publish!(fixture, reused, 3)
      assert reused.request == prepared.request
      [reuse_binding] = bindings_for_step(reuse.id)
      assert reuse_binding.file_id not in [source_binding.file_id, copy_binding.file_id]
      assert {:ok, wire} = hydrate(reused.request, reuse.id)
      assert_wire_payload(wire, fixture.payload, "image/png")
      Ash.destroy!(source, actor: fixture.actor)
      Ash.destroy!(copy, actor: fixture.actor)
      assert FilesystemStorage.exists?(source_binding.file.sha256)
      Ash.destroy!(reuse, actor: fixture.actor)
      assert {:ok, :deleted} = GarbageCollector.collect_sha256(source_binding.file.sha256)
      refute FilesystemStorage.exists?(source_binding.file.sha256)
    end

    test "copy conflicts never accept different pin bytes or change either saved request" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      source = publish!(fixture, prepared)
      ref = to_string(fixture.file.external_id)
      other_raw = responses_request(%{external_id: ref, mime_type: "image/jpeg"})

      target =
        create_request_step!(fixture.actor, fixture.target_message.id, 2, other_raw)

      assert {:ok, other_file} =
               Files.create_from_binary("other.jpg", "image/jpeg", jpeg_payload())

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
      assert :ok = validate_snapshot(raw, source.id)
      assert :ok = validate_snapshot(other_raw, target.id)
    end

    test "exact inherited refs use source-local pins after canonical deletion" do
      fixture = request_fixture!(jpeg_payload(), mime_type: "image/png")

      assert {:ok, prepared} =
               prepare(four_shape_request(fixture.file), scope(fixture))

      source = publish!(fixture, prepared)
      [source_binding] = bindings_for_step(source.id)
      Ash.destroy!(fixture.content, actor: fixture.actor)

      assert {:ok, inherited} =
               prepare(prepared.request, scope(fixture), source_step_id: source.id)

      assert inherited.request == prepared.request
      assert [item] = inherited.bindings.items
      refute item.file_id == source_binding.file_id
      assert item.reference_key == to_string(source_binding.reference_key)
      step = publish!(fixture, inherited, 2)
      assert :ok = validate_snapshot(inherited.request, step.id)
      assert saved_step(source.id).updated_at == source.updated_at
      assert {:ok, wire} = hydrate(inherited.request, step.id)
      assert_wire_payload(wire, fixture.payload, "image/jpeg")
    end

    test "missing exact source pin fails despite a canonical file and another usable pin" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      _other = publish!(fixture, prepared)

      source =
        create_request_step!(fixture.actor, fixture.target_message.id, 2, raw)

      count = count_files()
      ref = to_string(fixture.file.external_id)

      assert {:error, {:request_image_binding_not_found, ^ref}} =
               prepare(raw, scope(fixture), source_step_id: source.id)

      assert count_files() == count
      assert saved_step(source.id).raw_request == raw
      assert bindings_for_step(source.id) == []
    end

    test "inherited binding source, MIME and variant failures cannot fall back" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      ref = to_string(fixture.file.external_id)

      invalid_pins = [
        {png_1x1(), "identity:v1", Ash.UUID.generate(),
         {:request_image_binding_source_mismatch, ref}},
        {jpeg_payload(), "identity:v1", ref, {:request_image_binding_mime_mismatch, ref}},
        {png_1x1(), "unknown:v1", ref, {:unsupported_request_image_binding_variant, "unknown:v1"}}
      ]

      invalid_pins
      |> Enum.with_index(1)
      |> Enum.each(fn {{payload, variant, source_ref, expected_error}, sequence} ->
        source =
          create_request_step!(fixture.actor, fixture.target_message.id, sequence, raw)

        assert {:ok, file} = Files.create_from_binary("pin.png", "image/png", payload)
        create_binding!(source.id, file.id, ref, source_ref, variant)
        count = count_files()

        assert {:error, ^expected_error} =
                 prepare(raw, scope(fixture), source_step_id: source.id)

        assert count_files() == count
        assert saved_step(source.id).raw_request == raw
        assert [_binding] = bindings_for_step(source.id)
      end)
    end

    test "inherited pins above the edge limit become text in validation, hydration and inheritance" do
      fixture = request_fixture!(png_1x1())
      raw = four_shape_request(fixture.file)
      ref = to_string(fixture.file.external_id)
      source = create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)
      assert {:ok, file} = Files.create_from_binary("wide.png", "image/png", oversized_png())
      create_binding!(source.id, file.id, ref, ref, "identity:v1")

      assert :ok = validate_snapshot(raw, source.id)
      assert {:ok, wire} = hydrate(raw, source.id)
      text = assert_omitted(wire, fixture.file, "exceeds the image input limits")
      assert text =~ ~s("wide.png")
      assert text =~ "3000x1500 px"
      assert {:ok, inherited} = prepare(raw, scope(fixture), source_step_id: source.id)
      assert inherited.bindings.items == []
      assert inherited.image_state.images == %{}
      assert_fallback(inherited.request, text)
      assert saved_step(source.id).raw_request == raw
      assert [_binding] = bindings_for_step(source.id)
    end

    test "reusable pins over the request limits fall back to the canonical image" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      ref = to_string(fixture.file.external_id)
      source = create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)
      assert {:ok, file} = Files.create_from_binary("large.png", "image/png", oversized_png())
      create_binding!(source.id, file.id, ref, ref, "identity:v1")

      assert {:ok, prepared} = prepare(raw, scope(fixture))
      assert [item] = prepared.bindings.items
      assert {:ok, {_file, bytes}} = Files.load_payload(item.file_id)
      assert bytes == fixture.payload
      assert :ok = RequestImages.discard_staged_bindings(prepared.bindings)
    end

    test "saved invalid pins become text in validation, hydration and inheritance without canonical fallback" do
      fixture = request_fixture!(png_1x1())
      raw = four_shape_request(fixture.file)
      ref = to_string(fixture.file.external_id)
      source = create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)
      assert {:ok, file} = Files.create_from_binary("truncated.png", "image/png", truncated_png())
      create_binding!(source.id, file.id, ref, ref, "identity:v1")

      assert :ok = validate_snapshot(raw, source.id)
      assert {:ok, wire} = hydrate(raw, source.id)
      text = assert_omitted(wire, fixture.file, "could not be validated as an image")
      assert text =~ ~s("truncated.png")
      assert {:ok, inherited} = prepare(raw, scope(fixture), source_step_id: source.id)
      assert inherited.bindings.items == []
      assert_fallback(inherited.request, text)
      assert saved_step(source.id).raw_request == raw
      assert [_binding] = bindings_for_step(source.id)
    end

    test "images rejected by the current configuration become text when inherited, hydrated, reused or new" do
      fixture = request_fixture!(png_1x1())
      %{id: config} = create_configuration!(fixture.actor)
      raw = four_shape_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture), llm_configuration_id: config)
      source = publish!(fixture, prepared)
      :ok = ImageProviderVerdicts.mark_rejected([fixture.file.sha256], config, "test: rejected")

      # A warm wire cache from an earlier send must not bypass the rejection either.
      for cache <- [%{}, prepared.image_state.cache] do
        assert {:ok, wire} =
                 hydrate(prepared.request, source.id, cache: cache, llm_configuration_id: config)

        text = assert_omitted(wire, fixture.file, "was rejected by the model provider")
        assert text =~ "1x1 px"
        file_count = count_files()

        assert {:ok, retry} =
                 prepare(prepared.request, scope(fixture),
                   source_step_id: source.id,
                   cache: cache,
                   llm_configuration_id: config
                 )

        assert count_files() == file_count
        assert retry.bindings.items == []
        assert retry.image_state.images == %{}
        assert retry.image_state.descriptors == %{}
        assert retry.image_state.cache == %{}
        assert_fallback(retry.request, text)
        retry_step = publish!(fixture, retry, 2 + map_size(cache))

        assert {:ok, retry_wire} =
                 hydrate(retry.request, retry_step.id, llm_configuration_id: config)

        assert_fallback(retry_wire, text)
      end

      assert :ok = validate_snapshot(prepared.request, source.id)
      assert {:ok, reused} = prepare(raw, scope(fixture), llm_configuration_id: config)
      assert reused.bindings.items == []
      assert_omitted(reused.request, fixture.file, "was rejected by the model provider")

      other_chat = request_fixture!(png_1x1())
      other_raw = four_shape_request(other_chat.file)
      assert {:ok, new} = prepare(other_raw, scope(other_chat), llm_configuration_id: config)
      assert new.bindings.items == []
      assert_omitted(new.request, other_chat.file, "was rejected by the model provider")
    end

    test "an image rejected by one configuration is still sent to another one" do
      fixture = request_fixture!(png_1x1())
      %{id: rejecting} = create_configuration!(fixture.actor)
      %{id: other} = create_configuration!(fixture.actor)
      raw = four_shape_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture), llm_configuration_id: other)
      source = publish!(fixture, prepared)

      :ok =
        ImageProviderVerdicts.mark_rejected([fixture.file.sha256], rejecting, "test: rejected")

      for configuration_id <- [other, nil] do
        assert {:ok, wire} =
                 hydrate(prepared.request, source.id,
                   cache: prepared.image_state.cache,
                   llm_configuration_id: configuration_id
                 )

        assert_wire_payload(wire, fixture.payload, "image/png")

        assert {:ok, inherited} =
                 prepare(prepared.request, scope(fixture),
                   source_step_id: source.id,
                   llm_configuration_id: configuration_id
                 )

        assert inherited.request == prepared.request
        assert [_item] = inherited.bindings.items
        assert :ok = RequestImages.discard_staged_bindings(inherited.bindings)
      end
    end

    test "hydration reports the images it sends natively and whether the configuration accepted them" do
      fixture = request_fixture!(png_1x1())
      %{id: config} = create_configuration!(fixture.actor)

      {other, _content} =
        attach_content!(fixture.source_step, fixture.actor, jpeg_payload(), 2, "image/jpeg")

      first = responses_request(fixture.file)
      raw = put_blocks(first, image_blocks(first) ++ image_blocks(responses_request(other)))
      assert {:ok, prepared} = prepare(raw, scope(fixture), llm_configuration_id: config)
      step = publish!(fixture, prepared)
      pins = Map.new(bindings_for_step(step.id), &{&1.file.sha256, &1})
      :ok = ImageProviderVerdicts.record_accepted([fixture.file.sha256], config)
      parent = self()
      on_sent = &send(parent, {:sent, &1})

      sent = fn sha256, accepted? ->
        %{
          sha256: sha256,
          file_id: pins[sha256].file_id,
          source_file_external_id: to_string(pins[sha256].source_file_external_id),
          accepted?: accepted?
        }
      end

      expected =
        Enum.sort_by([sent.(fixture.file.sha256, true), sent.(other.sha256, false)], & &1.sha256)

      assert {:ok, _wire} =
               hydrate(prepared.request, step.id, llm_configuration_id: config, on_sent: on_sent)

      assert_receive {:sent, ^expected}

      # Without a configuration nothing is known to be accepted.
      assert {:ok, _wire} = hydrate(prepared.request, step.id, on_sent: on_sent)
      unknown = Enum.map(expected, &%{&1 | accepted?: false})
      assert_receive {:sent, ^unknown}

      # Images replaced by text are not sent.
      :ok = ImageProviderVerdicts.mark_rejected([other.sha256], config, "test: rejected")

      assert {:ok, _wire} =
               hydrate(prepared.request, step.id, llm_configuration_id: config, on_sent: on_sent)

      expected_sent = [sent.(fixture.file.sha256, true)]
      assert_receive {:sent, ^expected_sent}

      assert {:ok, _wire} = hydrate(image_request_without_markers(), nil, on_sent: on_sent)
      assert_receive {:sent, []}
    end

    @tag :whitebox
    test "the facts of the configuration are loaded with one query per preparation and hydration" do
      fixture = request_fixture!(png_1x1())
      %{id: config} = create_configuration!(fixture.actor)

      {other, _content} =
        attach_content!(fixture.source_step, fixture.actor, jpeg_payload(), 2, "image/jpeg")

      first = four_shape_request(fixture.file)
      raw = put_blocks(first, image_blocks(first) ++ image_blocks(four_shape_request(other)))

      {{:ok, prepared}, queries} =
        capture_queries(fn -> prepare(raw, scope(fixture), llm_configuration_id: config) end)

      assert length(selects_from(queries, "image_provider_verdicts")) == 1
      source = publish!(fixture, prepared)

      {{:ok, _wire}, queries} =
        capture_queries(fn ->
          hydrate(prepared.request, source.id, llm_configuration_id: config)
        end)

      assert length(selects_from(queries, "image_provider_verdicts")) == 1

      {{:ok, inherited}, queries} =
        capture_queries(fn ->
          prepare(prepared.request, scope(fixture),
            source_step_id: source.id,
            llm_configuration_id: config
          )
        end)

      assert length(selects_from(queries, "image_provider_verdicts")) == 1
      assert :ok = RequestImages.discard_staged_bindings(inherited.bindings)

      {{:ok, _wire}, queries} = capture_queries(fn -> hydrate(prepared.request, source.id) end)
      assert selects_from(queries, "image_provider_verdicts") == []
    end

    test "legacy thumbnail pins are still validated, hydrated, inherited and reused" do
      fixture = request_fixture!(png_1x1())
      ref = to_string(fixture.file.external_id)
      assert {:ok, prepared} = prepare(four_shape_request(fixture.file), scope(fixture))
      source = publish!(fixture, prepared)
      thumbnail = png(20, 10)
      binding = pin_legacy_thumbnail!(source, thumbnail)
      assert binding.variant_key == @thumbnail_variant

      assert :ok = validate_snapshot(prepared.request, source.id)
      assert {:ok, wire} = hydrate(prepared.request, source.id)
      assert_wire_payload(wire, thumbnail, "image/png")

      for {opts, origin} <- [{[source_step_id: source.id], :inherited}, {[], :reused}] do
        assert {:ok, staged} = prepare(prepared.request, scope(fixture), opts)
        assert staged.request == prepared.request
        assert [item] = staged.bindings.items
        assert item.variant_key == @thumbnail_variant
        assert %{^ref => %{sha256: sha256, origin: ^origin}} = staged.image_state.images
        assert sha256 == binding.file.sha256
        assert {:ok, {_file, ^thumbnail}} = Files.load_payload(item.file_id)
        assert :ok = RequestImages.discard_staged_bindings(staged.bindings)
      end
    end

    test "legacy exact pins of the raw request backfill are validated, hydrated, inherited and reused" do
      fixture = request_fixture!(png_1x1())
      ref = to_string(fixture.file.external_id)
      raw = legacy_exact_request(fixture.file)
      source = create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)
      exact = png(20, 10)
      assert {:ok, file} = Files.create_from_binary("exact.png", "image/png", exact)
      create_binding!(source.id, file.id, ref, ref, @legacy_exact_variant)

      assert :ok = validate_snapshot(raw, source.id)
      assert {:ok, wire} = hydrate(raw, source.id)
      assert_wire_payload(wire, exact, "image/png")

      for {request, opts, origin} <- [
            {raw, [source_step_id: source.id], :inherited},
            {four_shape_request(fixture.file), [], :reused}
          ] do
        assert {:ok, staged} = prepare(request, scope(fixture), opts)
        assert staged.request == request
        assert [item] = staged.bindings.items
        assert item.variant_key == @legacy_exact_variant
        assert %{^ref => %{origin: ^origin}} = staged.image_state.images
        assert {:ok, {_file, ^exact}} = Files.load_payload(item.file_id)
        assert :ok = RequestImages.discard_staged_bindings(staged.bindings)
      end
    end

    test "legacy exact pins above the request limits become text and never block new requests" do
      fixture = request_fixture!(png_1x1())
      ref = to_string(fixture.file.external_id)
      raw = legacy_exact_request(fixture.file)
      source = create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)
      assert {:ok, file} = Files.create_from_binary("exact.png", "image/png", oversized_png())
      create_binding!(source.id, file.id, ref, ref, @legacy_exact_variant)

      assert :ok = validate_snapshot(raw, source.id)
      assert {:ok, wire} = hydrate(raw, source.id)
      text = assert_omitted(wire, fixture.file, "exceeds the image input limits")
      assert {:ok, inherited} = prepare(raw, scope(fixture), source_step_id: source.id)
      assert inherited.bindings.items == []
      assert_fallback(inherited.request, text)

      # The newest pin of this file in the chat is the oversized exact one; a new
      # request falls back to the canonical file.
      assert {:ok, fresh} = prepare(four_shape_request(fixture.file), scope(fixture))
      assert [item] = fresh.bindings.items
      assert item.variant_key == "identity:v1"
      assert {:ok, {_file, bytes}} = Files.load_payload(item.file_id)
      assert bytes == fixture.payload
      assert :ok = RequestImages.discard_staged_bindings(fresh.bindings)
    end

    test "a missing inherited rendition payload fails even when canonical bytes are available" do
      fixture = request_fixture!(png_1x1())
      assert {:ok, prepared} = prepare(responses_request(fixture.file), scope(fixture))
      source = publish!(fixture, prepared)
      binding = pin_legacy_thumbnail!(source, png(20, 10))
      assert {:ok, {_file, bytes}} = Files.load_payload(binding.file_id)

      without_payload_blob(binding.file.sha256, bytes, fn path ->
        for expected <- [:payload_not_found, :request_image_payload_integrity_mismatch] do
          assert {:error, ^expected} =
                   prepare(prepared.request, scope(fixture), source_step_id: source.id)

          assert {:error, ^expected} = validate_snapshot(prepared.request, source.id)
          assert {:ok, {_file, original}} = Files.load_payload(fixture.file.id)
          assert original == fixture.payload
          File.write!(path, png_1x1())
        end
      end)
    end

    test "repeated inherited descriptors and hydration cannot change source identity or MIME" do
      fixture = request_fixture!(png_1x1())

      assert {:ok, prepared} =
               prepare(four_shape_request(fixture.file), scope(fixture))

      source = publish!(fixture, prepared)
      [responses, openrouter, anthropic, google] = image_blocks(prepared.request)
      ref = to_string(fixture.file.external_id)

      changed_mime =
        put_in(google, ["data", "$intellectual_club_file", "mime_type"], "image/jpeg")
        |> Map.put("mime_type", "image/jpeg")

      raw = put_blocks(prepared.request, [responses, openrouter, anthropic, changed_mime])

      assert {:error, {:request_image_binding_mime_mismatch, ^ref}} =
               prepare(raw, scope(fixture), source_step_id: source.id)

      assert {:error, {:request_image_binding_mime_mismatch, ^ref}} =
               hydrate(raw, source.id)

      wrong_outer_mime = Map.put(google, "mime_type", "image/jpeg")
      raw = put_blocks(prepared.request, [responses, openrouter, anthropic, wrong_outer_mime])

      assert {:error, {:request_image_block_mime_mismatch, ^ref}} =
               prepare(raw, scope(fixture), source_step_id: source.id)

      changed_source =
        put_in(
          responses,
          ["image_url", "$intellectual_club_file", "source_file_external_id"],
          Ash.UUID.generate()
        )

      raw = put_blocks(prepared.request, [changed_source])

      assert {:error, {:request_image_binding_source_mismatch, ^ref}} =
               prepare(raw, scope(fixture), source_step_id: source.id)

      assert saved_step(source.id).raw_request == prepared.request
    end

    test "exact image pins are inherited from reconstructed patch steps" do
      fixture = request_fixture!(png_1x1())

      request =
        Map.put(responses_request(fixture.file), "opaque_padding", String.duplicate("x", 4096))

      first =
        Persistence.create_request_step!(
          fixture.target_message,
          1,
          request,
          request_context: %{adapter_module: RequestImagesTestAdapter}
        )

      second =
        Persistence.create_request_step!(
          fixture.target_message,
          2,
          Map.put(first.request, "round", 2),
          request_context: %{adapter_module: RequestImagesTestAdapter},
          previous_request: first.request,
          previous_step: first.step,
          source_step_id: first.step.id
        )

      assert second.step.request_mode == :patch
      assert :ok = validate_snapshot(second.request, second.step.id)

      # The exact previous pin, not canonical lookup, must serve the third request.
      fixture.content
      |> Ash.Changeset.for_update(:update, %{file_id: nil}, actor: fixture.actor)
      |> Ash.update!(actor: fixture.actor)

      assert :ok = Files.delete_file_and_maybe_payload(fixture.file.id)

      third =
        Persistence.create_request_step!(
          fixture.target_message,
          3,
          Map.put(second.request, "round", 3),
          request_context: %{adapter_module: RequestImagesTestAdapter},
          previous_request: second.request,
          previous_step: second.step,
          source_step_id: second.step.id
        )

      assert third.step.request_mode == :patch
      assert :ok = validate_snapshot(third.request, third.step.id)
      assert {:ok, wire} = hydrate(third.request, third.step.id)
      assert inspect(wire) =~ "data:image/png;base64,"
    end
  end

  describe "staged file ownership and rollback" do
    test "formatter exceptions discard files staged before the callback failed" do
      fixture = request_fixture!(png_1x1())
      request = responses_request(fixture.file)
      before_count = count_files()

      mapper = fn raw, acc, mapper ->
        Responses.map_request_images(raw, acc, fn reference, state ->
          reference = %{reference | format: fn _, _ -> raise "Injected formatter failure" end}
          mapper.(reference, state)
        end)
      end

      assert_raise RuntimeError, "Injected formatter failure", fn ->
        RequestImages.prepare(request, scope(fixture), mapper: mapper)
      end

      assert count_files() == before_count
      assert [] == steps_for_message(fixture.target_message.id)
    end

    test "mapper throws after staging discard the entire staged journal" do
      fixture = request_fixture!(png_1x1())
      request = responses_request(fixture.file)
      before_count = count_files()

      mapper = fn raw, acc, callback ->
        result = Responses.map_request_images(raw, acc, callback)
        if is_map(acc) and Map.has_key?(acc, :staged), do: throw(:after_staging)
        result
      end

      assert catch_throw(RequestImages.prepare(request, scope(fixture), mapper: mapper)) ==
               :after_staging

      assert count_files() == before_count
    end

    test "preparation cleans already staged new files when an inherited pin fails later" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)

      source =
        create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)

      {file, _content} =
        attach_content!(fixture.source_step, fixture.actor, jpeg_payload(), 2, "image/jpeg")

      request = put_blocks(raw, image_blocks(responses_request(file)) ++ image_blocks(raw))
      count = count_files()
      ref = to_string(fixture.file.external_id)

      assert {:error, {:request_image_binding_not_found, ^ref}} =
               prepare(request, scope(fixture), source_step_id: source.id)

      assert count_files() == count
      assert bindings_for_step(source.id) == []
      assert {:ok, {_file, bytes}} = Files.load_payload(file.id)
      assert bytes == jpeg_payload()
    end

    test "prepare plus attach rolls back atomically and discards only unowned staged files" do
      fixture = request_fixture!(png_1x1())
      assert {:ok, first} = prepare(responses_request(fixture.file), scope(fixture))
      source = publish!(fixture, first)

      assert {:ok, staged} =
               prepare(first.request, scope(fixture), source_step_id: source.id)

      [item] = staged.bindings.items
      count = count_files()

      assert {:error, :publication_failed} =
               Repo.transaction(fn ->
                 replacement =
                   create_request_step!(
                     fixture.actor,
                     fixture.target_message.id,
                     2,
                     staged.request
                   )

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
      assert :ok = validate_snapshot(first.request, source.id)
      assert saved_step(source.id).updated_at == source.updated_at
      assert count_files() == count - 1
    end

    test "transactional attachment errors can roll back partial bindings without losing staged ownership" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, first} = prepare(raw, scope(fixture))
      assert {:ok, second} = prepare(raw, scope(fixture))
      staged = %StagedBindings{items: first.bindings.items ++ second.bindings.items}

      assert {:error, _reason} =
               Repo.transaction(fn ->
                 step =
                   create_request_step!(fixture.actor, fixture.target_message.id, 1, raw)

                 assert {:error, {:attach_staged_binding_failed, _ref, _reason}} =
                          RequestImages.attach_staged_bindings_transactional(staged, step.id)

                 Repo.rollback(:attach_failed)
               end)

      assert steps_for_message(fixture.target_message.id) == []
      assert :ok = RequestImages.discard_staged_bindings(staged)
      assert count_files() == 1
    end

    test "staging source-local copies inside a failed replacement transaction preserves the source" do
      fixture = request_fixture!(png_1x1())

      assert {:ok, prepared} =
               prepare(responses_request(fixture.file), scope(fixture))

      source = publish!(fixture, prepared)
      [binding] = bindings_for_step(source.id)

      assert {:error, :forced_retry_failure} =
               Repo.transaction(fn ->
                 assert {:ok, staged} = RequestImages.stage_bindings(source.id)
                 Ash.destroy!(source, actor: fixture.actor)

                 replacement =
                   create_request_step!(
                     fixture.actor,
                     fixture.target_message.id,
                     1,
                     prepared.request
                   )

                 assert :ok =
                          RequestImages.attach_staged_bindings_transactional(
                            staged,
                            replacement.id
                          )

                 Repo.rollback(:forced_retry_failure)
               end)

      assert [restored] = bindings_for_step(source.id)
      assert restored.id == binding.id
      assert :ok = validate_snapshot(prepared.request, source.id)
      assert {:ok, {_file, payload}} = Files.load_payload(restored.file_id)
      assert payload == fixture.payload
    end
  end

  describe "access scope" do
    test "canonical and reusable pins remain owner and chat scoped" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      source = publish!(fixture, prepared)
      other_chat = create_chat!(fixture.actor)
      other_scope = %ExecutionContext{owner_id: fixture.actor.id, chat_id: other_chat.id}
      assert {:ok, denied} = prepare(raw, other_scope)
      assert denied.bindings.items == []

      assert [%{"type" => "input_text", "text" => @unavailable_fallback}] =
               image_blocks(denied.request)

      assert {:error, :request_image_source_out_of_scope} =
               prepare(raw, other_scope, source_step_id: source.id)

      %{user: other_actor} = user_fixture()

      assert {:error, :request_image_source_out_of_scope} =
               prepare(
                 raw,
                 %ExecutionContext{owner_id: other_actor.id, chat_id: fixture.chat.id},
                 source_step_id: source.id
               )

      assert {:ok, denied} =
               prepare(raw, %ExecutionContext{
                 owner_id: other_actor.id,
                 chat_id: fixture.chat.id
               })

      assert denied.bindings.items == []
    end

    test "explicit available files resolve with no chat while nil scope grants no implicit access" do
      assert {:ok, file} = Files.create_from_binary("available.png", "image/png", png_1x1())
      raw = responses_request(file)
      assert {:ok, denied} = prepare(raw, %ExecutionContext{})
      assert denied.bindings.items == []

      assert {:ok, prepared} =
               prepare(raw, %ExecutionContext{
                 available_file_external_ids: [to_string(file.external_id)]
               })

      assert prepared.request == raw
      assert [_item] = prepared.bindings.items
      assert :ok = RequestImages.discard_staged_bindings(prepared.bindings)
    end

    test "standalone chats cannot reuse another chat's pins after canonical media is removed" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      source = publish!(fixture, prepared)
      Ash.destroy!(fixture.content, actor: fixture.actor)

      standalone = create_chat!(fixture.actor)
      standalone_scope = %ExecutionContext{owner_id: fixture.actor.id, chat_id: standalone.id}
      assert {:ok, denied} = prepare(raw, standalone_scope)
      assert denied.bindings.items == []

      assert {:error, :request_image_source_out_of_scope} =
               prepare(raw, standalone_scope, source_step_id: source.id)
    end

    test "linked forks permit exact prefix pins but never future parent refs or snapshots" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      anchor = publish!(fixture, prepared)
      call = create_tool_call!(anchor, fixture.actor)

      future_message =
        create_message!(fixture.actor, fixture.chat.id,
          role: :user,
          parent_id: fixture.target_message.id,
          token_count: 0
        )

      future_content_step =
        create_request_step!(fixture.actor, future_message.id, 1)

      {future_file, _content} =
        attach_content!(future_content_step, fixture.actor, jpeg_payload(), 1, "image/jpeg")

      future_raw = responses_request(future_file)
      assert {:ok, future} = prepare(future_raw, scope(fixture))
      future_step = publish!(fixture, future, 2)
      fork = linked_fork!(fixture, anchor, call)
      fork_scope = %ExecutionContext{owner_id: fixture.actor.id, chat_id: fork.id}

      assert {:ok, denied} = prepare(future_raw, fork_scope)
      assert denied.bindings.items == []

      assert [%{"type" => "input_text", "text" => @unavailable_fallback}] =
               image_blocks(denied.request)

      assert {:error, :request_image_source_out_of_scope} =
               prepare(future_raw, fork_scope, source_step_id: future_step.id)

      Ash.destroy!(fixture.content, actor: fixture.actor)
      assert {:ok, inherited} = prepare(raw, fork_scope, source_step_id: anchor.id)
      assert inherited.request == raw
      assert [_item] = inherited.bindings.items
      assert :ok = RequestImages.discard_staged_bindings(inherited.bindings)
    end
  end

  describe "wire cache" do
    test "cold hydration loads once and encodes repeated occurrences once per wire format" do
      fixture = request_fixture!(png_1x1())
      raw = four_shape_request(fixture.file)
      raw = put_blocks(raw, List.duplicate(image_blocks(raw), 3) |> List.flatten())
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      assert prepared.image_state.request == prepared.request
      assert map_size(prepared.image_state.descriptors) == 1
      assert map_size(prepared.image_state.cache) == 2
      assert_wire_cache(prepared.image_state.cache, fixture.payload)
      refute Jason.encode!(prepared.request) =~ ";base64,"
      step = publish!(fixture, prepared)
      telemetry = observe_image_cache()
      {cache_tag, cache_opts} = cache_probe()

      assert {:ok, wire} = hydrate(prepared.request, step.id, cache_opts)

      for blocks <- Enum.chunk_every(image_blocks(wire), 4) do
        assert_wire_blocks(blocks, fixture.payload, "image/png")
      end

      assert_receive {^cache_tag, cache}
      assert cache == prepared.image_state.cache
      assert_wire_cache(cache, fixture.payload)
      encoded_size = byte_size(Base.encode64(fixture.payload))

      assert image_cache_counters(telemetry) == %{
               loaded_bytes: byte_size(fixture.payload),
               miss: 2,
               hit: 0,
               encoded_bytes: encoded_size * 2 + byte_size("data:image/png;base64,")
             }
    end

    test "a warm hydration reuses the verified wire cache without loading or encoding bytes" do
      fixture = request_fixture!(png_1x1())
      assert {:ok, prepared} = prepare(four_shape_request(fixture.file), scope(fixture))
      step = publish!(fixture, prepared)
      [binding] = bindings_for_step(step.id)
      telemetry = observe_image_cache()
      {cache_tag, cache_opts} = cache_probe()

      assert {:ok, first_wire} = hydrate(prepared.request, step.id, cache_opts)
      assert_receive {^cache_tag, cache}
      assert image_cache_counters(telemetry).loaded_bytes == byte_size(fixture.payload)

      without_payload_blob(binding.file.sha256, fixture.payload, fn _path ->
        warm_opts = Keyword.put(cache_opts, :cache, cache)
        assert {:ok, ^first_wire} = hydrate(prepared.request, step.id, warm_opts)
        assert_receive {^cache_tag, ^cache}

        assert %{loaded_bytes: 0, miss: 0, encoded_bytes: 0, hit: hits} =
                 image_cache_counters(telemetry)

        assert hits > 0
        assert_wire_cache(cache, fixture.payload)
        assert saved_step(step.id).raw_request == prepared.request
      end)
    end

    test "inherited prepare reuses a warm cache while staging independent logical files" do
      fixture = request_fixture!(png_1x1())
      assert {:ok, prepared} = prepare(four_shape_request(fixture.file), scope(fixture))
      source = publish!(fixture, prepared)
      [source_binding] = bindings_for_step(source.id)
      Ash.destroy!(fixture.content, actor: fixture.actor)
      assert {:error, _} = Ash.get(StoredFile, fixture.file.id, authorize?: false)

      without_payload_blob(source_binding.file.sha256, fixture.payload, fn _path ->
        telemetry = observe_image_cache()

        assert {:ok, inherited} =
                 prepare(prepared.request, scope(fixture),
                   source_step_id: source.id,
                   cache: prepared.image_state.cache
                 )

        assert inherited.request == prepared.request
        assert inherited.image_state.request == prepared.request
        assert inherited.image_state.cache == prepared.image_state.cache
        assert_wire_cache(inherited.image_state.cache, fixture.payload)
        assert [item] = inherited.bindings.items
        refute item.file_id == source_binding.file_id
        assert item.reference_key == to_string(source_binding.reference_key)
        step = publish!(fixture, inherited, 2)

        assert {:ok, wire} =
                 hydrate(inherited.request, step.id, cache: inherited.image_state.cache)

        assert_wire_payload(wire, fixture.payload, "image/png")

        assert %{loaded_bytes: 0, miss: 0, encoded_bytes: 0, hit: hits} =
                 image_cache_counters(telemetry)

        assert hits > 0
        assert saved_step(source.id).raw_request == prepared.request
        assert saved_step(step.id).raw_request == prepared.request
      end)
    end

    test "a warm cache never bypasses a missing step-local binding" do
      fixture = request_fixture!(png_1x1())
      assert {:ok, prepared} = prepare(responses_request(fixture.file), scope(fixture))
      _source = publish!(fixture, prepared)

      unbound =
        create_request_step!(fixture.actor, fixture.target_message.id, 2, prepared.request)

      ref = to_string(fixture.file.external_id)
      count = count_files()
      telemetry = observe_image_cache()
      {cache_tag, cache_opts} = cache_probe(prepared.image_state.cache)

      for step_id <- [nil, unbound.id] do
        assert {:error, {:request_image_binding_not_found, ^ref}} =
                 hydrate(prepared.request, step_id, cache_opts)
      end

      assert {:error, {:request_image_binding_not_found, ^ref}} =
               prepare(prepared.request, scope(fixture),
                 source_step_id: unbound.id,
                 cache: prepared.image_state.cache
               )

      assert count_files() == count
      assert bindings_for_step(unbound.id) == []
      assert_no_image_cache_work(telemetry)
      refute_received {^cache_tag, _cache}
    end

    test "a warm cache cannot bypass source and variant validation of an existing binding" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      _source = publish!(fixture, prepared)
      ref = to_string(fixture.file.external_id)
      telemetry = observe_image_cache()

      for {{source_ref, variant, expected_error}, sequence} <-
            Enum.with_index(
              [
                {Ash.UUID.generate(), "identity:v1",
                 {:request_image_binding_source_mismatch, ref}},
                {ref, "unknown:v1", {:unsupported_request_image_binding_variant, "unknown:v1"}}
              ],
              2
            ) do
        step = create_request_step!(fixture.actor, fixture.target_message.id, sequence, raw)
        assert {:ok, file} = Files.duplicate_file(fixture.file.id)
        create_binding!(step.id, file.id, ref, source_ref, variant)

        assert {:error, ^expected_error} =
                 hydrate(raw, step.id, cache: prepared.image_state.cache)

        assert {:error, ^expected_error} =
                 prepare(raw, scope(fixture),
                   source_step_id: step.id,
                   cache: prepared.image_state.cache
                 )
      end

      assert_no_image_cache_work(telemetry)
    end

    test "cache keys use the bound content rather than only the stable image reference" do
      fixture = request_fixture!(png_1x1())
      raw = responses_request(fixture.file)
      assert {:ok, prepared} = prepare(raw, scope(fixture))
      _source = publish!(fixture, prepared)
      ref = to_string(fixture.file.external_id)
      changed_payload = IntellectualClub.ImageFixtures.png(2, 1)

      assert {:ok, changed_file} =
               Files.create_from_binary("changed.png", "image/png", changed_payload)

      changed_step = create_request_step!(fixture.actor, fixture.target_message.id, 2, raw)
      create_binding!(changed_step.id, changed_file.id, ref, ref, "identity:v1")
      telemetry = observe_image_cache()
      {cache_tag, cache_opts} = cache_probe(prepared.image_state.cache)

      assert {:ok, wire} = hydrate(raw, changed_step.id, cache_opts)

      assert [block] = image_blocks(wire)
      assert block["image_url"] == "data:image/png;base64," <> Base.encode64(changed_payload)
      assert_receive {^cache_tag, updated_cache}
      assert_wire_cache(updated_cache, changed_payload)
      assert Map.keys(updated_cache) == [{changed_file.sha256, "image/png", :data_url}]

      assert image_cache_counters(telemetry) == %{
               loaded_bytes: byte_size(changed_payload),
               miss: 1,
               hit: 0,
               encoded_bytes: byte_size(block["image_url"])
             }
    end

    test "cold hydration rejects missing and same-size corrupt payloads without cache updates" do
      fixture = request_fixture!(png_1x1())
      assert {:ok, prepared} = prepare(responses_request(fixture.file), scope(fixture))
      step = publish!(fixture, prepared)
      [binding] = bindings_for_step(step.id)

      without_payload_blob(binding.file.sha256, fixture.payload, fn path ->
        telemetry = observe_image_cache()
        {cache_tag, cache_opts} = cache_probe()

        assert {:error, :payload_not_found} = hydrate(prepared.request, step.id, cache_opts)
        assert_no_image_cache_work(telemetry)

        <<_first, rest::binary>> = fixture.payload
        File.write!(path, <<0, rest::binary>>)

        assert {:error, :request_image_payload_integrity_mismatch} =
                 hydrate(prepared.request, step.id, cache_opts)

        assert image_cache_counters(telemetry) == %{
                 loaded_bytes: byte_size(fixture.payload),
                 miss: 0,
                 hit: 0,
                 encoded_bytes: 0
               }

        refute_received {^cache_tag, _cache}
      end)
    end
  end

  defp prepare(request, scope, opts \\ []) do
    RequestImages.prepare(request, scope, with_mapper(opts))
  end

  defp hydrate(request, step_id, opts \\ []) do
    RequestImages.hydrate(request, step_id, with_mapper(opts))
  end

  defp validate_snapshot(request, step_id) do
    RequestImages.validate_snapshot(request, step_id, with_mapper([]))
  end

  defp with_mapper(opts),
    do: Keyword.put_new(opts, :mapper, &RequestImagesTestAdapter.map_request_images/3)

  defp request_fixture!(payload, opts \\ []) do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor)
    source_message = create_message!(actor, chat.id, role: :user, token_count: 0)

    source_step =
      create_request_step!(actor, source_message.id, 1)

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
        do:
          create_message!(actor, chat.id,
            role: :assistant,
            parent_id: source_message.id,
            token_count: 0
          )

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

  defp publish!(fixture, prepared, sequence \\ 1) do
    assert {:ok, step} =
             Repo.transaction(fn ->
               step =
                 create_request_step!(
                   fixture.actor,
                   fixture.target_message.id,
                   sequence,
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
    item = create_item!(actor, step, sequence: sequence, type: :input)
    {:ok, file} = Files.create_from_binary(filename, mime_type, payload)
    {file, create_content!(actor, item, kind: :media, file_id: file.id)}
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
    item = create_item!(actor, step, type: :tool_call)

    create_content!(actor, item,
      kind: :opaque,
      content_json: %{
        "call_id" => "fork_images",
        "name" => "fork_chat",
        "arguments" => %{"task" => "inspect images"}
      }
    )

    item
  end

  defp linked_fork!(fixture, anchor, call) do
    parent = %{chat: fixture.chat, message: fixture.target_message, step: anchor, item: call}
    create_linked_chat!(fixture.actor, parent, subagent: false, fork_task: "inspect images")
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

  # All four shapes with markers as the former raw request backfill wrote them.
  defp legacy_exact_request(file), do: file |> four_shape_request() |> put_legacy_rendition()

  defp put_legacy_rendition(%{"$intellectual_club_file" => marker}) do
    rendition = %{"kind" => "legacy_exact", "format" => "preserve"}
    %{"$intellectual_club_file" => Map.put(marker, "rendition", rendition)}
  end

  defp put_legacy_rendition(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, put_legacy_rendition(nested)} end)

  defp put_legacy_rendition(value) when is_list(value),
    do: Enum.map(value, &put_legacy_rendition/1)

  defp put_legacy_rendition(value), do: value

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

  defp image_request_without_markers do
    %{"input" => [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]}]}
  end

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

  defp assert_omitted(request, file, phrase, opts \\ []) do
    [%{"text" => text} | _blocks] = image_blocks(request)
    assert_fallback(request, text, opts)
    assert text =~ "file_id=#{file.external_id}"
    assert text =~ phrase
    assert text =~ "The file remains available to file tools."
    text
  end

  defp verdict(file) do
    case Ash.get(ImageVerdict, file.sha256, authorize?: false) do
      {:ok, verdict} -> verdict
      {:error, _not_found} -> nil
    end
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

  defp create_request_step!(actor, message_id, sequence, raw_request \\ %{}) do
    create_step!(actor, message_id,
      sequence: sequence,
      raw_request: raw_request,
      response_final: true
    )
  end

  defp pass_through_case(:non_content_markers) do
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

    {raw, %ExecutionContext{}, with_mapper(source_step_id: -1)}
  end

  defp pass_through_case(:legacy_inline) do
    data = Base.encode64(png_1x1())
    data_url = "data:image/png;base64," <> data

    blocks = [
      %{"type" => "input_image", "image_url" => data_url},
      %{"type" => "image_url", "image_url" => %{"url" => data_url}},
      %{
        "type" => "image",
        "source" => %{"type" => "base64", "media_type" => "image/png", "data" => data}
      },
      %{"type" => "image", "mime_type" => "image/png", "data" => data}
    ]

    raw = %{"messages" => [%{"role" => "user", "content" => blocks}]}
    {raw, %ExecutionContext{step_id: -1}, with_mapper(source_step_id: -1)}
  end

  defp pass_through_case(:empty_input),
    do: {%{"input" => []}, %ExecutionContext{step_id: -1}, with_mapper(source_step_id: -1)}

  defp pass_through_case(:text_input),
    do: {%{"input" => "hello"}, %ExecutionContext{step_id: -1}, with_mapper(source_step_id: -1)}

  defp pass_through_case(:no_mapper) do
    raw = four_shape_request(%{external_id: Ash.UUID.generate(), mime_type: "image/png"})
    {raw, %ExecutionContext{}, [mapper: RequestImages.mapper(nil)]}
  end
end
