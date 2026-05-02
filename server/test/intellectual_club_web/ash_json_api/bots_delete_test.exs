defmodule IntellectualClubWeb.AshJsonApi.BotsDeleteTest do
  @moduledoc """
  Regression tests for bot deletion through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.FilePayload
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Db

  import Ecto.Query
  require Ash.Query

  test "DELETE /api/ash/bots/:id deletes owned bot", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Delete me",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/bots/#{bot.id}")

    assert conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Bot, bot.id, actor: actor)
  end

  test "DELETE /api/ash/bots/:id clears dependent references", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Delete with deps",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Delete deps block", version: "v1", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding =
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
        %{title: "Linked chat", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/bots/#{bot.id}")

    assert conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Bot, bot.id, actor: actor)

    remaining_bindings =
      BotKnowledgeBlock
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.read!(actor: actor)

    assert remaining_bindings == []

    updated_chat = Ash.get!(Chat, chat.id, actor: actor)
    assert updated_chat.bot_id == nil
  end

  test "DELETE /api/ash/bots/:id removes the attached image file and payload", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    assert {:ok, stored_file} =
             Files.create_from_upload(%{
               filename: "bot-delete.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Delete with image",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 20,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)
      |> then(fn bot ->
        bot
        |> Ash.Changeset.for_update(:attach_image_file, %{image_file_id: stored_file.id},
          actor: actor
        )
        |> Ash.update!(actor: actor)
      end)

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/bots/#{bot.id}")

    assert conn.status in [200, 204]

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(StoredFile, stored_file.id, authorize?: false)

    assert Db.repo().aggregate(
             from(payload in FilePayload, where: payload.sha256 == ^stored_file.sha256),
             :count,
             :sha256
           ) == 0
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
