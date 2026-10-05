defmodule IntellectualClubWeb.AshJsonApi.BotsTest do
  @moduledoc """
  Bots and bot tool bindings through the AshJsonApi endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  import IntellectualClubWeb.AshJsonApiContract

  alias IntellectualClub.Bots.{Bot, BotCompatibleConfigurationTag, BotKnowledgeBlock}
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Tools.{BotToolBinding, BotUserToolBinding}

  require Ash.Query

  @include "knowledge_block_bindings.knowledge_block," <>
             "compatible_configuration_tag_bindings.llm_configuration_tag," <>
             "tool_bindings.tool_instance,user_tool_bindings.tool_instance"

  describe "GET /api/ash/bots" do
    test "exposes blocks_count and tools_count" do
      %{user: actor} = owner = user_fixture()
      bot = create_bot!(actor)
      empty_bot = create_bot!(actor)

      for sequence <- [0, 1] do
        block = create_knowledge_block!(actor)
        tool = create_tool_instance!(actor, alias: "tool_#{sequence}")
        bind_block!(actor, bot, block, sequence: sequence)
        create_bot_tool_binding!(actor, bot, tool, sequence: sequence)
      end

      attributes_by_id =
        owner
        |> api_get!("/api/ash/bots?fields[bots]=name,blocks_count,tools_count")
        |> Map.fetch!("data")
        |> Map.new(&{&1["id"], &1["attributes"]})

      assert %{"blocks_count" => 2, "tools_count" => 2} = attributes_by_id["#{bot.id}"]
      assert %{"blocks_count" => 0, "tools_count" => 0} = attributes_by_id["#{empty_bot.id}"]
    end
  end

  describe "GET /api/ash/bots/:id" do
    test "includes attached resources and only the actor's own tool overrides" do
      %{user: owner} = user_fixture()
      %{user: recipient} = recipient_fixture = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})

      tag = create_configuration_tag!(owner, name: "Compatible")
      block = create_knowledge_block!(owner)
      shared_tool = create_tool_instance!(owner, alias: "shared_tool")
      per_user_tool = create_tool_instance!(owner, alias: "personal_tool")
      recipient_tool = create_tool_instance!(recipient, alias: "personal_tool")
      bot = create_bot!(owner, max_file_size_bytes: 42 * 1024 * 1024)

      block_binding = bind_block!(owner, bot, block)
      tag_binding = bind_compatible_tag!(owner, bot, tag)
      shared_binding = create_bot_tool_binding!(owner, bot, shared_tool)

      per_user_binding =
        create_bot_tool_binding!(owner, bot, per_user_tool, sharing_mode: :per_user, sequence: 1)

      owner_override = create_user_tool_override!(owner, bot, per_user_tool)
      share_bot!(owner, bot, group)
      recipient_override = create_user_tool_override!(recipient, bot, recipient_tool)

      response = api_get!(recipient_fixture, "/api/ash/bots/#{bot.id}?include=#{@include}")

      assert relationship_ids(response, "knowledge_block_bindings") == [block_binding.id]

      assert relationship_ids(response, "compatible_configuration_tag_bindings") == [
               tag_binding.id
             ]

      assert relationship_ids(response, "tool_bindings") ==
               Enum.sort([shared_binding.id, per_user_binding.id])

      assert relationship_ids(response, "user_tool_bindings") == [recipient_override.id]
      assert ids_from_included(response, "knowledge-blocks") == [block.id]
      assert ids_from_included(response, "llm-configuration-tags") == [tag.id]

      assert ids_from_included(response, "tool-instances") ==
               Enum.sort([shared_tool.id, recipient_tool.id])

      assert ids_from_included(response, "bot-user-tool-bindings") == [recipient_override.id]
      refute owner_override.id in ids_from_included(response, "bot-user-tool-bindings")

      attributes = response["data"]["attributes"]
      assert attributes["max_file_size_bytes"] == 42 * 1024 * 1024
      refute Map.has_key?(attributes, "supports_file_processing")
    end
  end

  describe "PATCH /api/ash/bots/:id" do
    test "manages compatible tag, knowledge block and tool bindings" do
      %{user: actor} = owner = user_fixture()
      bot = create_bot!(actor)
      tags = for _ <- 1..2, do: create_configuration_tag!(actor).id
      blocks = for _ <- 1..2, do: create_knowledge_block!(actor).id

      [tool_one, tool_two] =
        for name <- ["tool_one", "tool_two"], do: create_tool_instance!(actor, alias: name).id

      assert_manages_bindings(owner, %{
        collection: "/api/ash/bots",
        type: "bots",
        id: bot.id,
        include: @include,
        relationships: [
          %{
            name: "compatible_configuration_tag_bindings",
            resource: BotCompatibleConfigurationTag,
            parent_key: :bot_id,
            target_key: :llm_configuration_tag_id,
            included: "llm-configuration-tags",
            targets: tags,
            attrs: fn tag_id, _index -> %{"llm_configuration_tag_id" => tag_id} end
          },
          %{
            name: "knowledge_block_bindings",
            resource: BotKnowledgeBlock,
            parent_key: :bot_id,
            target_key: :knowledge_block_id,
            included: "knowledge-blocks",
            targets: blocks,
            attrs: fn block_id, index ->
              %{"knowledge_block_id" => block_id, "enabled" => true, "sequence" => index}
            end,
            project: &{&1.knowledge_block_id, &1.sequence},
            expect_set: Enum.with_index(blocks),
            expect_keep: [{hd(blocks), 0}]
          },
          %{
            name: "tool_bindings",
            resource: BotToolBinding,
            parent_key: :bot_id,
            target_key: :tool_instance_id,
            included: "tool-instances",
            targets: [tool_one, tool_two],
            load: [:alias],
            attrs: fn tool_id, index ->
              %{
                "tool_instance_id" => tool_id,
                "alias" => Enum.at(["tool_one", "tool_two"], index),
                "sharing_mode" => "shared",
                "enabled" => index == 0
              }
            end,
            keep_changes: %{"enabled" => false},
            project: &{&1.tool_instance_id, &1.alias, &1.enabled, &1.sequence},
            expect_set: [{tool_one, "tool_one", true, 0}, {tool_two, "tool_two", false, 1}],
            expect_keep: [{tool_one, "tool_one", false, 0}]
          }
        ]
      })
    end

    test "saves the handoff message block reference" do
      %{user: actor} = owner = user_fixture()
      block = create_knowledge_block!(actor, content: "Custom prompt")
      bot = create_bot!(actor)

      response =
        owner
        |> api_patch("/api/ash/bots/#{bot.id}", "bots", bot.id, %{
          "handoff_message_block_id" => block.id
        })
        |> json_response(200)

      assert response["data"]["attributes"]["handoff_message_block_id"] == block.id
      assert Ash.get!(Bot, bot.id, actor: actor).handoff_message_block_id == block.id
    end
  end

  describe "POST /api/ash/bot-tool-bindings" do
    test "accepts an owned tool instance and lists the binding with its tool" do
      %{user: actor} = owner = user_fixture()
      bot = create_bot!(actor)
      tool = create_tool_instance!(actor, alias: "web")

      response =
        owner
        |> api_create("/api/ash/bot-tool-bindings", "bot-tool-bindings", %{
          "bot_id" => bot.id,
          "tool_instance_id" => tool.id,
          "sharing_mode" => "shared",
          "enabled" => true,
          "sequence" => 1
        })
        |> json_response(201)

      binding =
        BotToolBinding |> Ash.get!(response_id(response), actor: actor) |> Ash.load!(:alias)

      assert {binding.bot_id, binding.tool_instance_id, binding.alias} == {bot.id, tool.id, "web"}

      %{"data" => [row]} =
        api_get!(
          owner,
          "/api/ash/bot-tool-bindings?filter[bot_id]=#{bot.id}&sort=sequence" <>
            "&fields[bot-tool-bindings]=alias,enabled,sequence,sharing_mode,tool_instance"
        )

      assert row["attributes"]["tool_instance"]["id"] == tool.id
    end
  end

  describe "POST /api/ash/bots/:id/duplicate" do
    test "copies settings, knowledge block bindings and compatible configuration tags" do
      %{user: actor} = owner = user_fixture()
      [block_a, block_b, handoff_block] = for _ <- 1..3, do: create_knowledge_block!(actor)
      [tag_a, tag_b] = for _ <- 1..2, do: create_configuration_tag!(actor)

      source =
        create_bot!(actor,
          history_mode: :full,
          handoff_message_block_id: handoff_block.id,
          compatible_configuration_tag_bindings: [
            %{llm_configuration_tag_id: tag_a.id},
            %{llm_configuration_tag_id: tag_b.id}
          ],
          knowledge_block_bindings: [
            %{knowledge_block_id: block_a.id, enabled: true},
            %{knowledge_block_id: block_b.id, enabled: false}
          ]
        )

      {copy_id, response} = duplicate!(owner, "/api/ash/bots", "bots", source.id)

      copy = Ash.get!(Bot, copy_id, actor: actor)
      assert copy.handoff_message_block_id == handoff_block.id
      assert copy.history_mode == :full
      assert response["data"]["attributes"]["history_mode"] == "full"

      assert BotKnowledgeBlock
             |> Ash.Query.filter(bot_id == ^copy_id)
             |> Ash.Query.sort(sequence: :asc, id: :asc)
             |> Ash.read!(actor: actor)
             |> Enum.map(&{&1.knowledge_block_id, &1.enabled, &1.sequence}) == [
               {block_a.id, true, 0},
               {block_b.id, false, 1}
             ]

      assert BotCompatibleConfigurationTag
             |> Ash.Query.filter(bot_id == ^copy_id)
             |> Ash.read!(actor: actor)
             |> Enum.map(& &1.llm_configuration_tag_id)
             |> Enum.sort() == Enum.sort([tag_a.id, tag_b.id])
    end

    test "copies tool bindings and user overrides" do
      %{user: actor} = owner = user_fixture()
      source = create_bot!(actor)
      shared_tool = create_tool_instance!(actor, alias: "shared_tool", max_output_tokens: 1000)
      private_tool = create_tool_instance!(actor, alias: "private_tool", max_output_tokens: 2000)
      create_bot_tool_binding!(actor, source, shared_tool, sequence: 2)

      create_bot_tool_binding!(actor, source, private_tool,
        sharing_mode: :per_user,
        enabled: false,
        sequence: 4
      )

      create_user_tool_override!(actor, source, private_tool, sequence: 3)

      {copy_id, _response} = duplicate!(owner, "/api/ash/bots", "bots", source.id)

      assert bot_rows(BotToolBinding, copy_id, actor)
             |> Enum.map(
               &{&1.tool_instance_id, &1.alias, &1.sharing_mode, &1.enabled, &1.sequence}
             ) ==
               [
                 {shared_tool.id, "shared_tool", :shared, true, 2},
                 {private_tool.id, "private_tool", :per_user, false, 4}
               ]

      assert bot_rows(BotUserToolBinding, copy_id, actor)
             |> Enum.map(&{&1.tool_instance_id, &1.alias, &1.enabled, &1.sequence}) ==
               [{private_tool.id, "private_tool", true, 3}]
    end
  end

  describe "DELETE /api/ash/bots/:id" do
    test "deletes the bot with its bindings and clears chat references" do
      %{user: actor} = owner = user_fixture()
      bot = create_bot!(actor)
      block = create_knowledge_block!(actor)
      tool = create_tool_instance!(actor, alias: "web")
      bind_block!(actor, bot, block)
      create_bot_tool_binding!(actor, bot, tool, sequence: 1)
      create_user_tool_override!(actor, bot, tool, sequence: 2)
      chat = create_chat!(actor, bot_id: bot.id)

      delete!(owner, "/api/ash/bots/#{bot.id}")

      assert_not_found(Bot, bot.id, actor: actor)

      for resource <- [BotKnowledgeBlock, BotToolBinding, BotUserToolBinding] do
        refute resource |> Ash.read!(actor: actor) |> Enum.any?(&(&1.bot_id == bot.id))
      end

      assert Ash.get!(Chat, chat.id, actor: actor).bot_id == nil
    end
  end

  describe "image file" do
    image_file_lifecycle_contract(
      resource: Bot,
      collection: "/api/ash/bots",
      type: "bots",
      create: &create_bot!/1
    )
  end

  defp bind_block!(actor, bot, block, attrs \\ []) do
    defaults = %{bot_id: bot.id, knowledge_block_id: block.id, enabled: true, sequence: 0}
    create!(BotKnowledgeBlock, merge_attrs(defaults, attrs), actor)
  end

  defp bind_compatible_tag!(actor, bot, tag) do
    create!(
      BotCompatibleConfigurationTag,
      %{bot_id: bot.id, llm_configuration_tag_id: tag.id},
      actor
    )
  end

  defp create_user_tool_override!(actor, bot, tool, attrs \\ []) do
    defaults = %{bot_id: bot.id, tool_instance_id: tool.id, enabled: true, sequence: 1}
    create!(BotUserToolBinding, merge_attrs(defaults, attrs), actor)
  end

  defp bot_rows(resource, bot_id, actor) do
    resource
    |> Ash.Query.filter(bot_id == ^bot_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load([:alias])
    |> Ash.read!(actor: actor)
  end
end
