defmodule IntellectualClubWeb.Bff.ChatSendTest do
  @moduledoc """
  Send endpoint regression tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.{Chat, Threads}
  alias IntellectualClub.Llm.{LlmConfiguration, LlmProvider}

  test "POST /api/bff/chats/:id/send treats whitespace-only content as user message", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Whitespace send chat")
    whitespace = "   "

    conn = post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{"content" => whitespace})
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

  test "POST /api/bff/chats/:id/send with empty content does not create user message", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Empty send chat")

    conn = post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{"content" => ""})
    payload = json_response(conn, 200)

    generation_id = get_in(payload, ["generation", "message_id"])
    assert is_integer(generation_id)

    branch = payload["branch"] || []
    refute Enum.any?(branch, &(&1["role"] == "user"))

    wait_for_generation_to_finish(conn, generation_id)
  end

  test "POST /api/bff/chats/:id/send with file-only multipart creates user media content", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "File bot", supports_file_processing: true)
    chat = create_chat!(actor, "File send chat", %{bot_id: bot.id})
    upload = temp_upload("attached.png", "image/png", image_payload())

    conn = post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{"content" => "", "files" => [upload]})
    payload = json_response(conn, 200)

    branch = payload["branch"] || []
    user_messages = Enum.filter(branch, &(&1["role"] == "user"))
    assert length(user_messages) == 1

    [user_message] = user_messages

    media_contents =
      (Map.get(user_message, "steps") || [])
      |> Enum.flat_map(fn step -> Map.get(step, "items") || [] end)
      |> Enum.flat_map(fn item -> Map.get(item, "contents") || [] end)
      |> Enum.filter(fn content -> Map.get(content, "kind") == "media" end)

    assert length(media_contents) == 1
    [media_content] = media_contents
    assert is_binary(get_in(media_content, ["media", "external_id"]))
    assert get_in(media_content, ["media", "filename"]) == "attached.png"
    assert get_in(media_content, ["media", "mime_type"]) == "image/png"
  end

  test "POST /api/bff/chats/:id/send with upload_ids creates user media content and consumes uploads",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "Chunk send bot", supports_file_processing: true)
    chat = create_chat!(actor, "Chunk send chat", %{bot_id: bot.id})
    upload = upload_text_attachment!(conn, actor.username, password, chat.id, "attached.txt", "chunk upload")

    conn =
      post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{
        "content" => "",
        "upload_ids" => [upload["upload_id"]]
      })

    payload = json_response(conn, 200)
    branch = payload["branch"] || []
    user_messages = Enum.filter(branch, &(&1["role"] == "user"))

    assert length(user_messages) == 1
    [user_message] = user_messages

    media_contents =
      (Map.get(user_message, "steps") || [])
      |> Enum.flat_map(fn step -> Map.get(step, "items") || [] end)
      |> Enum.flat_map(fn item -> Map.get(item, "contents") || [] end)
      |> Enum.filter(fn content -> Map.get(content, "kind") == "media" end)

    assert length(media_contents) == 1
    [media_content] = media_contents
    assert get_in(media_content, ["media", "filename"]) == "attached.txt"
    assert get_in(media_content, ["media", "mime_type"]) == "text/plain"

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/uploads/#{upload["upload_id"]}")
    assert json_response(conn, 404)["error"] == "Upload not found."
  end

  test "POST /api/bff/chats/:id/send rejects files when bot and configuration do not allow uploads",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Restricted send chat")
    upload = temp_upload("attached.txt", "text/plain", "hello")

    conn = post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{"content" => "", "files" => [upload]})
    payload = json_response(conn, 422)

    assert payload["error"] == "File uploads are disabled for the current bot and configuration."
  end

  test "POST /api/bff/chats/:id/send allows images when configuration supports image input", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    provider = create_provider!(actor, "Image provider")

    configuration =
      create_configuration!(actor, provider, "image-model", supports_image_input: true)

    chat = create_chat!(actor, "Image send chat", %{llm_configuration_id: configuration.id})
    upload = temp_upload("attached.png", "image/png", image_payload())

    conn = post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{"content" => "", "files" => [upload]})
    payload = json_response(conn, 200)

    branch = payload["branch"] || []
    user_messages = Enum.filter(branch, &(&1["role"] == "user"))
    assert length(user_messages) == 1
  end

  test "POST /api/bff/chats/:id/send rejects files above the bot size limit", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot =
      create_bot!(actor, "Small limit bot",
        supports_file_processing: true,
        max_file_size_bytes: 4
      )

    chat = create_chat!(actor, "Small limit chat", %{bot_id: bot.id})
    upload = temp_upload("attached.txt", "text/plain", "hello")

    conn = post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{"content" => "", "files" => [upload]})
    payload = json_response(conn, 422)

    assert payload["error"] == ~s(File "attached.txt" exceeds the maximum size of 4 B.)
  end

  test "POST /api/bff/chats/:id/send without parent_id appends follow-up to active branch leaf",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Follow-up send chat")
    {:ok, root} = Threads.add_message(chat, :user, "Root", actor: actor, parent_id: nil)

    {:ok, assistant} =
      Threads.add_message(chat, :assistant, "Answer", actor: actor, parent_id: root.id)

    conn = post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{"content" => "Follow-up"})
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
    assert Enum.map(branch, & &1["id"]) == [root.id, assistant.id, follow_up["id"], generation_id]

    wait_for_generation_to_finish(conn, generation_id)
  end

  test "POST /api/bff/chats/:id/send can copy existing attachments without reupload", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    bot = create_bot!(actor, "Copy bot", supports_file_processing: true)
    chat = create_chat!(actor, "Copy chat", %{bot_id: bot.id})
    original_file = create_file!("spec.txt", "text/plain", "copied attachment")

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

    {:ok, assistant} = Threads.add_message(chat, :assistant, "Answer", actor: actor, parent_id: root.id)

    conn =
      post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{
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

    copied_media =
      (Map.get(copied_user_message, "steps") || [])
      |> Enum.flat_map(fn step -> Map.get(step, "items") || [] end)
      |> Enum.flat_map(fn item -> Map.get(item, "contents") || [] end)
      |> Enum.filter(fn content -> Map.get(content, "kind") == "media" end)

    assert length(copied_media) == 1
    [content] = copied_media
    assert get_in(content, ["media", "filename"]) == "spec.txt"
    assert get_in(content, ["media", "mime_type"]) == "text/plain"

    generated = Enum.find(branch, &(&1["id"] == generation_id))
    assert is_map(generated)
    assert generated["parent_id"] == copied_user_message["id"]

    wait_for_generation_to_finish(conn, generation_id)
  end

  test "POST /api/bff/chats/:id/send with explicit null parent_id branches from root level", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat = create_chat!(actor, "Root branch send chat")
    {:ok, root} = Threads.add_message(chat, :user, "Root", actor: actor, parent_id: nil)

    {:ok, assistant} =
      Threads.add_message(chat, :assistant, "Answer", actor: actor, parent_id: root.id)

    conn =
      post(conn, ~p"/api/bff/chats/#{chat.id}/send", %{
        "content" => "Alternative root",
        "parent_id" => nil
      })

    payload = json_response(conn, 200)

    generation_id = get_in(payload, ["generation", "message_id"])
    assert is_integer(generation_id)

    branch = payload["branch"] || []

    alternative_root =
      Enum.find(branch, &(&1["role"] == "user" and all_text_contents(&1) == ["Alternative root"]))

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

  defp create_chat!(actor, title, attrs \\ %{}) do
    Chat
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{title: title, note: "", variables: %{}}, attrs),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_bot!(actor, name, attrs) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        variables: %{},
        max_tool_rounds: 20,
        context_soft_limit_percent: 80,
        history_mode: :chat,
        supports_file_processing: Keyword.get(attrs, :supports_file_processing, false),
        max_file_size_bytes: Keyword.get(attrs, :max_file_size_bytes, 500 * 1024 * 1024)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_provider!(actor, name) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        type: :openrouter_chat_completion,
        auth_method: :api_key,
        base_url: "https://openrouter.ai/api/v1",
        api_key: "test-key"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor, provider, model_name, attrs) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: "cfg",
        parameters: %{},
        enabled: true,
        timeout_seconds: 300,
        supports_image_input: Keyword.get(attrs, :supports_image_input, false)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp all_text_contents(message_payload) do
    (Map.get(message_payload, "steps") || [])
    |> Enum.flat_map(fn step -> Map.get(step, "items") || [] end)
    |> Enum.flat_map(fn item -> Map.get(item, "contents") || [] end)
    |> Enum.filter(fn content -> Map.get(content, "kind") == "text" end)
    |> Enum.map(fn content -> Map.get(content, "content_text") || "" end)
  end

  defp wait_for_generation_to_finish(conn, message_id, attempts_left \\ 200)

  defp wait_for_generation_to_finish(_conn, _message_id, 0) do
    flunk("Generation did not finish within timeout")
  end

  defp wait_for_generation_to_finish(conn, message_id, attempts_left) do
    payload =
      conn
      |> get(~p"/api/bff/chat-messages/#{message_id}/poll")
      |> json_response(200)

    if payload["status"] in ["done", "canceled", "error"] do
      :ok
    else
      Process.sleep(20)
      wait_for_generation_to_finish(conn, message_id, attempts_left - 1)
    end
  end

  defp temp_upload(filename, content_type, payload) do
    path =
      Path.join(System.tmp_dir!(), "chat-send-#{System.unique_integer([:positive])}-#{filename}")

    File.write!(path, payload)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end

  defp create_file!(filename, mime_type, payload) do
    {:ok, file} =
      IntellectualClub.Files.create_from_upload(%{
        filename: filename,
        mime_type: mime_type,
        payload: payload
      })

    file
  end

  defp upload_text_attachment!(conn, username, password, chat_id, filename, payload) do
    size = byte_size(payload)

    upload =
      conn
      |> post(~p"/api/bff/chats/#{chat_id}/uploads", %{
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
    |> put(~p"/api/bff/chats/#{chat_id}/uploads/#{upload["upload_id"]}/chunk", payload)
    |> json_response(200)

    upload
  end
end
