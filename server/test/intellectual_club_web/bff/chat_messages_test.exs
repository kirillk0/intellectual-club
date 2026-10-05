defmodule IntellectualClubWeb.Bff.ChatMessagesTest do
  @moduledoc """
  Chat message BFF endpoints: editing, retries and steering.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Llm.Providers.Responses.HistoryInput

  describe "PATCH /api/bff/chat-messages/:id" do
    test "updates single answer content via legacy content field",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, "Old answer",
          actor: actor,
          parent_id: user_message.id
        )

      before_update =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:finished_at, items: [:contents]]]
        )

      before_finished_at = before_update.finished_at
      [before_step] = Enum.sort_by(before_update.steps || [], & &1.sequence)

      answer_item = Enum.find(before_step.items || [], &(&1.type == :answer))

      _legacy_opaque =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: answer_item.id,
            sequence: 10_000,
            kind: :opaque,
            content_json: %{
              "id" => "msg_legacy",
              "type" => "message",
              "role" => "assistant",
              "status" => "completed",
              "phase" => "commentary",
              "content" => [
                %{
                  "type" => "output_text",
                  "text" => "Old answer",
                  "annotations" => []
                }
              ]
            }
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn =
        patch(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}", %{
          "content" => "New answer"
        })

      payload = json_response(conn, 200)
      assistant_payload = find_message(payload["branch"] || [], assistant_message.id)

      assert answer_text_contents(assistant_payload) == ["New answer"]

      after_update =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [:finished_at, items: [:contents]]]
        )

      [after_step] = Enum.sort_by(after_update.steps || [], & &1.sequence)

      assert after_update.finished_at == before_finished_at
      assert after_step.finished_at == before_step.finished_at

      updated_answer_item = Enum.find(after_step.items || [], &(&1.type == :answer))
      legacy_opaque = Enum.find(updated_answer_item.contents || [], &(&1.kind == :opaque))

      assert get_in(legacy_opaque.content_json, ["content", Access.at(0), "text"]) == "Old answer"

      assert [projected_answer] = HistoryInput.build_input_items([after_update])
      assert projected_answer["phase"] == "final_answer"

      assert get_in(projected_answer, ["content", Access.at(0), "text"]) == "New answer"
      refute Map.has_key?(projected_answer, "id")
    end

    test "updates multiple answer contents via contents payload",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, "First", actor: actor, parent_id: user_message.id)

      loaded =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      step = loaded.steps |> List.first()
      item = step.items |> List.first()
      content_1 = item.contents |> List.first()

      content_2 =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: item.id,
            sequence: 2,
            kind: :text,
            content_text: "Second"
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn =
        patch(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}", %{
          "contents" => [
            %{"id" => content_1.id, "content_text" => "Alpha"},
            %{"id" => content_2.id, "content_text" => "Beta"}
          ]
        })

      payload = json_response(conn, 200)
      assistant_payload = find_message(payload["branch"] || [], assistant_message.id)

      assert answer_text_contents(assistant_payload) == ["Alpha", "Beta"]
    end

    test "rejects legacy content payload when multiple contents exist",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, "First", actor: actor, parent_id: user_message.id)

      loaded =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      step = loaded.steps |> List.first()
      item = step.items |> List.first()

      _content_2 =
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: item.id,
            sequence: 2,
            kind: :text,
            content_text: "Second"
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn =
        patch(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}", %{
          "content" => "New answer"
        })

      payload = json_response(conn, 422)
      assert is_binary(payload["error"])
      assert String.contains?(payload["error"], "multiple")
    end

    test "can remove and upload user attachments", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      bot = create_artifact_bot!(actor, "Editable files bot")

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, message} =
        Threads.add_message_to_end(chat, :user, "",
          actor: actor,
          contents: [
            %{kind: :text, content_text: "Question with file"},
            %{
              kind: :media,
              file_id:
                create_file!(
                  filename: "old.txt",
                  mime_type: "text/plain",
                  payload: "old attachment"
                ).id
            }
          ]
        )

      loaded =
        Ash.get!(ChatMessage, message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      input_item =
        loaded.steps
        |> List.first()
        |> Map.get(:items)
        |> Enum.find(&(&1.type == :input))

      old_media_content =
        input_item.contents
        |> Enum.find(&(&1.kind == :media))

      upload = temp_upload("new.md", "text/markdown", "# new attachment")

      conn =
        patch(conn, ~p"/api/bff/chat-messages/#{message.id}", %{
          "remove_content_ids" => [old_media_content.id],
          "files" => [upload]
        })

      payload = json_response(conn, 200)
      message_payload = find_message(payload["branch"] || [], message.id)
      media_contents = media_contents(message_payload, "input")

      assert length(media_contents) == 1
      [media_content] = media_contents
      assert get_in(media_content, ["media", "filename"]) == "new.md"
      assert get_in(media_content, ["media", "mime_type"]) == "text/markdown"

      assert {:error, _reason} = Files.load_payload(old_media_content.file_id)
    end

    test "accepts upload_ids for user attachments", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      bot = create_artifact_bot!(actor, "Chunk editable bot")

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, message} =
        Threads.add_message_to_end(chat, :user, "",
          actor: actor,
          contents: [
            %{kind: :text, content_text: "Question with upload id"},
            %{
              kind: :media,
              file_id:
                create_file!(
                  filename: "old.txt",
                  mime_type: "text/plain",
                  payload: "old attachment"
                ).id
            }
          ]
        )

      loaded =
        Ash.get!(ChatMessage, message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      input_item =
        loaded.steps
        |> List.first()
        |> Map.get(:items)
        |> Enum.find(&(&1.type == :input))

      old_media_content =
        input_item.contents
        |> Enum.find(&(&1.kind == :media))

      upload =
        upload_text_attachment!(
          conn,
          actor.username,
          password,
          chat.id,
          "new-upload.txt",
          "new attachment by upload id"
        )

      conn =
        patch(conn, ~p"/api/bff/chat-messages/#{message.id}", %{
          "remove_content_ids" => [old_media_content.id],
          "upload_ids" => [upload["upload_id"]]
        })

      payload = json_response(conn, 200)
      message_payload = find_message(payload["branch"] || [], message.id)
      media_contents = media_contents(message_payload, "input")

      assert length(media_contents) == 1
      [media_content] = media_contents
      assert get_in(media_content, ["media", "filename"]) == "new-upload.txt"
      assert get_in(media_content, ["media", "mime_type"]) == "text/plain"

      assert {:error, _reason} = Files.load_payload(old_media_content.file_id)

      conn = get(conn, ~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}")
      assert json_response(conn, 404)["error"] == "Upload not found."
    end

    test "stores assistant attachments in artifact item", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      bot = create_artifact_bot!(actor, "Assistant files bot")

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", bot_id: bot.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, "Answer", actor: actor, parent_id: user_message.id)

      upload = temp_upload("diagram.png", "image/png", png_1x1())

      conn =
        patch(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}", %{
          "files" => [upload]
        })

      payload = json_response(conn, 200)
      assistant_payload = find_message(payload["branch"] || [], assistant_message.id)

      assert answer_text_contents(assistant_payload) == ["Answer"]

      artifact_media =
        media_contents(assistant_payload, "artifact")

      assert length(artifact_media) == 1
      [artifact] = artifact_media
      assert get_in(artifact, ["media", "filename"]) == "diagram.png"

      loaded =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      artifact_item =
        loaded.steps
        |> Enum.flat_map(&(&1.items || []))
        |> Enum.find(&(&1.type == :artifact))

      assert %ChatMessageItem{} = artifact_item
      assert Enum.any?(artifact_item.contents || [], &(&1.kind == :media))
    end

    test "rejects new attachments when uploads are disabled", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: ""},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)
      upload = temp_upload("new.md", "text/markdown", "# new attachment")

      conn =
        patch(conn, ~p"/api/bff/chat-messages/#{message.id}", %{
          "files" => [upload]
        })

      payload = json_response(conn, 422)

      assert payload["error"] ==
               "File uploads are disabled for the current bot and configuration."
    end
  end

  describe "retry-last-step and retry-from-step" do
    test "POST /api/bff/chat-messages/:id/retry-last-step retries assistant message in error state",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)

      {assistant_message, old_step} =
        create_retryable_assistant_message!(chat, actor, :error, "hello")

      conn = post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/retry-last-step", %{})
      payload = json_response(conn, 200)

      assert get_in(payload, ["generation", "message_id"]) == assistant_message.id
      assert {:error, _error} = Ash.get(ChatMessageStep, old_step.id, actor: actor)

      retried = find_message(payload["branch"] || [], assistant_message.id)
      assert retried["status"] in ["generating", "done"]

      wait_for_generation_to_finish(conn, assistant_message.id)
    end

    test "POST /api/bff/chat-messages/:id/retry-last-step rejects done messages", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)

      {assistant_message, _old_step} =
        create_retryable_assistant_message!(chat, actor, :done, "hello")

      conn = post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/retry-last-step", %{})
      payload = json_response(conn, 422)

      assert is_binary(payload["error"])
      assert String.contains?(payload["error"], "error or canceled")
    end

    test "POST /api/bff/chat-messages/:message_id/steps/:step_id/retry-from-step retries a done message from an earlier step",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)

      {assistant_message, [step_1, step_2, step_3]} =
        create_retryable_assistant_message_with_steps!(chat, actor, :done, "hello", 3)

      conn =
        post(
          conn,
          ~p"/api/bff/chat-messages/#{assistant_message.id}/steps/#{step_2.id}/retry-from-step",
          %{}
        )

      payload = json_response(conn, 200)

      assert get_in(payload, ["generation", "message_id"]) == assistant_message.id
      assert {:ok, _step} = Ash.get(ChatMessageStep, step_1.id, actor: actor)
      assert {:error, _error} = Ash.get(ChatMessageStep, step_2.id, actor: actor)
      assert {:error, _error} = Ash.get(ChatMessageStep, step_3.id, actor: actor)

      retried = find_message(payload["branch"] || [], assistant_message.id)
      assert retried["status"] in ["generating", "done"]

      wait_for_generation_to_finish(conn, assistant_message.id)

      message =
        Ash.get!(ChatMessage, assistant_message.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      [preserved_step, retried_step] = Enum.sort_by(message.steps || [], & &1.sequence)

      assert preserved_step.id == step_1.id
      assert retried_step.sequence == 2
      assert retried_step.id != step_2.id
    end

    test "POST /api/bff/chat-messages/:message_id/steps/:step_id/retry-from-step rejects generating messages",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)

      {assistant_message, [step]} =
        create_retryable_assistant_message_with_steps!(chat, actor, :generating, "hello", 1)

      conn =
        post(
          conn,
          ~p"/api/bff/chat-messages/#{assistant_message.id}/steps/#{step.id}/retry-from-step",
          %{}
        )

      payload = json_response(conn, 422)

      assert payload["error"] == "Retry from this step is available after generation stops."
      assert {:ok, _step} = Ash.get(ChatMessageStep, step.id, actor: actor)

      message = Ash.get!(ChatMessage, assistant_message.id, actor: actor)
      assert message.status == :generating
    end

    test "POST /api/bff/chat-messages/:message_id/steps/:step_id/retry-from-step returns 404 for a step from another message",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)

      {assistant_message, [_step_1, _step_2]} =
        create_retryable_assistant_message_with_steps!(chat, actor, :done, "hello", 2)

      {_other_message, [other_step]} =
        create_retryable_assistant_message_with_steps!(chat, actor, :done, "another", 1)

      conn =
        post(
          conn,
          ~p"/api/bff/chat-messages/#{assistant_message.id}/steps/#{other_step.id}/retry-from-step",
          %{}
        )

      payload = json_response(conn, 404)
      assert payload["error"] == "Step not found"
    end
  end

  describe "POST /api/bff/chat-messages/:id/steer" do
    test "steer validates content and converts a late request to follow-up", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, "Answer",
          actor: actor,
          parent_id: user_message.id
        )

      empty_conn =
        post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{"content" => ""})

      assert %{"code" => "empty_steering"} = json_response(empty_conn, 422)

      inactive_conn =
        post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{
          "content" => "Change direction"
        })

      queued_message = json_response(inactive_conn, 201)["queued_message"]
      assert queued_message["kind"] == "follow_up"
      assert queued_message["anchor_message_id"] == assistant_message.id
    end

    test "steer persists outside the canonical trace until generation consumes it", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      configuration =
        create_configuration!(actor,
          provider_attrs: %{name: "Steering provider", type: :openrouter_chat_completion},
          model_name: "steering-model",
          note: "",
          timeout_seconds: 300,
          context_length: nil
        )

      chat =
        Chat
        |> Ash.Changeset.for_create(
          :create,
          %{note: "", llm_configuration_id: configuration.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      assistant_message =
        ChatMessage
        |> Ash.Changeset.for_create(
          :create_generating_assistant,
          %{
            chat_id: chat.id,
            parent_id: user_message.id,
            llm_configuration_id: configuration.id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

      conn =
        post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/steer", %{
          "content" => "Change direction"
        })

      queued_message = json_response(conn, 201)["queued_message"]
      assert queued_message["kind"] == "steer"
      assert queued_message["status"] == "pending"
      assert queued_message["target_generation_message_id"] == assistant_message.id

      assert [%{"kind" => "text", "content_text" => "Change direction"}] =
               queued_message["contents"]

      assert {:ok, [persisted]} =
               QueuedMessages.list_pending_steers(assistant_message.id, actor)

      assert persisted.id == queued_message["id"]

      reloaded =
        Ash.get!(ChatMessage, assistant_message.id, actor: actor, load: [steps: [:items]])

      assert reloaded.steps == []
    end
  end

  defp find_message(branch, message_id) do
    Enum.find(branch, fn message -> message["id"] == message_id end) || %{}
  end

  defp answer_text_contents(message_payload) do
    message_payload
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.sort_by(fn content -> Map.get(content, "sequence") || 0 end)
    |> Enum.map(fn content -> Map.get(content, "text") || "" end)
  end

  defp media_contents(message_payload, _item_type) do
    message_payload
    |> get_in(["content", "media"])
    |> List.wrap()
    |> Enum.filter(fn content -> Map.get(content, "kind") == "media" end)
    |> Enum.sort_by(fn content -> Map.get(content, "sequence") || 0 end)
  end

  defp temp_upload(filename, content_type, payload) do
    path =
      Path.join(
        System.tmp_dir!(),
        "chat-update-#{System.unique_integer([:positive])}-#{filename}"
      )

    File.write!(path, payload)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp upload_text_attachment!(conn, username, password, chat_id, filename, payload) do
    size = byte_size(payload)

    upload =
      conn
      |> post(~p"/api/bff/chat-uploads/#{chat_id}", %{
        "filename" => filename,
        "mime_type" => "text/plain",
        "size_bytes" => size
      })
      |> json_response(200)
      |> Map.fetch!("upload")

    build_conn()
    |> sign_in_conn(username, password)
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("x-upload-offset", "0")
    |> put(~p"/api/bff/chat-uploads/#{chat_id}/#{upload["upload_id"]}/chunk", payload)
    |> json_response(200)

    upload
  end

  defp create_retryable_assistant_message!(chat, actor, status, prompt) do
    {assistant_message, [old_step]} =
      create_retryable_assistant_message_with_steps!(chat, actor, status, prompt, 1)

    {assistant_message, old_step}
  end

  defp create_retryable_assistant_message_with_steps!(chat, actor, status, prompt, step_count)
       when is_integer(step_count) and step_count > 0 do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, prompt, actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :assistant,
          parent_id: user_message.id,
          status: status,
          error_detail: if(status == :error, do: "boom", else: nil),
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    steps =
      Enum.map(1..step_count, fn sequence ->
        ChatMessageStep
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_id: assistant_message.id,
            sequence: sequence,
            status: retryable_step_status(status),
            raw_request: %{
              "model" => "demo-model",
              "messages" => [
                %{"role" => "user", "content" => "#{prompt} step #{sequence}"}
              ],
              "stream" => true
            },
            raw_response: %{},
            response_final: status == :done and sequence == step_count
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)
      end)

    {assistant_message, steps}
  end

  defp retryable_step_status(:generating), do: :waiting_provider

  defp retryable_step_status(status), do: status
end
