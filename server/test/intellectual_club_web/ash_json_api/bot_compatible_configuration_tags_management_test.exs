defmodule IntellectualClubWeb.AshJsonApi.BotCompatibleConfigurationTagsManagementTest do
  @moduledoc """
  Regression tests for managing bot-compatible configuration tags through the bot update action.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Bots.{Bot, BotCompatibleConfigurationTag, BotKnowledgeBlock, BotShare}
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfigurationTag
  alias IntellectualClub.Tools.{BotToolBinding, BotUserToolBinding, ToolInstance}

  require Ash.Query

  @bot_include_query Enum.join(
                       [
                         "include=knowledge_block_bindings.knowledge_block,compatible_configuration_tag_bindings.llm_configuration_tag,tool_bindings.tool_instance,user_tool_bindings.tool_instance"
                       ],
                       "&"
                     )

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp json_api_patch(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, body)
  end

  defp relationship_ids(%{"data" => %{"relationships" => relationships}}, rel_name) do
    relationships
    |> Map.get(rel_name, %{})
    |> Map.get("data", [])
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp relationship_ids(_resp, _rel_name), do: []

  defp ids_from_included(%{"included" => included}, type) when is_list(included) do
    included
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp ids_from_included(_resp, _type), do: []

  test "GET /api/ash/bots/:id includes attached resources and actor-specific overrides", %{
    conn: conn
  } do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    tag =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Compatible"}, actor: owner)
      |> Ash.create!(actor: owner)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Knowledge", version: "v1", type: :rules, content: "content", variables: %{}},
        actor: owner
      )
      |> Ash.create!(actor: owner)

    shared_tool = create_tool!(owner, "Shared tool", "https://example.com/shared")
    recipient_tool = create_tool!(recipient, "Recipient tool", "https://example.com/recipient")

    bot =
      create_bot!(owner, "Shared bot",
        supports_file_processing: true,
        max_file_size_bytes: 42 * 1024 * 1024
      )

    block_binding =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: block.id, enabled: true, sequence: 0},
        actor: owner
      )
      |> Ash.create!(actor: owner)

    tag_binding =
      BotCompatibleConfigurationTag
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, llm_configuration_tag_id: tag.id},
        actor: owner
      )
      |> Ash.create!(actor: owner)

    shared_binding =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: shared_tool.id,
          alias: "shared_tool",
          sharing_mode: :shared,
          enabled: true,
          sequence: 0
        },
        actor: owner
      )
      |> Ash.create!(actor: owner)

    per_user_binding =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: shared_tool.id,
          alias: "personal_tool",
          sharing_mode: :per_user,
          enabled: true,
          sequence: 1
        },
        actor: owner
      )
      |> Ash.create!(actor: owner)

    owner_override =
      BotUserToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: shared_tool.id,
          alias: "personal_tool",
          enabled: true,
          sequence: 1
        },
        actor: owner
      )
      |> Ash.create!(actor: owner)

    BotShare
    |> Ash.Changeset.for_create(:create, %{bot_id: bot.id, user_group_id: group.id}, actor: owner)
    |> Ash.create!(actor: owner)

    recipient_override =
      BotUserToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: recipient_tool.id,
          alias: "personal_tool",
          enabled: true,
          sequence: 1
        },
        actor: recipient
      )
      |> Ash.create!(actor: recipient)

    response =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_get("/api/ash/bots/#{bot.id}?#{@bot_include_query}")
      |> json_response(200)

    assert relationship_ids(response, "knowledge_block_bindings") == [block_binding.id]
    assert relationship_ids(response, "compatible_configuration_tag_bindings") == [tag_binding.id]
    assert get_in(response, ["data", "attributes", "supports_file_processing"]) == true
    assert get_in(response, ["data", "attributes", "max_file_size_bytes"]) == 42 * 1024 * 1024

    assert relationship_ids(response, "tool_bindings") ==
             Enum.sort([shared_binding.id, per_user_binding.id])

    assert relationship_ids(response, "user_tool_bindings") == [recipient_override.id]

    assert ids_from_included(response, "knowledge-blocks") == [block.id]
    assert ids_from_included(response, "llm-configuration-tags") == [tag.id]

    assert ids_from_included(response, "tool-instances") ==
             Enum.sort([shared_tool.id, recipient_tool.id])

    assert ids_from_included(response, "bot-user-tool-bindings") == [recipient_override.id]
    refute owner_override.id in ids_from_included(response, "bot-user-tool-bindings")
  end

  test "PATCH /api/ash/bots/:id manages compatible configuration tags", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    tag1 =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Compatible One"}, actor: actor)
      |> Ash.create!(actor: actor)

    tag2 =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Compatible Two"}, actor: actor)
      |> Ash.create!(actor: actor)

    block1 =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block One", version: "v1", type: :rules, content: "x", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block2 =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block Two", version: "v2", type: :rules, content: "y", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool1 = create_tool!(actor, "Tool One", "https://example.com/one")
    tool2 = create_tool!(actor, "Tool Two", "https://example.com/two")

    bot =
      Bot
      |> Ash.Changeset.for_create(:create, %{name: "Tagged bot"}, actor: actor)
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)

    resp1 =
      conn
      |> json_api_patch("/api/ash/bots/#{bot.id}?#{@bot_include_query}", %{
        "data" => %{
          "type" => "bots",
          "id" => "#{bot.id}",
          "attributes" => %{
            "compatible_configuration_tag_bindings" => [
              %{"llm_configuration_tag_id" => tag1.id},
              %{"llm_configuration_tag_id" => tag2.id}
            ],
            "knowledge_block_bindings" => [
              %{"knowledge_block_id" => block1.id, "enabled" => true, "sequence" => 0},
              %{"knowledge_block_id" => block2.id, "enabled" => true, "sequence" => 1}
            ],
            "tool_bindings" => [
              %{
                "tool_instance_id" => tool1.id,
                "alias" => "tool_one",
                "sharing_mode" => "shared",
                "enabled" => true
              },
              %{
                "tool_instance_id" => tool2.id,
                "alias" => "tool_two",
                "sharing_mode" => "shared",
                "enabled" => false
              }
            ]
          }
        }
      })
      |> json_response(200)

    bindings1 =
      BotCompatibleConfigurationTag
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.read!(actor: actor)

    assert Enum.sort(Enum.map(bindings1, & &1.llm_configuration_tag_id)) ==
             Enum.sort([tag1.id, tag2.id])

    block_bindings1 =
      BotKnowledgeBlock
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(block_bindings1, & &1.knowledge_block_id) == [block1.id, block2.id]

    tool_bindings1 =
      BotToolBinding
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(tool_bindings1, &{&1.tool_instance_id, &1.alias, &1.enabled, &1.sequence}) ==
             [
               {tool1.id, "tool_one", true, 0},
               {tool2.id, "tool_two", false, 1}
             ]

    assert relationship_ids(resp1, "compatible_configuration_tag_bindings") ==
             Enum.sort(Enum.map(bindings1, & &1.id))

    assert relationship_ids(resp1, "knowledge_block_bindings") ==
             Enum.map(block_bindings1, & &1.id)

    assert relationship_ids(resp1, "tool_bindings") == Enum.map(tool_bindings1, & &1.id)

    assert ids_from_included(resp1, "llm-configuration-tags") == Enum.sort([tag1.id, tag2.id])
    assert ids_from_included(resp1, "knowledge-blocks") == Enum.sort([block1.id, block2.id])
    assert ids_from_included(resp1, "tool-instances") == Enum.sort([tool1.id, tool2.id])

    binding1 = Enum.find(bindings1, &(&1.llm_configuration_tag_id == tag1.id))
    assert binding1

    block_binding1 = Enum.find(block_bindings1, &(&1.knowledge_block_id == block1.id))
    assert block_binding1

    tool_binding1 = Enum.find(tool_bindings1, &(&1.tool_instance_id == tool1.id))
    assert tool_binding1

    resp2 =
      conn
      |> json_api_patch("/api/ash/bots/#{bot.id}?#{@bot_include_query}", %{
        "data" => %{
          "type" => "bots",
          "id" => "#{bot.id}",
          "attributes" => %{
            "compatible_configuration_tag_bindings" => [
              %{"id" => binding1.id, "llm_configuration_tag_id" => tag1.id}
            ],
            "knowledge_block_bindings" => [
              %{
                "id" => block_binding1.id,
                "knowledge_block_id" => block1.id,
                "enabled" => true,
                "sequence" => 0
              }
            ],
            "tool_bindings" => [
              %{
                "id" => tool_binding1.id,
                "tool_instance_id" => tool1.id,
                "alias" => "tool_one",
                "sharing_mode" => "shared",
                "enabled" => false
              }
            ]
          }
        }
      })
      |> json_response(200)

    bindings2 =
      BotCompatibleConfigurationTag
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.read!(actor: actor)

    assert Enum.map(bindings2, & &1.llm_configuration_tag_id) == [tag1.id]

    block_bindings2 =
      BotKnowledgeBlock
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(block_bindings2, & &1.knowledge_block_id) == [block1.id]

    tool_bindings2 =
      BotToolBinding
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(tool_bindings2, &{&1.tool_instance_id, &1.alias, &1.enabled, &1.sequence}) ==
             [
               {tool1.id, "tool_one", false, 0}
             ]

    assert relationship_ids(resp2, "compatible_configuration_tag_bindings") ==
             Enum.map(bindings2, & &1.id)

    assert relationship_ids(resp2, "knowledge_block_bindings") ==
             Enum.map(block_bindings2, & &1.id)

    assert relationship_ids(resp2, "tool_bindings") == Enum.map(tool_bindings2, & &1.id)

    assert ids_from_included(resp2, "llm-configuration-tags") == [tag1.id]
    assert ids_from_included(resp2, "knowledge-blocks") == [block1.id]
    assert ids_from_included(resp2, "tool-instances") == [tool1.id]
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
        supports_file_processing: false,
        max_file_size_bytes: 500 * 1024 * 1024,
        history_mode: :chat
      }
      |> Map.merge(Enum.into(attrs, %{})),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_tool!(actor, name, server_url) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "mcp_http",
        name: name,
        config: %{"server_url" => server_url},
        secrets: %{"bearer_token" => "super-secret"},
        max_output_tokens: 1000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
