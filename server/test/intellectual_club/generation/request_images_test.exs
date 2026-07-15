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
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.RequestImages.StagedBindings

  require Ash.Query

  @invalid_fallback "[Image omitted: attached file could not be validated as an image.]"
  @resize_fallback "[Image omitted: attached image exceeded the native image size limit and could not be resized.]"

  test "materializes one identity binding and hydrates all four provider shapes" do
    fixture = request_fixture!(image_payload())
    raw_request = four_shape_request(fixture.file)

    file_count_before = count_files()

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, fixture.target_step.id)

    assert [binding] = bindings_for_step(fixture.target_step.id)
    assert binding.variant_key == "identity:v1"
    assert to_string(binding.reference_key) == to_string(fixture.file.external_id)
    assert count_files() == file_count_before + 1

    persisted_step = Ash.get!(ChatMessageStep, fixture.target_step.id, authorize?: false)
    assert persisted_step.raw_request == compact_request

    Process.sleep(2)

    assert {:ok, ^compact_request} =
             RequestImages.materialize_and_persist(compact_request, fixture.target_step.id)

    assert [same_binding] = bindings_for_step(fixture.target_step.id)
    assert same_binding.id == binding.id
    assert count_files() == file_count_before + 1

    unchanged_step = Ash.get!(ChatMessageStep, fixture.target_step.id, authorize?: false)
    assert unchanged_step.updated_at == persisted_step.updated_at

    assert {:ok, wire_request} =
             RequestImages.hydrate(compact_request, fixture.target_step.id)

    [responses, openrouter, anthropic, google] = image_blocks(wire_request)

    assert decode_data_url(responses["image_url"]) == fixture.payload
    assert decode_data_url(openrouter["image_url"]["url"]) == fixture.payload
    assert Base.decode64!(anthropic["source"]["data"]) == fixture.payload
    assert anthropic["source"]["media_type"] == "image/png"
    assert Base.decode64!(google["data"]) == fixture.payload
    assert google["mime_type"] == "image/png"

    assert {:error, {:request_image_binding_not_found, _reference_key}} =
             RequestImages.hydrate(compact_request, fixture.unbound_step.id)
  end

  test "stores an oversized image as a bounded thumbnail and keeps the canonical payload" do
    fixture = request_fixture!(oversized_png_payload())
    raw_request = responses_request(fixture.file)

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, fixture.target_step.id)

    assert [binding] = bindings_for_step(fixture.target_step.id)
    assert binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"

    assert {:ok, {_request_file, resized_payload}} = Files.load_payload(binding.file_id)

    assert {"image/png", resized_width, resized_height, _variant} =
             ExImageInfo.info(resized_payload)

    assert max(resized_width, resized_height) <= 2_000

    assert {:ok, {_source_file, original_payload}} = Files.load_payload(fixture.file.id)
    assert {"image/png", 3_000, 1_500, _variant} = ExImageInfo.info(original_payload)

    assert {:ok, wire_request} =
             RequestImages.hydrate(compact_request, fixture.target_step.id)

    [wire_block] = image_blocks(wire_request)
    assert decode_data_url(wire_block["image_url"]) == resized_payload
  end

  test "materializes an oversized attachment on its canonical message step" do
    fixture = request_fixture!(oversized_png_payload())
    raw_request = responses_request(fixture.file)

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, fixture.source_step.id)

    assert compact_request == raw_request
    assert [binding] = bindings_for_step(fixture.source_step.id)
    assert binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
  end

  test "updates compact and wire MIME types from the validated image payload" do
    fixture = request_fixture!(jpeg_payload(), mime_type: "image/png", filename: "declared.png")

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(
               four_shape_request(fixture.file),
               fixture.target_step.id
             )

    [responses, openrouter, anthropic, google] = image_blocks(compact_request)

    assert marker_mime_type(responses["image_url"]) == "image/jpeg"
    assert marker_mime_type(openrouter["image_url"]["url"]) == "image/jpeg"
    assert marker_mime_type(anthropic["source"]["data"]) == "image/jpeg"
    assert anthropic["source"]["media_type"] == "image/jpeg"
    assert marker_mime_type(google["data"]) == "image/jpeg"
    assert google["mime_type"] == "image/jpeg"

    assert {:ok, wire_request} =
             RequestImages.hydrate(compact_request, fixture.target_step.id)

    [responses, _openrouter, anthropic, google] = image_blocks(wire_request)
    assert String.starts_with?(responses["image_url"], "data:image/jpeg;base64,")
    assert anthropic["source"]["media_type"] == "image/jpeg"
    assert google["mime_type"] == "image/jpeg"
  end

  test "uses the resize-specific fallback when an oversized format cannot be resized" do
    fixture =
      request_fixture!(oversized_bmp_header_payload(),
        mime_type: "image/bmp",
        filename: "source.bmp"
      )

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(
               responses_request(fixture.file),
               fixture.target_step.id
             )

    assert [%{"type" => "input_text", "text" => @resize_fallback}] =
             image_blocks(compact_request)

    assert [] == bindings_for_step(fixture.target_step.id)
  end

  test "concurrent materialization converges on one step binding" do
    fixture = request_fixture!(image_payload())
    raw_request = responses_request(fixture.file)

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn ->
          RequestImages.materialize_and_persist(raw_request, fixture.target_step.id)
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, _compact_request}, &1))
    assert [_binding] = bindings_for_step(fixture.target_step.id)
    assert count_files() == 2
  end

  test "removes bindings which are no longer present in the compact request" do
    fixture = request_fixture!(image_payload())
    empty_request = %{"input" => []}

    assert {:ok, _compact_request} =
             RequestImages.materialize_and_persist(
               responses_request(fixture.file),
               fixture.target_step.id
             )

    assert [binding] = bindings_for_step(fixture.target_step.id)

    persisted_step =
      fixture.target_step
      |> Ash.Changeset.for_update(:update, %{raw_request: empty_request}, authorize?: false)
      |> Ash.update!(authorize?: false)

    Process.sleep(2)

    assert {:ok, ^empty_request} =
             RequestImages.materialize_and_persist(empty_request, fixture.target_step.id)

    assert [] == bindings_for_step(fixture.target_step.id)

    assert Ash.get!(ChatMessageStep, fixture.target_step.id, authorize?: false).updated_at ==
             persisted_step.updated_at

    assert {:error, _error} = Ash.get(StoredFile, binding.file_id, authorize?: false)
    assert Ash.get!(StoredFile, fixture.file.id, authorize?: false).id == fixture.file.id
  end

  test "stale cleanup failure preserves the compact request and binding ownership" do
    fixture = request_fixture!(oversized_png_payload())

    assert {:ok, _compact_request} =
             RequestImages.materialize_and_persist(
               responses_request(fixture.file),
               fixture.target_step.id
             )

    [binding] = bindings_for_step(fixture.target_step.id)
    assert {:ok, {_file, rendition_payload}} = Files.load_payload(binding.file_id)
    replace_payload_with_directory!(binding.file.sha256)

    assert {:ok, empty_request} =
             RequestImages.materialize_and_persist(%{"input" => []}, fixture.target_step.id)

    assert empty_request == %{"input" => []}

    assert Ash.get!(ChatMessageStep, fixture.target_step.id, authorize?: false).raw_request ==
             empty_request

    assert Ash.get!(ChatMessageStepRequestFile, binding.id, authorize?: false).id == binding.id
    assert Ash.get!(StoredFile, binding.file_id, authorize?: false).id == binding.file_id

    restore_payload!(binding.file.sha256, rendition_payload)

    assert {:ok, %{"input" => []}} =
             RequestImages.materialize_and_persist(%{"input" => []}, fixture.target_step.id)

    assert [] == bindings_for_step(fixture.target_step.id)
  end

  test "replaces invalid image blocks with provider-native fallback text" do
    fixture = request_fixture!("<html><body>not an image</body></html>")
    raw_request = four_shape_request(fixture.file, anthropic_cache_control?: true)

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, fixture.target_step.id)

    assert [] == bindings_for_step(fixture.target_step.id)

    assert [responses, openrouter, anthropic, google] = image_blocks(compact_request)
    assert responses == %{"type" => "input_text", "text" => @invalid_fallback}
    assert openrouter == %{"type" => "text", "text" => @invalid_fallback}

    assert anthropic == %{
             "type" => "text",
             "text" => @invalid_fallback,
             "cache_control" => %{"type" => "ephemeral"}
           }

    assert google == %{"type" => "text", "text" => @invalid_fallback}
    refute Jason.encode!(compact_request) =~ "$intellectual_club_file"
  end

  test "ignores markers in parameters, tool arguments, and opaque result maps" do
    fixture = request_fixture!(image_payload())
    marker = RequestImages.marker(to_string(fixture.file.external_id), "image/png")

    raw_request = %{
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

    assert {:ok, ^raw_request} =
             RequestImages.materialize_and_persist(raw_request, fixture.target_step.id)

    assert [] == bindings_for_step(fixture.target_step.id)
    assert {:ok, ^raw_request} = RequestImages.hydrate(raw_request, nil)
  end

  test "leaves legacy requests untouched and rejects an unbound marker without a step" do
    fixture = request_fixture!(image_payload())

    legacy = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/png;base64,#{Base.encode64(image_payload())}"}
            }
          ]
        }
      ]
    }

    file_count_before = count_files()

    assert {:ok, ^legacy} =
             RequestImages.materialize_and_persist(legacy, fixture.target_step.id)

    persisted_step = Ash.get!(ChatMessageStep, fixture.target_step.id, authorize?: false)
    Process.sleep(2)

    assert {:ok, ^legacy} =
             RequestImages.materialize_and_persist(legacy, fixture.target_step.id)

    unchanged_step = Ash.get!(ChatMessageStep, fixture.target_step.id, authorize?: false)

    assert unchanged_step.updated_at == persisted_step.updated_at
    assert count_files() == file_count_before
    assert [] == bindings_for_step(fixture.target_step.id)
    assert {:ok, ^legacy} = RequestImages.hydrate(legacy, nil)

    external_id = Ash.UUID.generate()
    request = responses_request(%{external_id: external_id, mime_type: "image/png"})

    assert {:error, {:request_image_binding_not_found, ^external_id}} =
             RequestImages.hydrate(request, nil)
  end

  test "reuses and clones pinned files after the canonical attachment is deleted" do
    fixture = request_fixture!(image_payload())
    raw_request = responses_request(fixture.file)

    assert {:ok, compact_request} =
             RequestImages.materialize_and_persist(raw_request, fixture.target_step.id)

    assert :ok = RequestImages.clone_bindings(fixture.target_step.id, fixture.unbound_step.id)

    [source_binding] = bindings_for_step(fixture.target_step.id)
    [cloned_binding] = bindings_for_step(fixture.unbound_step.id)
    assert cloned_binding.file_id != source_binding.file_id
    assert cloned_binding.file.sha256 == source_binding.file.sha256

    Ash.destroy!(fixture.content, actor: fixture.actor)
    assert {:error, _error} = Ash.get(StoredFile, fixture.file.id, authorize?: false)

    assert {:ok, wire_request} =
             RequestImages.hydrate(compact_request, fixture.unbound_step.id)

    assert [wire_block] = image_blocks(wire_request)
    assert decode_data_url(wire_block["image_url"]) == fixture.payload

    reused_step = create_step!(fixture.target_message.id, 3, fixture.actor)

    assert {:ok, ^compact_request} =
             RequestImages.materialize_and_persist(compact_request, reused_step.id)

    [reused_binding] = bindings_for_step(reused_step.id)
    assert reused_binding.file_id not in [source_binding.file_id, cloned_binding.file_id]
    assert reused_binding.file.sha256 == source_binding.file.sha256

    Ash.destroy!(fixture.target_step, actor: fixture.actor)
    Ash.destroy!(fixture.unbound_step, actor: fixture.actor)
    assert FilesystemStorage.exists?(source_binding.file.sha256)

    Ash.destroy!(reused_step, actor: fixture.actor)
    refute FilesystemStorage.exists?(source_binding.file.sha256)
  end

  test "transactional staging preserves the source payload when retry replacement rolls back" do
    fixture = request_fixture!(image_payload())
    raw_request = responses_request(fixture.file)

    assert {:ok, _compact_request} =
             RequestImages.materialize_and_persist(raw_request, fixture.target_step.id)

    [binding] = bindings_for_step(fixture.target_step.id)
    sha256 = binding.file.sha256

    assert {:error, :forced_retry_failure} =
             Repo.transaction(fn ->
               assert {:ok, staged} = RequestImages.stage_bindings(fixture.target_step.id)
               Ash.destroy!(fixture.target_step, actor: fixture.actor)

               replacement = create_step!(fixture.target_message.id, 1, fixture.actor)

               assert :ok =
                        RequestImages.attach_staged_bindings_transactional(
                          staged,
                          replacement.id
                        )

               Repo.rollback(:forced_retry_failure)
             end)

    assert Ash.get!(ChatMessageStep, fixture.target_step.id, actor: fixture.actor).id ==
             fixture.target_step.id

    assert [restored_binding] = bindings_for_step(fixture.target_step.id)
    assert restored_binding.id == binding.id
    assert FilesystemStorage.exists?(sha256)
    assert {:ok, {_file, payload}} = Files.load_payload(restored_binding.file_id)
    assert payload == fixture.payload
  end

  test "discarding staged files reports payload cleanup failures" do
    payload = "staged cleanup payload"

    assert {:ok, file} =
             Files.create_from_binary("staged.bin", "application/octet-stream", payload)

    staged = %StagedBindings{items: [%{file_id: file.id}]}
    replace_payload_with_directory!(file.sha256)

    assert {:error, {:staged_file_cleanup_failed, [{file_id, _reason}]}} =
             RequestImages.discard_staged_bindings(staged)

    assert file_id == file.id
    assert Ash.get!(StoredFile, file.id, authorize?: false).id == file.id

    restore_payload!(file.sha256, payload)
    assert :ok = RequestImages.discard_staged_bindings(staged)
    assert {:error, _error} = Ash.get(StoredFile, file.id, authorize?: false)
  end

  defp request_fixture!(payload, opts \\ []) do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    source_message = create_message!(chat.id, :user, actor)
    source_step = create_step!(source_message.id, 1, actor)

    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: source_step.id, sequence: 1, type: :input},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    mime_type = Keyword.get(opts, :mime_type, "image/png")
    filename = Keyword.get(opts, :filename, "source.png")
    {:ok, file} = Files.create_from_binary(filename, mime_type, payload)

    content =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: item.id,
          sequence: 1,
          kind: :media,
          file_id: file.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    target_message = create_message!(chat.id, :assistant, actor, source_message.id)
    target_step = create_step!(target_message.id, 1, actor)
    unbound_step = create_step!(target_message.id, 2, actor)

    %{
      actor: actor,
      chat: chat,
      source_message: source_message,
      source_step: source_step,
      target_message: target_message,
      target_step: target_step,
      unbound_step: unbound_step,
      content: content,
      file: file,
      payload: payload
    }
  end

  defp create_message!(chat_id, role, actor, parent_id \\ nil) do
    attrs = %{
      chat_id: chat_id,
      role: role,
      parent_id: parent_id,
      status: :done,
      token_count: 0
    }

    ChatMessage
    |> Ash.Changeset.for_create(:add_message, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_step!(message_id, sequence, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_id: message_id,
        sequence: sequence,
        status: :done,
        raw_request: %{}
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp four_shape_request(file, opts \\ []) do
    data_url_marker = RequestImages.marker(to_string(file.external_id), file.mime_type, :data_url)
    base64_marker = RequestImages.marker(to_string(file.external_id), file.mime_type, :base64)

    anthropic = %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => file.mime_type,
        "data" => base64_marker
      }
    }

    anthropic =
      if Keyword.get(opts, :anthropic_cache_control?, false) do
        Map.put(anthropic, "cache_control", %{"type" => "ephemeral"})
      else
        anthropic
      end

    %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "input_image", "image_url" => data_url_marker},
            %{"type" => "image_url", "image_url" => %{"url" => data_url_marker}},
            anthropic,
            %{"type" => "image", "mime_type" => file.mime_type, "data" => base64_marker}
          ]
        }
      ]
    }
  end

  defp responses_request(file) do
    marker = RequestImages.marker(to_string(file.external_id), file.mime_type, :data_url)

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

  defp image_blocks(request) do
    container = List.first(request["messages"] || request["input"])
    container["content"]
  end

  defp bindings_for_step(step_id) do
    ChatMessageStepRequestFile
    |> Ash.Query.filter(chat_message_step_id == ^step_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false, load: [:file])
  end

  defp count_files do
    StoredFile
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp decode_data_url("data:" <> data_url) do
    [_metadata, encoded] = String.split(data_url, ";base64,", parts: 2)
    Base.decode64!(encoded)
  end

  defp marker_mime_type(%{"$intellectual_club_file" => marker}),
    do: marker["mime_type"]

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp oversized_png_payload do
    assert {:ok, image} = Image.new(3_000, 1_500)
    assert {:ok, payload} = Image.write(image, :memory, suffix: ".png")
    payload
  end

  defp jpeg_payload do
    assert {:ok, image} = Image.new(2, 1)
    assert {:ok, payload} = Image.write(image, :memory, suffix: ".jpg")
    payload
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
