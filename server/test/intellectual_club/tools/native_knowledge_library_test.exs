defmodule IntellectualClub.Tools.NativeKnowledgeLibraryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotShare
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockTag
  alias IntellectualClub.Knowledge.KnowledgeTag
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.BindingResolver
  alias IntellectualClub.Tools.Drivers.NativeKnowledgeLibrary
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "lists, reads, and searches owner blocks from a configured tag subtree" do
    %{user: owner} = user_fixture()

    root = create_tag!(owner, "Library")
    child = create_tag!(owner, "Child", root.id)
    other = create_tag!(owner, "Other")

    root_block =
      create_block!(owner, "Root Block", "v1", "Visible root text\n//// hidden root note")

    child_block = create_block!(owner, "Child Block", "v2", "Visible child text")
    other_block = create_block!(owner, "Other Block", "v3", "Other text")
    duplicate_a = create_block!(owner, "Duplicate", "a", "First duplicate text")
    duplicate_b = create_block!(owner, "Duplicate", "b", "Second duplicate text")

    attach_tag!(owner, root_block, root)
    attach_tag!(owner, child_block, child)
    attach_tag!(owner, other_block, other)
    attach_tag!(owner, duplicate_a, root)
    attach_tag!(owner, duplicate_b, root)

    tool = create_library_tool!(owner, root.id, %{"chunk_size_tokens" => 4})

    assert {:ok, {list_text, list_raw}} =
             NativeKnowledgeLibrary.execute(tool, "list_blocks", %{"max_results" => 10})

    assert list_text =~ "Root Block"
    assert list_text =~ "Child Block"
    refute list_text =~ "Other Block"

    assert Enum.map(list_raw["blocks"], & &1["block_id"]) |> Enum.sort() ==
             Enum.sort([child_block.id, duplicate_a.id, duplicate_b.id, root_block.id])

    assert {:ok, {page_zero_text, page_zero_raw}} =
             NativeKnowledgeLibrary.execute(tool, "read_block", %{
               "block_id" => root_block.id,
               "page" => 0
             })

    assert page_zero_raw["page"] == 1
    assert page_zero_text =~ "Visible root text"
    refute page_zero_text =~ "hidden root note"

    assert {:error, "Page out of range:" <> _} =
             NativeKnowledgeLibrary.execute(tool, "read_block", %{
               "block_id" => root_block.id,
               "page" => 999
             })

    assert {:error, "Multiple blocks have this name. Use `block_id` from list_blocks."} =
             NativeKnowledgeLibrary.execute(tool, "read_block", %{"block_name" => "Duplicate"})

    assert {:ok, {search_text, search_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "Visible",
               "max_snippets" => 1
             })

    assert search_text =~ "Matches: 1"
    assert length(search_raw["snippets"]) == 1

    assert {:ok, {hidden_search_text, hidden_search_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "hidden root note",
               "max_snippets" => 5
             })

    assert hidden_search_text =~ "Matches: none"
    assert hidden_search_raw["snippets"] == []

    context =
      NativeKnowledgeLibrary.instance_prompt_context(%{
        tool
        | config: Map.put(tool.config, "max_context_blocks", 1)
      })

    assert context =~ "Knowledge tag: Library"
    assert context =~ "The list is truncated"
  end

  test "search distributes limited snippets across matching blocks before filling extras" do
    %{user: owner} = user_fixture()

    tag = create_tag!(owner, "Distributed Search Library")

    alpha_block =
      create_block!(
        owner,
        "Alpha Block",
        "v1",
        "needle alpha first. #{String.duplicate("padding ", 16)} needle alpha second."
      )

    beta_block = create_block!(owner, "Beta Block", "v1", "needle beta only.")
    gamma_block = create_block!(owner, "Gamma Block", "v1", "needle gamma only.")

    attach_tag!(owner, alpha_block, tag)
    attach_tag!(owner, beta_block, tag)
    attach_tag!(owner, gamma_block, tag)

    tool = create_library_tool!(owner, tag.id)

    assert {:ok, {_search_text, limited_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "needle",
               "max_snippets" => 2,
               "snippet_len_chars" => 40
             })

    limited_block_ids = Enum.map(limited_raw["snippets"], & &1["block_id"])
    assert length(limited_block_ids) == 2
    assert Enum.uniq(limited_block_ids) == limited_block_ids
    assert limited_block_ids == [alpha_block.id, beta_block.id]

    assert {:ok, {_search_text, filled_raw}} =
             NativeKnowledgeLibrary.execute(tool, "search_blocks", %{
               "regex" => "needle",
               "max_snippets" => 4,
               "snippet_len_chars" => 40
             })

    assert Enum.map(filled_raw["snippets"], & &1["block_id"]) == [
             alpha_block.id,
             beta_block.id,
             gamma_block.id,
             alpha_block.id
           ]
  end

  test "shared recipients execute owner library without direct block access" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    tag = create_tag!(owner, "Shared Library")
    block = create_block!(owner, "Shared Block", "v1", "Owner-only library text")
    attach_tag!(owner, block, tag)

    tool = create_library_tool!(owner, tag.id)
    bot = create_bot!(owner, "Shared library bot")
    bind_tool!(owner, bot, tool)
    share_bot!(owner, bot, group)

    assert {:error, _error} = Ash.get(KnowledgeBlock, block.id, actor: recipient)

    resolution = BindingResolver.resolve_for_chat(%{id: -1, bot_id: bot.id}, recipient)
    assert resolution.tool_instances_by_alias["library"].owner_id == owner.id

    result =
      Executor.execute_llm_tool(
        resolution.tool_instances_by_alias,
        "library__read_block",
        %{"block_id" => block.id},
        nil
      )

    assert result.raw["isError"] != true
    assert result.text =~ "Owner-only library text"
  end

  test "duplication preserves owner config and clears shared recipient tag config" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    tag = create_tag!(owner, "Source Library")
    tool = create_library_tool!(owner, tag.id)

    owner_copy =
      ToolInstance
      |> Ash.Changeset.for_create(:duplicate, %{id: tool.id}, actor: owner)
      |> Ash.create!()

    assert owner_copy.config["knowledge_tag_id"] == tag.id

    bot = create_bot!(owner, "Shared duplicate bot")
    bind_tool!(owner, bot, tool)
    share_bot!(owner, bot, group)

    recipient_copy =
      ToolInstance
      |> Ash.Changeset.for_create(:duplicate, %{id: tool.id}, actor: recipient)
      |> Ash.create!()

    refute Map.has_key?(recipient_copy.config, "knowledge_tag_id")
    refute Map.has_key?(recipient_copy.config, :knowledge_tag_id)
  end

  test "config validation rejects tags outside the tool owner authority" do
    %{user: owner} = user_fixture()
    %{user: other_owner} = user_fixture()

    foreign_tag = create_tag!(other_owner, "Foreign Library")

    assert {:error, error} =
             ToolInstance
             |> Ash.Changeset.for_create(
               :create,
               %{
                 type: "native-knowledge-library",
                 name: "Invalid Library",
                 alias: "invalid_library",
                 config: %{"knowledge_tag_id" => foreign_tag.id},
                 secrets: %{}
               },
               actor: owner
             )
             |> Ash.create()

    assert Exception.message(error) =~ "Knowledge tag is not available."
  end

  defp create_tag!(actor, name, parent_id \\ nil) do
    KnowledgeTag
    |> Ash.Changeset.for_create(:create, %{name: name, parent_id: parent_id}, actor: actor)
    |> Ash.create!()
  end

  defp create_block!(actor, name, version, content) do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, version: version, content: content},
      actor: actor
    )
    |> Ash.create!()
  end

  defp attach_tag!(actor, block, tag) do
    KnowledgeBlockTag
    |> Ash.Changeset.for_create(
      :create,
      %{knowledge_block_id: block.id, knowledge_tag_id: tag.id},
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_library_tool!(actor, tag_id, config_overrides \\ %{}) do
    config = Map.merge(%{"knowledge_tag_id" => tag_id}, config_overrides)

    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-knowledge-library",
        name: "Knowledge Library",
        alias: "library",
        config: config,
        secrets: %{}
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_bot!(actor, name) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        variables: %{},
        max_tool_rounds: 10,
        context_soft_limit_percent: 80,
        history_mode: :chat
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp bind_tool!(actor, bot, tool) do
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
    |> Ash.create!()
  end

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(:create, %{bot_id: bot.id, user_group_id: group.id}, actor: actor)
    |> Ash.create!()
  end
end
