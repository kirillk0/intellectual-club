defmodule IntellectualClubWeb.Bff.ChatDeleteTest do
  @moduledoc """
  Chat deletion endpoint tests for the SPA.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "DELETE /api/bff/chats/:id deletes chat with dependent records", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{title: "Delete chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, first} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    {:ok, _second} =
      Threads.add_message(chat, :assistant, "World", actor: actor, parent_id: first.id)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Delete block", version: "v1", type: :rules, content: "Test"},
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
          type: "mcp_http",
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

    conn = delete(conn, ~p"/api/bff/chats/#{chat.id}")
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
end
