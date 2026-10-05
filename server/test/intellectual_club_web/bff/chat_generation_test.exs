defmodule IntellectualClubWeb.Bff.ChatGenerationTest do
  @moduledoc """
  Chat generation BFF endpoints: send, generate and branch-to-new-chat.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Files.UploadStaging
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  describe "POST /api/bff/chat-generation/:id/send" do
    test "treats whitespace-only content as user message",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)
      whitespace = "   "

      conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{"content" => whitespace})
      payload = json_response(conn, 200)

      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      user_messages = Enum.filter(branch, &(&1["role"] == "user"))

      assert length(user_messages) == 1

      [user_message] = user_messages
      assert all_text_contents(user_message) == [whitespace]

      generated = Enum.find(branch, &(&1["id"] == generation_id))
      assert is_map(generated)
      assert generated["parent_id"] == user_message["id"]

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "rejects an empty user payload",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)

      conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{"content" => ""})
      payload = json_response(conn, 422)

      assert payload["error"] =~ "must contain text or an attachment"

      chat = Ash.get!(Chat, chat.id, actor: actor, load: [:last_message])
      assert chat.last_message == nil
    end

    test "with file-only multipart creates user media content",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot = create_artifact_bot!(actor, "File bot")
      chat = create_chat!(actor, bot_id: bot.id)
      upload = temp_upload("attached.png", "image/png", png_1x1())

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "",
          "files" => [upload]
        })

      payload = json_response(conn, 200)
      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      user_messages = Enum.filter(branch, &(&1["role"] == "user"))
      assert length(user_messages) == 1

      [user_message] = user_messages

      media_contents = media_contents(user_message)

      assert length(media_contents) == 1
      [media_content] = media_contents
      assert is_binary(get_in(media_content, ["media", "external_id"]))
      assert get_in(media_content, ["media", "filename"]) == "attached.png"
      assert get_in(media_content, ["media", "mime_type"]) == "image/png"

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "with upload_ids creates user media content and consumes uploads",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot = create_artifact_bot!(actor, "Chunk send bot")
      chat = create_chat!(actor, bot_id: bot.id)

      upload =
        upload_text_attachment!(
          conn,
          actor.username,
          password,
          chat.id,
          "attached.txt",
          "chunk upload"
        )

      upload_path = UploadStaging.chat_upload_path(upload["upload_id"])
      assert File.exists?(upload_path)

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "",
          "upload_ids" => [upload["upload_id"]]
        })

      payload = json_response(conn, 200)
      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      user_messages = Enum.filter(branch, &(&1["role"] == "user"))

      assert length(user_messages) == 1
      [user_message] = user_messages

      media_contents = media_contents(user_message)

      assert length(media_contents) == 1
      [media_content] = media_contents
      assert get_in(media_content, ["media", "filename"]) == "attached.txt"
      assert get_in(media_content, ["media", "mime_type"]) == "text/plain"

      conn = get(conn, ~p"/api/bff/chat-uploads/#{chat.id}/#{upload["upload_id"]}")
      assert json_response(conn, 404)["error"] == "Upload not found."
      refute File.exists?(upload_path)

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "rejects files when bot and configuration do not allow uploads",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)
      upload = temp_upload("attached.txt", "text/plain", "hello")

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "",
          "files" => [upload]
        })

      payload = json_response(conn, 422)

      assert payload["error"] ==
               "File uploads are disabled for the current bot and configuration."
    end

    test "allows files when chat has an artifact tool", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)

      tool =
        create_tool_instance!(actor,
          type: "native-artifact-reader",
          name: "Chat Artifact Reader",
          alias: "chat_artifacts"
        )

      create_chat_tool_binding!(actor, chat, tool)
      upload = temp_upload("attached.txt", "text/plain", "hello from chat tool")

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "",
          "files" => [upload]
        })

      payload = json_response(conn, 200)
      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      user_messages = Enum.filter(branch, &(&1["role"] == "user"))
      assert length(user_messages) == 1

      [user_message] = user_messages
      [media_content] = media_contents(user_message)
      assert get_in(media_content, ["media", "filename"]) == "attached.txt"
      assert get_in(media_content, ["media", "mime_type"]) == "text/plain"

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "allows images when configuration supports image input",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      # A local OpenRouter-compatible server rejects the request, so the generation
      # ends without network access after the image reached the provider.
      {base_url, server} =
        start_scripted_server!(
          %{
            "/chat/completions" => [
              {401, %{"error" => %{"message" => "No auth credentials found", "code" => 401}}}
            ]
          },
          response: :json
        )

      configuration =
        create_configuration!(actor,
          supports_image_input: true,
          provider_attrs: %{type: :openrouter_chat_completion, base_url: base_url}
        )

      chat = create_chat!(actor, llm_configuration_id: configuration.id)
      upload = temp_upload("attached.png", "image/png", png_1x1())

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "",
          "files" => [upload]
        })

      payload = json_response(conn, 200)
      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      user_messages = Enum.filter(branch, &(&1["role"] == "user"))
      assert length(user_messages) == 1

      assert wait_for_generation_to_finish(conn, generation_id)["status"] == "error"

      assert [%{"messages" => messages}] = scripted_requests(server, "/chat/completions")

      assert Enum.any?(messages, fn message ->
               is_list(message["content"]) and
                 Enum.any?(message["content"], &(&1["type"] == "image_url"))
             end)
    end

    test "rejects files above the bot size limit", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot =
        create_artifact_bot!(actor, "Small limit bot", max_file_size_bytes: 4)

      chat = create_chat!(actor, bot_id: bot.id)
      upload = temp_upload("attached.txt", "text/plain", "hello")

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "",
          "files" => [upload]
        })

      payload = json_response(conn, 422)

      assert payload["error"] == ~s(File "attached.txt" exceeds the maximum size of 4 B.)
    end

    test "without parent_id appends follow-up to active branch leaf",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)
      {:ok, root} = Threads.add_message(chat, :user, "Root", actor: actor, parent_id: nil)

      {:ok, assistant} =
        Threads.add_message(chat, :assistant, "Answer", actor: actor, parent_id: root.id)

      conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{"content" => "Follow-up"})
      payload = json_response(conn, 200)

      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []

      follow_up =
        Enum.find(branch, &(&1["role"] == "user" and all_text_contents(&1) == ["Follow-up"]))

      assert is_map(follow_up)
      assert follow_up["parent_id"] == assistant.id

      generated = Enum.find(branch, &(&1["id"] == generation_id))
      assert is_map(generated)
      assert generated["parent_id"] == follow_up["id"]

      assert Enum.map(branch, & &1["id"]) == [
               root.id,
               assistant.id,
               follow_up["id"],
               generation_id
             ]

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "can copy existing attachments without reupload",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot = create_artifact_bot!(actor, "Copy bot")
      chat = create_chat!(actor, bot_id: bot.id)

      original_file =
        create_file!(filename: "spec.txt", mime_type: "text/plain", payload: "copied attachment")

      {:ok, root} =
        Threads.add_message_to_end(chat, :user, "",
          actor: actor,
          contents: [
            %{kind: :text, content_text: "Original"},
            %{kind: :media, file_id: original_file.id}
          ]
        )

      loaded_root =
        Ash.get!(IntellectualClub.Chat.ChatMessage, root.id,
          actor: actor,
          load: [steps: [items: [:contents]]]
        )

      copied_content_id =
        loaded_root.steps
        |> Enum.flat_map(&(&1.items || []))
        |> Enum.flat_map(&(&1.contents || []))
        |> Enum.find_value(fn content ->
          if content.kind == :media, do: content.id, else: nil
        end)

      {:ok, assistant} =
        Threads.add_message(chat, :assistant, "Answer", actor: actor, parent_id: root.id)

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "",
          "parent_id" => assistant.id,
          "copy_content_ids" => [copied_content_id]
        })

      payload = json_response(conn, 200)
      generation_id = get_in(payload, ["generation", "message_id"])
      branch = payload["branch"] || []

      copied_user_message =
        Enum.find(branch, fn message ->
          message["role"] == "user" and message["parent_id"] == assistant.id
        end)

      assert is_map(copied_user_message)

      copied_media = media_contents(copied_user_message)

      assert length(copied_media) == 1
      [content] = copied_media
      assert get_in(content, ["media", "filename"]) == "spec.txt"
      assert get_in(content, ["media", "mime_type"]) == "text/plain"

      generated = Enum.find(branch, &(&1["id"] == generation_id))
      assert is_map(generated)
      assert generated["parent_id"] == copied_user_message["id"]

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "with explicit null parent_id branches from root level",
         %{
           conn: conn
         } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      chat = create_chat!(actor)
      {:ok, root} = Threads.add_message(chat, :user, "Root", actor: actor, parent_id: nil)

      {:ok, assistant} =
        Threads.add_message(chat, :assistant, "Answer", actor: actor, parent_id: root.id)

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{chat.id}/send", %{
          "content" => "Alternative root",
          "parent_id" => nil
        })

      payload = json_response(conn, 200)

      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []

      alternative_root =
        Enum.find(
          branch,
          &(&1["role"] == "user" and all_text_contents(&1) == ["Alternative root"])
        )

      assert is_map(alternative_root)
      assert alternative_root["parent_id"] == nil

      generated = Enum.find(branch, &(&1["id"] == generation_id))
      assert is_map(generated)
      assert generated["parent_id"] == alternative_root["id"]
      assert Enum.map(branch, & &1["id"]) == [alternative_root["id"], generation_id]

      refute Enum.any?(branch, &(&1["id"] == root.id))
      refute Enum.any?(branch, &(&1["id"] == assistant.id))

      wait_for_generation_to_finish(conn, generation_id)
    end
  end

  describe "POST /api/bff/chat-generation/:id/generate" do
    test "keeps deleted-reply parent by default", %{
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

      {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      {:ok, assistant_message} =
        Threads.add_message(chat, :assistant, "First answer",
          actor: actor,
          parent_id: user_message.id
        )

      conn = post(conn, ~p"/api/bff/chat-messages/#{assistant_message.id}/delete")
      delete_payload = json_response(conn, 200)

      assert Enum.map(delete_payload["branch"] || [], & &1["id"]) == [user_message.id]

      conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/generate", %{})
      payload = json_response(conn, 200)

      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      generated = Enum.find(branch, &(&1["id"] == generation_id))

      assert is_map(generated)
      assert generated["parent_id"] == user_message.id
      assert Enum.map(branch, & &1["id"]) == [user_message.id, generation_id]

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "with explicit null parent creates root assistant branch",
         %{conn: conn} do
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

      {:ok, root_assistant} =
        Threads.add_message(chat, :assistant, "First root answer",
          actor: actor,
          parent_id: nil
        )

      conn = post(conn, ~p"/api/bff/chat-generation/#{chat.id}/generate", %{"parent_id" => nil})
      payload = json_response(conn, 200)

      generation_id = get_in(payload, ["generation", "message_id"])
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      generated = Enum.find(branch, &(&1["id"] == generation_id))

      assert is_map(generated)
      assert generated["parent_id"] == nil
      assert Enum.map(branch, & &1["id"]) == [generation_id]
      refute Enum.any?(branch, &(&1["id"] == root_assistant.id))

      wait_for_generation_to_finish(conn, generation_id)
    end
  end

  describe "POST /api/bff/chat-generation/:id/branch-to-new-chat" do
    test "branches from assistant as alternative answer",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot = create_bot!(actor, name: "Assistant branch bot")
      configuration = create_demo_configuration!(actor)

      source =
        create_empty_chat!(actor,
          note: "source note",
          bot_id: bot.id,
          llm_configuration_id: configuration.id
        )

      {:ok, root} = Threads.add_message_to_end(source, :user, "Root prompt", actor: actor)

      {:ok, selected_assistant} =
        Threads.add_message_to_end(source, :assistant, "Selected answer", actor: actor)

      {:ok, inactive_assistant} =
        Threads.add_message(source, :assistant, "Inactive answer",
          actor: actor,
          parent_id: root.id
        )

      {:ok, _meta} = Threads.activate_branch(source.id, selected_assistant.id, actor)

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{source.id}/branch-to-new-chat", %{
          "message_id" => selected_assistant.id
        })

      payload = json_response(conn, 200)
      target_id = get_in(payload, ["chat", "id"])
      generation_id = get_in(payload, ["generation", "message_id"])

      assert is_integer(target_id)
      assert is_integer(generation_id)
      assert target_id != source.id

      refute Map.has_key?(payload["chat"], "title")
      assert get_in(payload, ["chat", "note"]) == "source note (branch)"
      assert get_in(payload, ["chat", "bot_id"]) == bot.id
      assert get_in(payload, ["chat", "llm_configuration_id"]) == configuration.id

      target = Ash.get!(Chat, target_id, actor: actor)
      assert target.parent_chat_id == nil
      assert target.parent_message_id == nil
      assert target.parent_relation_kind == nil

      branch = payload["branch"] || []
      assert Enum.map(branch, & &1["role"]) == ["user", "assistant"]
      assert Enum.map(branch, & &1["id"]) == [List.first(branch)["id"], generation_id]
      assert Enum.at(branch, 1)["parent_id"] == List.first(branch)["id"]

      target_messages = messages_for_chat!(actor, target_id)
      target_text = Enum.map(target_messages, &message_text/1)

      assert "Root prompt" in target_text
      refute "Selected answer" in target_text
      refute "Inactive answer" in target_text
      refute Enum.any?(target_messages, &(&1.id == inactive_assistant.id))

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "branches from user with settings and attachments",
         %{conn: conn} do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)

      bot = create_artifact_bot!(actor, "User branch bot", max_file_size_bytes: 500 * 1024 * 1024)
      source = create_empty_chat!(actor, bot_id: bot.id)
      block = create_knowledge_block!(actor, name: "Branch block", content: "Knowledge")
      tool = create_tool_instance!(actor, type: "native-agent-management")

      _block_binding =
        create_chat_block_binding!(actor, source, block, enabled: false, sequence: 7)

      _tool_binding = create_chat_tool_binding!(actor, source, tool, sequence: 3)

      {:ok, _root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)
      {:ok, assistant} = Threads.add_message_to_end(source, :assistant, "Answer", actor: actor)
      {:ok, copied_file} = Files.create_from_binary("copied.txt", "text/plain", "copied payload")

      {:ok, selected_user} =
        Threads.add_message(source, :user, "",
          actor: actor,
          parent_id: assistant.id,
          contents: [
            %{kind: :text, content_text: "Original follow-up"},
            %{kind: :media, file_id: copied_file.id}
          ]
        )

      {:ok, tail} = Threads.add_message_to_end(source, :assistant, "Tail answer", actor: actor)

      {:ok, _inactive_user} =
        Threads.add_message(source, :user, "Inactive follow-up",
          actor: actor,
          parent_id: assistant.id
        )

      {:ok, _meta} = Threads.activate_branch(source.id, tail.id, actor)

      copied_content_id = media_content_id!(selected_user.id, actor)
      upload = create_upload!(conn, source.id, "uploaded.txt", "text/plain", 16)
      upload_id = upload["upload_id"]

      build_conn()
      |> sign_in_conn(actor.username, password)
      |> upload_chunk!(source.id, upload_id, "uploaded payload")

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{source.id}/branch-to-new-chat", %{
          "message_id" => selected_user.id,
          "content" => "Replacement follow-up",
          "copy_content_ids" => [copied_content_id],
          "upload_ids" => [upload_id]
        })

      payload = json_response(conn, 200)
      target_id = get_in(payload, ["chat", "id"])
      generation_id = get_in(payload, ["generation", "message_id"])

      assert is_integer(target_id)
      assert is_integer(generation_id)

      branch = payload["branch"] || []
      replacement = Enum.at(branch, -2)
      generated = List.last(branch)

      assert Enum.map(branch, & &1["role"]) == ["user", "assistant", "user", "assistant"]
      assert all_text_contents(Enum.at(branch, 0)) == ["Root"]
      assert all_text_contents(Enum.at(branch, 1)) == ["Answer"]
      assert all_text_contents(replacement) == ["Replacement follow-up"]
      assert generated["id"] == generation_id
      assert generated["parent_id"] == replacement["id"]

      media = media_contents(replacement)
      assert length(media) == 2

      assert Enum.map(media, &get_in(&1, ["media", "filename"])) |> Enum.sort() == [
               "copied.txt",
               "uploaded.txt"
             ]

      target_messages = messages_for_chat!(actor, target_id)
      target_text = Enum.map(target_messages, &message_text/1)

      refute "Original follow-up" in target_text
      refute "Inactive follow-up" in target_text
      refute "Tail answer" in target_text

      # The binding copy contract (order, flags, several bindings) is covered by
      # `POST /api/ash/chats/:id/copy`; here the branch only has to carry it over.
      assert %{blocks: [_ | _], tools: [_ | _]} =
               settings = chat_binding_settings!(actor, source)

      assert chat_binding_settings!(actor, target_id) == settings

      wait_for_generation_to_finish(conn, generation_id)
    end

    test "rejects missing message id", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      source = create_empty_chat!(actor)

      conn = post(conn, ~p"/api/bff/chat-generation/#{source.id}/branch-to-new-chat", %{})
      payload = json_response(conn, 422)

      assert payload["error"] == "message_id is required"
    end

    test "rejects inactive message", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      source = create_empty_chat!(actor)

      {:ok, root} = Threads.add_message_to_end(source, :user, "Root", actor: actor)

      {:ok, active} =
        Threads.add_message(source, :assistant, "Active", actor: actor, parent_id: root.id)

      {:ok, inactive} =
        Threads.add_message(source, :assistant, "Inactive", actor: actor, parent_id: root.id)

      {:ok, _meta} = Threads.activate_branch(source.id, active.id, actor)

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{source.id}/branch-to-new-chat", %{
          "message_id" => inactive.id
        })

      payload = json_response(conn, 422)
      assert payload["error"] == "Message is not in the active branch."
    end

    test "rejects non-owner", %{conn: conn} do
      %{user: owner} = user_fixture()
      %{user: other, password: password} = user_fixture()
      conn = sign_in_conn(conn, other.username, password)

      source = create_empty_chat!(owner)
      {:ok, message} = Threads.add_message_to_end(source, :user, "Root", actor: owner)

      conn =
        post(conn, ~p"/api/bff/chat-generation/#{source.id}/branch-to-new-chat", %{
          "message_id" => message.id,
          "content" => "Replacement"
        })

      assert response(conn, conn.status)
      assert conn.status in [403, 404]
    end
  end

  defp all_text_contents(message_payload) do
    message_payload
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.map(fn part -> Map.get(part, "text") || "" end)
  end

  defp media_contents(message_payload) do
    message_payload
    |> get_in(["content", "media"])
    |> List.wrap()
    |> Enum.filter(fn content -> Map.get(content, "kind") == "media" end)
  end

  defp temp_upload(filename, content_type, payload) do
    path =
      Path.join(System.tmp_dir!(), "chat-send-#{System.unique_integer([:positive])}-#{filename}")

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

  defp create_demo_configuration!(actor) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Branch demo provider", type: :demo, auth_method: :api_key},
        actor: actor
      )
      |> Ash.create!()

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "demo",
        parameters: %{},
        enabled: true,
        timeout_seconds: 5,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_upload!(conn, chat_id, filename, mime_type, size_bytes) do
    conn =
      post(conn, ~p"/api/bff/chat-uploads/#{chat_id}", %{
        "filename" => filename,
        "mime_type" => mime_type,
        "size_bytes" => size_bytes
      })

    json_response(conn, 200)["upload"]
  end

  defp upload_chunk!(conn, chat_id, upload_id, payload) do
    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-upload-offset", "0")
      |> put(~p"/api/bff/chat-uploads/#{chat_id}/#{upload_id}/chunk", payload)

    json_response(conn, 200)
  end

  defp media_content_id!(message_id, actor) do
    message =
      ChatMessage
      |> Ash.get!(message_id, actor: actor, load: [steps: [items: [:contents]]])

    message.steps
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.flat_map(&(&1.contents || []))
    |> Enum.find_value(fn content ->
      if content.kind == :media, do: content.id, else: nil
    end)
  end

  defp message_text(%ChatMessage{} = message) do
    IntellectualClub.Chat.Previews.message_preview_text(message)
  end
end
