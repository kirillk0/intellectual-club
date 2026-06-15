defmodule IntellectualClubWeb.Bff.ChatDeleteTest do
  @moduledoc """
  Chat deletion endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Db
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilePayload
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  import Ecto.Query
  require Ash.Query

  test "DELETE /api/bff/chat-lifecycle/:id deletes chat with dependent records", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, first} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    {:ok, _second} =
      Threads.add_message(chat, :assistant, "World", actor: actor, parent_id: first.id)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Delete block", version: "v1", content: "Test"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, knowledge_block_id: block.id, enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp-http",
          name: "Delete tool binding",
          config: %{"server_url" => "https://example.com/delete"},
          secrets: %{"bearer_token" => "delete"}
        },
        actor: actor
      )
      |> Ash.create!()

    _tool_binding =
      ChatToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, tool_instance_id: tool.id, alias: "web", enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!()

    conn = delete(conn, ~p"/api/bff/chat-lifecycle/#{chat.id}")
    assert %{"status" => "ok"} = json_response(conn, 200)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Chat, chat.id, actor: actor)

    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.read!(actor: actor)

    assert messages == []

    bindings =
      ChatKnowledgeBlock
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.read!(actor: actor)

    assert bindings == []

    tool_bindings =
      ChatToolBinding
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.read!(actor: actor)

    assert tool_bindings == []
  end

  test "DELETE /api/bff/chat-lifecycle/:id removes attachment files and payloads via Ash cascades", %{
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

    file = create_file!("delete.txt", "text/plain", "delete payload")

    {:ok, message} =
      Threads.add_message_to_end(chat, :user, "",
        actor: actor,
        contents: [
          %{kind: :text, content_text: "Delete with attachment"},
          %{kind: :media, file_id: file.id}
        ]
      )

    loaded =
      Ash.get!(ChatMessage, message.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    [step] = Enum.sort_by(loaded.steps || [], & &1.sequence)
    [item] = Enum.sort_by(step.items || [], & &1.sequence)
    media_content = Enum.find(item.contents || [], &(&1.kind == :media))

    conn = delete(conn, ~p"/api/bff/chat-lifecycle/#{chat.id}")
    assert %{"status" => "ok"} = json_response(conn, 200)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Chat, chat.id, actor: actor)

    assert {:error, _} = Ash.get(ChatMessage, message.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageStep, step.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageItem, item.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageContent, media_content.id, actor: actor)
    assert {:error, _} = Ash.get(StoredFile, file.id, authorize?: false)
    assert payload_count(file.sha256) == 0
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

  defp payload_count(sha256) do
    Db.repo().aggregate(
      from(payload in FilePayload, where: payload.sha256 == ^sha256),
      :count,
      :sha256
    )
  end
end
