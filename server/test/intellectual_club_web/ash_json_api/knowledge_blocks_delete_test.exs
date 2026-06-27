defmodule IntellectualClubWeb.AshJsonApi.KnowledgeBlocksDeleteTest do
  @moduledoc """
  Regression tests for knowledge block deletion through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilesystemStorage
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockTag
  alias IntellectualClub.Knowledge.KnowledgeTag

  require Ash.Query

  test "DELETE /api/ash/knowledge-blocks/:id deletes block and clears dependent bindings", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Delete block", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tag =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Delete tag"}, actor: actor)
      |> Ash.create!(actor: actor)

    _tag_binding =
      KnowledgeBlockTag
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, knowledge_tag_id: tag.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Delete block bot",
          first_messages: [],
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat,
          handoff_message_block_id: block.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _bot_binding =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: block.id, enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: ""},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _chat_binding =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, knowledge_block_id: block.id, enabled: true, sequence: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/knowledge-blocks/#{block.id}")

    assert conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(KnowledgeBlock, block.id, actor: actor)

    remaining_tag_bindings =
      KnowledgeBlockTag
      |> Ash.Query.filter(knowledge_block_id == ^block.id)
      |> Ash.read!(actor: actor)

    assert remaining_tag_bindings == []

    remaining_bot_bindings =
      BotKnowledgeBlock
      |> Ash.Query.filter(knowledge_block_id == ^block.id)
      |> Ash.read!(actor: actor)

    assert remaining_bot_bindings == []

    remaining_chat_bindings =
      ChatKnowledgeBlock
      |> Ash.Query.filter(knowledge_block_id == ^block.id)
      |> Ash.read!(actor: actor)

    assert remaining_chat_bindings == []

    assert Ash.get!(Bot, bot.id, actor: actor).id == bot.id
    assert Ash.get!(Bot, bot.id, actor: actor).handoff_message_block_id == nil
    assert Ash.get!(Chat, chat.id, actor: actor).id == chat.id
  end

  test "DELETE /api/ash/knowledge-blocks/:id removes the attached image file and payload", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    assert {:ok, stored_file} =
             Files.create_from_upload(%{
               filename: "block-delete.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Delete imaged block", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)
      |> then(fn block ->
        block
        |> Ash.Changeset.for_update(
          :attach_image_file,
          %{image_file_id: stored_file.id},
          actor: actor
        )
        |> Ash.update!(actor: actor)
      end)

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/knowledge-blocks/#{block.id}")

    assert conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(StoredFile, stored_file.id, authorize?: false)

    refute FilesystemStorage.exists?(stored_file.sha256)
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
