defmodule IntellectualClubWeb.AshJsonApi.BotsDuplicationTest do
  @moduledoc """
  Regression tests for bot duplication through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotCompatibleConfigurationTag, BotKnowledgeBlock}
  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfigurationTag
  alias IntellectualClub.Tools.{BotToolBinding, BotUserToolBinding, ToolInstance}

  require Ash.Query

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  test "POST /api/ash/bots/:id/duplicate copies knowledge block bindings and compatible configuration tags",
       %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    block_a =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block A", version: "v1", content: "A"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_b =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block B", version: "v1", content: "B"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tag_a =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag A"}, actor: actor)
      |> Ash.create!(actor: actor)

    tag_b =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag B"}, actor: actor)
      |> Ash.create!(actor: actor)

    source_bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Knowledge bot",
          compatible_configuration_tag_bindings: [
            %{llm_configuration_tag_id: tag_a.id},
            %{llm_configuration_tag_id: tag_b.id}
          ],
          knowledge_block_bindings: [
            %{knowledge_block_id: block_a.id, enabled: true},
            %{knowledge_block_id: block_b.id, enabled: false}
          ]
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/bots/#{source_bot.id}/duplicate", %{
        "data" => %{
          "type" => "bots",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated_bot_id = String.to_integer(response["data"]["id"])

    duplicated_bindings =
      BotKnowledgeBlock
      |> Ash.Query.filter(bot_id == ^duplicated_bot_id)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(duplicated_bindings, &{&1.knowledge_block_id, &1.enabled, &1.sequence}) == [
             {block_a.id, true, 0},
             {block_b.id, false, 1}
           ]

    duplicated_tag_ids =
      BotCompatibleConfigurationTag
      |> Ash.Query.filter(bot_id == ^duplicated_bot_id)
      |> Ash.Query.sort(llm_configuration_tag_id: :asc)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.llm_configuration_tag_id)

    assert duplicated_tag_ids == Enum.sort([tag_a.id, tag_b.id])
  end

  test "POST /api/ash/bots/:id/duplicate copies bot tool bindings and user overrides", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    source_bot =
      Bot
      |> Ash.Changeset.for_create(:create, %{name: "Tools bot"}, actor: actor)
      |> Ash.create!(actor: actor)

    shared_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp_http",
          name: "Shared MCP",
          alias: "shared_tool",
          config: %{"server_url" => "https://shared.example.com/mcp"},
          secrets: %{"bearer_token" => "shared"},
          max_output_tokens: 1000
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    private_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "mcp_http",
          name: "Private MCP",
          alias: "private_tool",
          config: %{"server_url" => "https://private.example.com/mcp"},
          secrets: %{"bearer_token" => "private"},
          max_output_tokens: 2000
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding_a =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: source_bot.id,
          tool_instance_id: shared_tool.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 2
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding_b =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: source_bot.id,
          tool_instance_id: private_tool.id,
          sharing_mode: :per_user,
          enabled: false,
          sequence: 4
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _user_binding =
      BotUserToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: source_bot.id,
          tool_instance_id: private_tool.id,
          enabled: true,
          sequence: 3
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/bots/#{source_bot.id}/duplicate", %{
        "data" => %{
          "type" => "bots",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated_bot_id = String.to_integer(response["data"]["id"])

    duplicated_tool_bindings =
      BotToolBinding
      |> Ash.Query.filter(bot_id == ^duplicated_bot_id)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.Query.load([:alias])
      |> Ash.read!(actor: actor)

    assert Enum.map(
             duplicated_tool_bindings,
             &{&1.tool_instance_id, &1.alias, &1.sharing_mode, &1.enabled, &1.sequence}
           ) == [
             {shared_tool.id, "shared_tool", :shared, true, 2},
             {private_tool.id, "private_tool", :per_user, false, 4}
           ]

    duplicated_user_tool_bindings =
      BotUserToolBinding
      |> Ash.Query.filter(bot_id == ^duplicated_bot_id)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.Query.load([:alias])
      |> Ash.read!(actor: actor)

    assert Enum.map(
             duplicated_user_tool_bindings,
             &{&1.tool_instance_id, &1.alias, &1.enabled, &1.sequence}
           ) == [
             {private_tool.id, "private_tool", true, 3}
           ]
  end

  test "POST /api/ash/bots/:id/duplicate creates a new image file row with the same payload", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    assert {:ok, source_file} =
             Files.create_from_upload(%{
               filename: "bot.png",
               mime_type: "image/png",
               payload: image_payload()
             })

    source_bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Image bot",
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
        |> Ash.Changeset.for_update(:attach_image_file, %{image_file_id: source_file.id},
          actor: actor
        )
        |> Ash.update!(actor: actor)
      end)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/bots/#{source_bot.id}/duplicate", %{
        "data" => %{
          "type" => "bots",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated_bot = Ash.get!(Bot, String.to_integer(response["data"]["id"]), actor: actor)

    assert duplicated_bot.image_file_id != source_bot.image_file_id
    assert is_integer(duplicated_bot.image_file_id)

    duplicated_file = Ash.get!(StoredFile, duplicated_bot.image_file_id, authorize?: false)

    assert duplicated_file.sha256 == source_file.sha256
    assert duplicated_file.filename == source_file.filename
  end

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
