defmodule IntellectualClubWeb.Bff.ChatMessageUpdateTest do
  @moduledoc """
  BFF message editing tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Tools.{BotToolBinding, ToolInstance}

  test "PATCH /api/bff/chat-messages/:id updates single answer content via legacy content field",
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
        load: [steps: [:finished_at]]
      )

    before_finished_at = before_update.finished_at
    [before_step] = Enum.sort_by(before_update.steps || [], & &1.sequence)

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
        load: [steps: [:finished_at]]
      )

    [after_step] = Enum.sort_by(after_update.steps || [], & &1.sequence)

    assert after_update.finished_at == before_finished_at
    assert after_step.finished_at == before_step.finished_at
  end

  test "PATCH /api/bff/chat-messages/:id updates multiple answer contents via contents payload",
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

  test "PATCH /api/bff/chat-messages/:id rejects legacy content payload when multiple contents exist",
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

  test "PATCH /api/bff/chat-messages/:id can remove and upload user attachments", %{conn: conn} do
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
          %{kind: :media, file_id: create_file!("old.txt", "text/plain", "old attachment").id}
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

  test "PATCH /api/bff/chat-messages/:id accepts upload_ids for user attachments", %{conn: conn} do
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
          %{kind: :media, file_id: create_file!("old.txt", "text/plain", "old attachment").id}
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

    conn = get(conn, ~p"/api/bff/chats/#{chat.id}/uploads/#{upload["upload_id"]}")
    assert json_response(conn, 404)["error"] == "Upload not found."
  end

  test "PATCH /api/bff/chat-messages/:id stores assistant attachments in artifact item", %{
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

    upload = temp_upload("diagram.png", "image/png", image_payload())

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

  test "PATCH /api/bff/chat-messages/:id rejects new attachments when uploads are disabled", %{
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
    assert payload["error"] == "File uploads are disabled for the current bot and configuration."
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

  defp create_file!(filename, mime_type, payload) do
    {:ok, file} =
      Files.create_from_upload(%{
        filename: filename,
        mime_type: mime_type,
        payload: payload
      })

    file
  end

  defp create_artifact_bot!(actor, name, attrs \\ []) do
    bot = create_bot!(actor, name, attrs)
    tool = create_artifact_tool!(actor, "#{name} Artifact Reader")
    bind_tool_to_bot!(actor, bot, tool)
    bot
  end

  defp create_bot!(actor, name, attrs) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        max_tool_rounds: 20,
        context_soft_limit_percent: 80,
        history_mode: :chat,
        max_file_size_bytes: Keyword.get(attrs, :max_file_size_bytes, 500 * 1024 * 1024)
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_artifact_tool!(actor, name) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-artifact-reader",
        name: name,
        alias: "artifacts",
        config: %{},
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp bind_tool_to_bot!(actor, bot, tool) do
    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: tool.id,
        sharing_mode: :shared,
        enabled: true,
        sequence: 0
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
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

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
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
