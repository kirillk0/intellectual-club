defmodule IntellectualClub.Generation.LegacyRequestImagesTest do
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
  alias IntellectualClub.Generation.LegacyRequestImages
  alias IntellectualClub.Generation.RequestImages

  require Ash.Query

  test "migrates all provider shapes by file_id, preserves exact wire payload, and is idempotent" do
    fixture = request_fixture!(image_payload())
    raw_request = four_shape_legacy_request(fixture.file.external_id, fixture.payload, :file)
    step = persist_raw_request!(fixture.step, raw_request)
    file_count_before = count_files()

    assert {:ok, candidate} = LegacyRequestImages.migrate_step(step.id)
    assert candidate.status == :candidate
    assert candidate.occurrences == 4
    assert candidate.bindings == 1
    assert candidate.identity_bindings == 1
    assert candidate.thumbnail_bindings == 0
    assert candidate.missing_sources == 0
    assert candidate.legacy_json_bytes == byte_size(Jason.encode!(raw_request))
    assert candidate.compact_json_bytes > 0
    assert candidate.encoded_chars == 4 * byte_size(Base.encode64(fixture.payload))
    assert count_files() == file_count_before
    assert [] == bindings_for_step(step.id)
    assert Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request == raw_request

    assert {:ok, result} = LegacyRequestImages.migrate_step(step.id, dry_run?: false)
    assert result.status == :migrated
    assert result.occurrences == 4
    assert result.bindings == 1
    assert result.identity_bindings == 1
    assert result.thumbnail_bindings == 0
    assert result.missing_sources == 0
    assert count_files() == file_count_before + 1

    assert [binding] = bindings_for_step(step.id)
    assert binding.variant_key == "identity:v1"
    assert to_string(binding.reference_key) == to_string(fixture.file.external_id)
    assert to_string(binding.source_file_external_id) == to_string(fixture.file.external_id)
    assert binding.file.sha256 == fixture.file.sha256

    persisted_step = Ash.get!(ChatMessageStep, step.id, authorize?: false)
    encoded_compact = Jason.encode!(persisted_step.raw_request)
    refute encoded_compact =~ "data:image/png;base64,"
    refute encoded_compact =~ Base.encode64(fixture.payload)
    assert encoded_compact =~ "$intellectual_club_file"

    assert {:ok, hydrated_request} = RequestImages.hydrate(persisted_step.raw_request, step.id)
    assert hydrated_request == raw_request

    assert {:ok, %{status: :noop, step_id: step_id}} =
             LegacyRequestImages.migrate_step(step.id, dry_run?: false)

    assert step_id == step.id
    assert [same_binding] = bindings_for_step(step.id)
    assert same_binding.id == binding.id
    assert same_binding.file_id == binding.file_id
    assert count_files() == file_count_before + 1
  end

  test "resolves an old content_id attachment to its canonical file" do
    fixture = request_fixture!(image_payload())

    raw_request =
      responses_legacy_request(fixture.content.external_id, fixture.payload, :content)

    step = persist_raw_request!(fixture.step, raw_request)

    assert {:ok, result} = LegacyRequestImages.migrate_step(step.id, dry_run?: false)
    assert result.status == :migrated
    assert result.identity_bindings == 1
    assert result.missing_sources == 0

    assert [binding] = bindings_for_step(step.id)
    assert to_string(binding.reference_key) == to_string(fixture.file.external_id)
    assert to_string(binding.source_file_external_id) == to_string(fixture.file.external_id)

    compact_request = Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request
    assert {:ok, ^raw_request} = RequestImages.hydrate(compact_request, step.id)
  end

  test "recovers a non-oversized payload when its direct file_id source was deleted" do
    fixture = request_fixture!(image_payload())
    external_id = to_string(fixture.file.external_id)
    raw_request = responses_legacy_request(external_id, fixture.payload, :file)
    step = persist_raw_request!(fixture.step, raw_request)

    Ash.destroy!(fixture.content, actor: fixture.actor)
    assert {:error, _error} = Ash.get(StoredFile, fixture.file.id, authorize?: false)

    assert {:ok, result} = LegacyRequestImages.migrate_step(step.id, dry_run?: false)
    assert result.status == :migrated
    assert result.missing_sources == 1
    assert result.identity_bindings == 0
    assert result.thumbnail_bindings == 1

    assert [binding] = bindings_for_step(step.id)
    assert binding.variant_key == "thumbnail:max-edge=2000:preserve-format:v1"
    assert to_string(binding.reference_key) == external_id
    assert to_string(binding.source_file_external_id) == external_id
    assert {:ok, {_file, payload}} = Files.load_payload(binding.file_id)
    assert payload == fixture.payload

    compact_request = Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request
    assert {:ok, ^raw_request} = RequestImages.hydrate(compact_request, step.id)
  end

  test "ignores legacy-looking images in parameters, tool arguments, and opaque maps" do
    fixture = request_fixture!(image_payload())
    data_url = data_url(fixture.payload)
    encoded = Base.encode64(fixture.payload)

    raw_request = %{
      "parameters" => %{"type" => "input_image", "image_url" => data_url},
      "tools" => [
        %{
          "type" => "function",
          "parameters" => %{"type" => "image", "mime_type" => "image/png", "data" => encoded}
        }
      ],
      "input" => [
        %{
          "type" => "function_call",
          "arguments" => %{"type" => "input_image", "image_url" => data_url}
        },
        %{
          "type" => "function_result",
          "result" => %{"type" => "image", "mime_type" => "image/png", "data" => encoded}
        },
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "opaque",
              "content" => [%{"type" => "input_image", "image_url" => data_url}]
            }
          ]
        }
      ]
    }

    step = persist_raw_request!(fixture.step, raw_request)
    file_count_before = count_files()

    assert {:ok, %{status: :noop, step_id: step_id}} =
             LegacyRequestImages.migrate_step(step.id, dry_run?: false)

    assert step_id == step.id
    assert count_files() == file_count_before
    assert [] == bindings_for_step(step.id)
    assert Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request == raw_request
  end

  test "leaves the whole request untouched when any recognized image is invalid" do
    fixture = request_fixture!(image_payload())
    reference = attachment_text(:file, fixture.file.external_id)

    raw_request = %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            reference,
            %{"type" => "input_image", "image_url" => data_url(fixture.payload)},
            reference,
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => "not-valid-base64!"
              }
            }
          ]
        }
      ]
    }

    step = persist_raw_request!(fixture.step, raw_request)
    file_count_before = count_files()

    assert {:error, {:legacy_request_image_prepare_failed, step_id, :invalid_base64}} =
             LegacyRequestImages.migrate_step(step.id, dry_run?: false)

    assert step_id == step.id
    assert count_files() == file_count_before
    assert [] == bindings_for_step(step.id)
    assert Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request == raw_request
  end

  test "leaves the whole request untouched when a recognized image has no source" do
    fixture = request_fixture!(image_payload())
    missing_payload = jpeg_payload()

    raw_request = %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            attachment_text(:file, fixture.file.external_id),
            %{"type" => "input_image", "image_url" => data_url(fixture.payload)},
            %{"type" => "input_image", "image_url" => data_url(missing_payload, "image/jpeg")}
          ]
        }
      ]
    }

    step = persist_raw_request!(fixture.step, raw_request)
    file_count_before = count_files()

    assert {:error,
            {:legacy_request_image_prepare_failed, step_id,
             {:legacy_image_source_not_resolved, _sha256, :not_found}}} =
             LegacyRequestImages.migrate_step(step.id, dry_run?: false)

    assert step_id == step.id
    assert count_files() == file_count_before
    assert [] == bindings_for_step(step.id)
    assert Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request == raw_request
  end

  test "skips an active step without inspecting or changing its legacy request" do
    fixture = request_fixture!(image_payload())
    raw_request = responses_legacy_request(fixture.file.external_id, fixture.payload, :file)

    step =
      fixture.step
      |> Ash.Changeset.for_update(
        :update,
        %{raw_request: raw_request, status: :waiting_provider},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

    file_count_before = count_files()

    assert {:ok, %{status: :active, step_id: step_id}} =
             LegacyRequestImages.migrate_step(step.id, dry_run?: false)

    assert step_id == step.id
    assert count_files() == file_count_before
    assert [] == bindings_for_step(step.id)
    assert Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request == raw_request
  end

  test "preserves an oversized legacy source exactly through materialization and hydration" do
    fixture = request_fixture!(oversized_png_payload())
    raw_request = responses_legacy_request(fixture.file.external_id, fixture.payload, :file)
    step = persist_raw_request!(fixture.step, raw_request)

    assert {:ok, result} = LegacyRequestImages.migrate_step(step.id, dry_run?: false)
    assert result.status == :migrated
    assert result.identity_bindings == 0
    assert result.thumbnail_bindings == 0
    assert result.legacy_exact_bindings == 1
    assert result.wire_changed_oversized == 0

    assert [binding] = bindings_for_step(step.id)
    assert binding.variant_key == "legacy_exact:v1"
    assert {:ok, {_file, exact_payload}} = Files.load_payload(binding.file_id)
    assert exact_payload == fixture.payload
    assert {"image/png", 3_000, 1_500, _variant} = ExImageInfo.info(exact_payload)

    assert {:ok, {_file, original_payload}} = Files.load_payload(fixture.file.id)
    assert original_payload == fixture.payload
    assert {"image/png", 3_000, 1_500, _variant} = ExImageInfo.info(original_payload)

    compact_request = Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request
    [compact_image] = image_blocks(compact_request)

    assert %{
             "$intellectual_club_file" => %{
               "rendition" => %{
                 "kind" => "legacy_exact",
                 "format" => "preserve"
               }
             }
           } = compact_image["image_url"]

    assert {:ok, ^compact_request} =
             RequestImages.materialize_and_persist(compact_request, step.id)

    assert {:ok, ^raw_request} = RequestImages.hydrate(compact_request, step.id)
  end

  test "preserves an oversized legacy payload after its direct source was deleted" do
    fixture = request_fixture!(oversized_png_payload())
    external_id = to_string(fixture.file.external_id)
    raw_request = responses_legacy_request(external_id, fixture.payload, :file)
    step = persist_raw_request!(fixture.step, raw_request)

    Ash.destroy!(fixture.content, actor: fixture.actor)
    assert {:error, _error} = Ash.get(StoredFile, fixture.file.id, authorize?: false)

    assert {:ok, result} = LegacyRequestImages.migrate_step(step.id, dry_run?: false)
    assert result.status == :migrated
    assert result.missing_sources == 1
    assert result.legacy_exact_bindings == 1
    assert result.wire_changed_oversized == 0

    assert [binding] = bindings_for_step(step.id)
    assert binding.variant_key == "legacy_exact:v1"
    assert {:ok, {_file, exact_payload}} = Files.load_payload(binding.file_id)
    assert exact_payload == fixture.payload

    compact_request = Ash.get!(ChatMessageStep, step.id, authorize?: false).raw_request
    assert {:ok, ^raw_request} = RequestImages.hydrate(compact_request, step.id)
  end

  test "cleanup removes only unbound backfill files" do
    fixture = request_fixture!(image_payload())
    raw_request = responses_legacy_request(fixture.file.external_id, fixture.payload, :file)
    step = persist_raw_request!(fixture.step, raw_request)

    assert {:ok, %{status: :migrated}} =
             LegacyRequestImages.migrate_step(step.id, dry_run?: false)

    [binding] = bindings_for_step(step.id)

    orphan_filename =
      LegacyRequestImages.staged_filename_prefix() <> "orphan.png"

    assert {:ok, orphan} =
             Files.create_from_binary(orphan_filename, "image/png", jpeg_payload())

    assert {:ok, 1} = LegacyRequestImages.cleanup_unbound_staged_files()
    assert {:error, _error} = Ash.get(StoredFile, orphan.id, authorize?: false)
    assert Ash.get!(StoredFile, binding.file_id, authorize?: false).id == binding.file_id
  end

  defp request_fixture!(payload) do
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

    {:ok, file} = Files.create_from_binary("source.png", "image/png", payload)

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
    step = create_step!(target_message.id, 1, actor)

    %{
      actor: actor,
      content: content,
      file: file,
      payload: payload,
      step: step
    }
  end

  defp create_message!(chat_id, role, actor, parent_id \\ nil) do
    ChatMessage
    |> Ash.Changeset.for_create(
      :add_message,
      %{
        chat_id: chat_id,
        role: role,
        parent_id: parent_id,
        status: :done,
        token_count: 0
      },
      actor: actor
    )
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

  defp persist_raw_request!(step, raw_request) do
    step
    |> Ash.Changeset.for_update(:update, %{raw_request: raw_request}, authorize?: false)
    |> Ash.update!(authorize?: false)
  end

  defp four_shape_legacy_request(external_id, payload, reference_kind) do
    encoded = Base.encode64(payload)
    data_url = data_url(payload)
    reference = attachment_text(reference_kind, external_id)

    %{
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            reference,
            %{"type" => "input_image", "image_url" => data_url},
            reference,
            %{"type" => "image_url", "image_url" => %{"url" => data_url}},
            reference,
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => "image/png",
                "data" => encoded
              }
            },
            reference,
            %{"type" => "image", "mime_type" => "image/png", "data" => encoded}
          ]
        }
      ]
    }
  end

  defp responses_legacy_request(external_id, payload, reference_kind) do
    %{
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            attachment_text(reference_kind, external_id),
            %{"type" => "input_image", "image_url" => data_url(payload)}
          ]
        }
      ]
    }
  end

  defp attachment_text(kind, external_id) when kind in [:file, :content] do
    %{
      "type" => "input_text",
      "text" => "[Attached file #{kind}_id=#{external_id}]"
    }
  end

  defp image_blocks(request) do
    request
    |> Map.get("messages", Map.get(request, "input"))
    |> List.first()
    |> Map.fetch!("content")
    |> Enum.filter(fn block -> block["type"] in ["input_image", "image_url", "image"] end)
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

  defp data_url(payload, mime_type \\ "image/png") do
    "data:#{mime_type};base64,#{Base.encode64(payload)}"
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp jpeg_payload do
    assert {:ok, image} = Image.new(2, 1)
    assert {:ok, payload} = Image.write(image, :memory, suffix: ".jpg")
    payload
  end

  defp oversized_png_payload do
    assert {:ok, image} = Image.new(3_000, 1_500)
    assert {:ok, payload} = Image.write(image, :memory, suffix: ".png")
    payload
  end
end
