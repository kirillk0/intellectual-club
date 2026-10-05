defmodule IntellectualClubWeb.AshJsonApi.KnowledgeBlocksTest do
  @moduledoc """
  Knowledge blocks, their tag bindings and user block settings through the
  AshJsonApi endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  import IntellectualClubWeb.AshJsonApiContract

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.{Bot, BotKnowledgeBlock}
  alias IntellectualClub.Chat.{Chat, ChatKnowledgeBlock}
  alias IntellectualClub.Knowledge.{KnowledgeBlock, KnowledgeBlockTag}

  require Ash.Query

  describe "GET /api/ash/knowledge-blocks" do
    test "filters by tag subtree and by missing tags" do
      %{user: actor} = owner = user_fixture()
      root = create_knowledge_tag!(actor)
      child = create_knowledge_tag!(actor, parent_id: root.id)
      grandchild = create_knowledge_tag!(actor, parent_id: child.id)
      other = create_knowledge_tag!(actor)

      [block_root, block_child, block_grandchild, block_other] =
        for tag <- [root, child, grandchild, other] do
          block = create_knowledge_block!(actor)
          tag_block!(actor, block, tag)
          block.id
        end

      untagged = create_knowledge_block!(actor).id

      for {query, expected} <- [
            {"tag_id=#{root.id}", [block_root, block_child, block_grandchild]},
            {"tag_id=#{child.id}", [block_child, block_grandchild]},
            {"tag_id=#{grandchild.id}", [block_grandchild]},
            {"tag_id=#{other.id}", [block_other]},
            {"no_tags=true", [untagged]}
          ] do
        response = api_get!(owner, "/api/ash/knowledge-blocks?#{query}&sort=name")
        assert ids_from_data(response) == Enum.sort(expected), query
      end
    end
  end

  describe "PATCH /api/ash/knowledge-blocks/:id" do
    test "manages tag bindings" do
      %{user: actor} = owner = user_fixture()
      block = create_knowledge_block!(actor)
      tags = for _ <- 1..2, do: create_knowledge_tag!(actor).id

      assert_manages_bindings(owner, %{
        collection: "/api/ash/knowledge-blocks",
        type: "knowledge-blocks",
        id: block.id,
        include: "tag_bindings.knowledge_tag",
        relationships: [
          %{
            name: "tag_bindings",
            resource: KnowledgeBlockTag,
            parent_key: :knowledge_block_id,
            target_key: :knowledge_tag_id,
            included: "knowledge-tags",
            targets: tags,
            attrs: fn tag_id, _index -> %{"knowledge_tag_id" => tag_id} end
          }
        ]
      })
    end
  end

  describe "GET /api/ash/knowledge-block-tags" do
    test "filters by block, includes tags and sorts" do
      %{user: actor} = owner = user_fixture()
      block = create_knowledge_block!(actor)
      tags = for _ <- 1..2, do: create_knowledge_tag!(actor)
      bindings = for tag <- tags, do: tag_block!(actor, block, tag)
      _foreign_binding = tag_block!(actor, create_knowledge_block!(actor), hd(tags))

      response =
        api_get!(
          owner,
          "/api/ash/knowledge-block-tags?filter[knowledge_block_id]=#{block.id}" <>
            "&include=knowledge_tag&sort=created_at"
        )

      assert ids_from_data(response) == bindings |> Enum.map(& &1.id) |> Enum.sort()

      assert ids_from_included(response, "knowledge-tags") ==
               tags |> Enum.map(& &1.id) |> Enum.sort()
    end
  end

  describe "POST /api/ash/knowledge-blocks/:id/duplicate" do
    test "copies the block with a version suffix and its tag bindings" do
      %{user: actor} = owner = user_fixture()
      tags = for _ <- 1..2, do: create_knowledge_tag!(actor)
      source = create_knowledge_block!(actor, content: "Important content")
      for tag <- tags, do: tag_block!(actor, source, tag)

      {copy_id, _response} =
        duplicate!(owner, "/api/ash/knowledge-blocks", "knowledge-blocks", source.id)

      copy = Ash.get!(KnowledgeBlock, copy_id, actor: actor)
      assert copy.id != source.id
      assert copy.owner_id == source.owner_id
      assert copy.name == source.name
      assert copy.version == "v1 copy"
      assert copy.content == source.content
      assert copy.token_count == source.token_count
      assert block_tag_ids(copy_id, actor) == tags |> Enum.map(& &1.id) |> Enum.sort()
    end
  end

  describe "DELETE /api/ash/knowledge-blocks/:id" do
    test "deletes the block and its bindings and clears the bot handoff reference" do
      %{user: actor} = owner = user_fixture()
      block = create_knowledge_block!(actor)
      tag_block!(actor, block, create_knowledge_tag!(actor))
      bot = create_bot!(actor, handoff_message_block_id: block.id)
      create!(BotKnowledgeBlock, %{bot_id: bot.id, knowledge_block_id: block.id}, actor)
      chat = create_chat!(actor)
      create_chat_block_binding!(actor, chat, block)

      delete!(owner, "/api/ash/knowledge-blocks/#{block.id}")

      assert_not_found(KnowledgeBlock, block.id, actor: actor)
      assert block_tag_ids(block.id, actor) == []

      for resource <- [BotKnowledgeBlock, ChatKnowledgeBlock] do
        assert resource
               |> Ash.Query.filter(knowledge_block_id == ^block.id)
               |> Ash.read!(actor: actor) == []
      end

      assert Ash.get!(Bot, bot.id, actor: actor).handoff_message_block_id == nil
      assert Ash.get!(Chat, chat.id, actor: actor).id == chat.id
    end
  end

  describe "image file" do
    image_file_lifecycle_contract(
      resource: KnowledgeBlock,
      collection: "/api/ash/knowledge-blocks",
      type: "knowledge-blocks",
      create: &create_knowledge_block!/1
    )
  end

  describe "/api/ash/user-knowledge-blocks" do
    test "creates, lists and deletes the current user's block settings" do
      %{user: actor} = owner = user_fixture()
      block = create_knowledge_block!(actor)

      created_id =
        owner
        |> api_create("/api/ash/user-knowledge-blocks", "user-knowledge-blocks", %{
          "knowledge_block_id" => block.id,
          "enabled" => true,
          "sequence" => 1
        })
        |> json_response(201)
        |> response_id()

      assert created_id in ids_from_data(api_get!(owner, "/api/ash/user-knowledge-blocks"))

      delete!(owner, "/api/ash/user-knowledge-blocks/#{created_id}")

      assert UserKnowledgeBlock
             |> Ash.Query.filter(owner_id == ^actor.id)
             |> Ash.read!(actor: actor) == []
    end
  end

  defp tag_block!(actor, block, tag) do
    create!(KnowledgeBlockTag, %{knowledge_block_id: block.id, knowledge_tag_id: tag.id}, actor)
  end

  defp block_tag_ids(block_id, actor) do
    KnowledgeBlockTag
    |> Ash.Query.filter(knowledge_block_id == ^block_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.knowledge_tag_id)
    |> Enum.sort()
  end
end
