defmodule IntellectualClub.Sharing.AccessTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.{Bot, BotCompatibleConfigurationTag, BotKnowledgeBlock}
  alias IntellectualClub.Chat.{Chat, Threads}
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Knowledge.{KnowledgeBlock, KnowledgeBlockShare}

  alias IntellectualClub.Llm.{
    LlmConfiguration,
    LlmConfigurationKnowledgeBlock,
    LlmConfigurationTag,
    LlmConfigurationTagBinding,
    LlmProvider
  }

  alias IntellectualClub.Tools.{
    BotToolBinding,
    BotUserToolBinding,
    ToolFunction,
    ToolInstance,
    ToolInstanceShare
  }

  test "direct shares grant read-only access to knowledge blocks, tools, and tool functions" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{user: outsider} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})
    block = create_knowledge_block!(owner, name: "Direct block", content: "Direct block content")

    tool =
      create_tool_instance!(owner,
        name: "Direct tool",
        alias: "direct_tool",
        max_output_tokens: 2000
      )

    function = create_tool_function!(owner, tool, name: "direct_search", description: "Search")

    block_share =
      KnowledgeBlockShare
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: block.id, user_group_id: group.id},
        actor: owner
      )
      |> Ash.create!()

    tool_share =
      ToolInstanceShare
      |> Ash.Changeset.for_create(
        :create,
        %{tool_instance_id: tool.id, user_group_id: group.id},
        actor: owner
      )
      |> Ash.create!()

    recipient_block =
      Ash.get!(KnowledgeBlock, block.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    recipient_tool =
      Ash.get!(ToolInstance, tool.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    owner_block = Ash.get!(KnowledgeBlock, block.id, actor: owner, load: [:shared_outgoing])
    owner_tool = Ash.get!(ToolInstance, tool.id, actor: owner, load: [:shared_outgoing])

    assert recipient_block.content == "Direct block content"
    assert recipient_block.can_edit == false
    assert recipient_block.shared_incoming == true
    assert recipient_block.shared_outgoing == true
    assert recipient_tool.can_edit == false
    assert recipient_tool.shared_incoming == true
    assert recipient_tool.shared_outgoing == true
    assert owner_block.shared_outgoing == true
    assert owner_tool.shared_outgoing == true
    assert Ash.get!(ToolFunction, function.id, actor: recipient).name == "direct_search"
    assert {:error, _error} = Ash.get(KnowledgeBlock, block.id, actor: outsider)
    assert {:error, _error} = Ash.get(ToolInstance, tool.id, actor: outsider)

    recipient_bot = create_bot!(recipient, name: "Recipient bot")

    direct_tool_binding =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: recipient_bot.id,
          tool_instance_id: tool.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: recipient
      )
      |> Ash.create!()

    assert direct_tool_binding.tool_instance_id == tool.id

    assert {:error, _error} =
             recipient_block
             |> Ash.Changeset.for_update(:update, %{content: "Recipient edit"}, actor: recipient)
             |> Ash.update()

    block_share
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: owner)
    |> Ash.destroy!()

    tool_share
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: owner)
    |> Ash.destroy!()

    assert {:error, _error} = Ash.get(KnowledgeBlock, block.id, actor: recipient)
    assert {:error, _error} = Ash.get(ToolInstance, tool.id, actor: recipient)
    assert {:error, _error} = Ash.get(ToolFunction, function.id, actor: recipient)
  end

  test "tools visible only through shared bots cannot be rebound elsewhere" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})
    shared_bot = create_bot!(owner, name: "Shared source bot")
    recipient_bot = create_bot!(recipient, name: "Recipient destination bot")

    tool =
      create_tool_instance!(owner,
        name: "Transitive tool",
        alias: "transitive_tool",
        max_output_tokens: 2000
      )

    _binding =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: shared_bot.id,
          tool_instance_id: tool.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    share_bot!(owner, shared_bot, group)
    assert Ash.get!(ToolInstance, tool.id, actor: recipient).id == tool.id

    assert {:error, _error} =
             BotToolBinding
             |> Ash.Changeset.for_create(
               :create,
               %{
                 bot_id: recipient_bot.id,
                 tool_instance_id: tool.id,
                 sharing_mode: :shared,
                 enabled: true,
                 sequence: 10
               },
               actor: recipient
             )
             |> Ash.create()
  end

  test "shared recipients get transitive read access but not write access" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, name: "Shared bot")
    provider = create_provider!(owner, name: "Shared provider")
    configuration = create_configuration!(owner, provider: provider, model_name: "shared-model")
    bot_block = create_knowledge_block!(owner, name: "Bot block", content: "Bot block content")

    config_block =
      create_knowledge_block!(owner, name: "Config block", content: "Config block content")

    tool =
      create_tool_instance!(owner,
        name: "Shared MCP tool",
        alias: "team_web",
        max_output_tokens: 2000
      )

    tool_function = create_tool_function!(owner, tool, name: "search", description: "Search")

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: bot_block.id, enabled: true, sequence: 10},
        actor: owner
      )
      |> Ash.create!()

    _ =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: config_block.id,
          enabled: true,
          sequence: 20
        },
        actor: owner
      )
      |> Ash.create!()

    shared_binding =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: tool.id,
          alias: "team_web",
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)

    owner_view =
      Ash.get!(Bot, bot.id,
        actor: owner,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    recipient_view =
      Ash.get!(Bot, bot.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    shared_configuration =
      Ash.get!(LlmConfiguration, configuration.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    shared_bot_block =
      Ash.get!(KnowledgeBlock, bot_block.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    shared_config_block =
      Ash.get!(KnowledgeBlock, config_block.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    shared_provider =
      Ash.get!(LlmProvider, provider.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    shared_tool =
      Ash.get!(ToolInstance, tool.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    shared_function = Ash.get!(ToolFunction, tool_function.id, actor: recipient)

    shared_bot_binding =
      BotToolBinding
      |> Ash.get!(shared_binding.id, actor: recipient)
      |> Ash.load!(:alias, actor: recipient)

    assert owner_view.can_edit == true
    assert owner_view.shared_incoming == false
    assert owner_view.shared_outgoing == true

    assert recipient_view.can_edit == false
    assert recipient_view.shared_incoming == true
    assert recipient_view.shared_outgoing == true

    assert shared_configuration.can_edit == false
    assert shared_configuration.shared_incoming == true
    assert shared_configuration.shared_outgoing == true

    assert shared_bot_block.can_edit == false
    assert shared_bot_block.shared_incoming == true
    assert shared_bot_block.shared_outgoing == true

    assert shared_config_block.can_edit == false
    assert shared_config_block.shared_incoming == true
    assert shared_config_block.shared_outgoing == true

    assert shared_provider.can_edit == false
    assert shared_provider.shared_incoming == true
    assert shared_provider.shared_outgoing == true

    assert shared_tool.can_edit == false
    assert shared_tool.shared_incoming == true
    assert shared_tool.shared_outgoing == true

    assert shared_function.name == "search"
    assert shared_bot_binding.alias == "team_web"

    assert {:error, _} =
             recipient_view
             |> Ash.Changeset.for_update(:update, %{name: "Recipient edit"}, actor: recipient)
             |> Ash.update()

    assert {:error, _} =
             shared_configuration
             |> Ash.Changeset.for_update(:update, %{model_name: "recipient-model"},
               actor: recipient
             )
             |> Ash.update()

    assert {:error, _} =
             shared_bot_block
             |> Ash.Changeset.for_update(:update, %{content: "mutated"}, actor: recipient)
             |> Ash.update()

    assert {:error, _} =
             shared_provider
             |> Ash.Changeset.for_update(:update, %{name: "Recipient provider"}, actor: recipient)
             |> Ash.update()

    assert {:error, _} =
             shared_tool
             |> Ash.Changeset.for_update(:update, %{name: "Recipient tool"}, actor: recipient)
             |> Ash.update()

    assert {:error, _} =
             shared_function
             |> Ash.Changeset.for_update(:update, %{description: "recipient"}, actor: recipient)
             |> Ash.update()
  end

  test "per-user tool bindings expose only alias contracts and keep owner resources private" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, name: "Per-user bot")

    owner_tool =
      create_tool_instance!(owner,
        name: "Owner private tool",
        alias: "personal_web",
        max_output_tokens: 2000
      )

    per_user_binding =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: owner_tool.id,
          sharing_mode: :per_user,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    share_bot!(owner, bot, group)

    recipient_contract =
      BotToolBinding
      |> Ash.get!(per_user_binding.id, actor: recipient)
      |> Ash.load!(:alias, actor: recipient)

    assert recipient_contract.alias == "personal_web"
    assert recipient_contract.sharing_mode == :per_user
    assert {:error, _} = Ash.get(ToolInstance, owner_tool.id, actor: recipient)

    recipient_tool =
      create_tool_instance!(recipient,
        name: "Recipient own tool",
        alias: "personal_web",
        max_output_tokens: 2000
      )

    recipient_block =
      create_knowledge_block!(recipient,
        name: "Recipient block",
        content: "Recipient block content"
      )

    user_binding =
      BotUserToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: recipient_tool.id,
          enabled: true,
          sequence: 10
        },
        actor: recipient
      )
      |> Ash.create!()
      |> then(&Ash.get!(BotUserToolBinding, &1.id, actor: recipient))
      |> Ash.load!(:alias, actor: recipient)

    assert user_binding.alias == "personal_web"
    assert user_binding.owner_id == recipient.id

    assert {:error, _} =
             BotToolBinding
             |> Ash.Changeset.for_create(
               :create,
               %{
                 bot_id: bot.id,
                 tool_instance_id: recipient_tool.id,
                 alias: "illegal",
                 sharing_mode: :shared,
                 enabled: true,
                 sequence: 20
               },
               actor: recipient
             )
             |> Ash.create()

    assert {:error, _} =
             BotKnowledgeBlock
             |> Ash.Changeset.for_create(
               :create,
               %{
                 bot_id: bot.id,
                 knowledge_block_id: recipient_block.id,
                 enabled: true,
                 sequence: 20
               },
               actor: recipient
             )
             |> Ash.create()
  end

  test "private resources do not become shared_outgoing because unrelated records are shared" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    shared_bot = create_bot!(owner, name: "Shared bot")
    private_bot = create_bot!(owner, name: "Private bot")

    shared_provider = create_provider!(owner, name: "Shared provider")
    private_provider = create_provider!(owner, name: "Private provider")

    shared_configuration =
      create_configuration!(owner, provider: shared_provider, model_name: "shared-model")

    private_configuration =
      create_configuration!(owner, provider: private_provider, model_name: "private-model")

    shared_tool =
      create_tool_instance!(owner, name: "Shared tool", alias: nil, max_output_tokens: 2000)

    private_tool =
      create_tool_instance!(owner, name: "Private tool", alias: nil, max_output_tokens: 2000)

    private_bot_block =
      create_knowledge_block!(owner,
        name: "Private bot block",
        content: "Private bot block content"
      )

    private_config_block =
      create_knowledge_block!(owner,
        name: "Private config block",
        content: "Private config block content"
      )

    _ =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: shared_bot.id,
          tool_instance_id: shared_tool.id,
          alias: "shared_tool",
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    _ =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: private_bot.id,
          tool_instance_id: private_tool.id,
          alias: "private_tool",
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: private_bot.id,
          knowledge_block_id: private_bot_block.id,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    _ =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: private_configuration.id,
          knowledge_block_id: private_config_block.id,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    share_bot!(owner, shared_bot, group)
    share_configuration!(owner, shared_configuration, group)

    shared_tool_view =
      Ash.get!(ToolInstance, shared_tool.id, actor: owner, load: [:shared_outgoing])

    private_tool_view =
      Ash.get!(ToolInstance, private_tool.id, actor: owner, load: [:shared_outgoing])

    shared_provider_view =
      Ash.get!(LlmProvider, shared_provider.id, actor: owner, load: [:shared_outgoing])

    private_provider_view =
      Ash.get!(LlmProvider, private_provider.id, actor: owner, load: [:shared_outgoing])

    private_bot_block_view =
      Ash.get!(KnowledgeBlock, private_bot_block.id, actor: owner, load: [:shared_outgoing])

    private_config_block_view =
      Ash.get!(KnowledgeBlock, private_config_block.id, actor: owner, load: [:shared_outgoing])

    assert shared_tool_view.shared_outgoing == true
    assert private_tool_view.shared_outgoing == false

    assert shared_provider_view.shared_outgoing == true
    assert private_provider_view.shared_outgoing == false

    assert private_bot_block_view.shared_outgoing == false
    assert private_config_block_view.shared_outgoing == false
  end

  test "shared recipients can read nested configuration tags through shared bots and configurations" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, name: "Tagged shared bot")
    provider = create_provider!(owner, name: "Tagged provider")
    configuration = create_configuration!(owner, provider: provider, model_name: "tagged-model")
    tag = create_configuration_tag!(owner, name: "shared-tag")

    configuration_binding =
      LlmConfigurationTagBinding
      |> Ash.Changeset.for_create(
        :create,
        %{llm_configuration_id: configuration.id, llm_configuration_tag_id: tag.id},
        actor: owner
      )
      |> Ash.create!()

    bot_binding =
      BotCompatibleConfigurationTag
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, llm_configuration_tag_id: tag.id},
        actor: owner
      )
      |> Ash.create!()

    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)

    shared_tag = Ash.get!(LlmConfigurationTag, tag.id, actor: recipient)

    shared_configuration_binding =
      Ash.get!(LlmConfigurationTagBinding, configuration_binding.id,
        actor: recipient,
        load: [:tag_name]
      )

    shared_bot_binding =
      Ash.get!(BotCompatibleConfigurationTag, bot_binding.id,
        actor: recipient,
        load: [:tag_name]
      )

    assert shared_tag.name == "shared-tag"
    assert shared_configuration_binding.tag_name == "shared-tag"
    assert shared_bot_binding.tag_name == "shared-tag"
  end

  test "generation context works for shared bots and configurations with per-user overrides" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, name: "Generation bot")
    provider = create_provider!(owner, name: "Demo provider")
    configuration = create_configuration!(owner, provider: provider, model_name: "demo-model")
    bot_block = create_knowledge_block!(owner, name: "Bot prompt", content: "Bot prompt content")

    config_block =
      create_knowledge_block!(owner, name: "Config prompt", content: "Config prompt content")

    shared_tool = create_fixed_tool!(owner, "Shared search tool", "team_web")
    per_user_tool = create_fixed_tool!(owner, "Per-user search tool", "personal_web")

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: bot_block.id, enabled: true, sequence: 10},
        actor: owner
      )
      |> Ash.create!()

    _ =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: config_block.id,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    _ =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: shared_tool.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: owner
      )
      |> Ash.create!()

    _ =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: per_user_tool.id,
          sharing_mode: :per_user,
          enabled: true,
          sequence: 20
        },
        actor: owner
      )
      |> Ash.create!()

    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)

    chat_without_override =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          bot_id: bot.id,
          llm_configuration_id: configuration.id
        },
        actor: recipient
      )
      |> Ash.create!(actor: recipient)

    {:ok, _} =
      Threads.add_message_to_end(chat_without_override, :user, "hello", actor: recipient)

    context_without_override =
      Context.build!(chat_without_override.id, actor: recipient, chunk_delay_ms: 0)

    assert context_without_override.provider_id == provider.id
    assert String.contains?(context_without_override.system_prompt, "Bot prompt content")
    assert String.contains?(context_without_override.system_prompt, "Config prompt content")

    refute Enum.any?(context_without_override.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "personal_web__web_search"
           end)

    assert Enum.any?(context_without_override.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "team_web__web_search"
           end)

    recipient_tool = create_fixed_tool!(recipient, "Recipient override tool", "personal_web")

    _ =
      BotUserToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: recipient_tool.id,
          enabled: true,
          sequence: 20
        },
        actor: recipient
      )
      |> Ash.create!()

    chat_with_override =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          bot_id: bot.id,
          llm_configuration_id: configuration.id
        },
        actor: recipient
      )
      |> Ash.create!(actor: recipient)

    {:ok, _} =
      Threads.add_message_to_end(chat_with_override, :user, "hello again", actor: recipient)

    context_with_override =
      Context.build!(chat_with_override.id, actor: recipient, chunk_delay_ms: 0)

    assert context_with_override.tool_instances_by_alias["team_web"].id == shared_tool.id
    assert context_with_override.tool_instances_by_alias["personal_web"].id == recipient_tool.id

    assert Enum.any?(context_with_override.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "personal_web__web_search"
           end)
  end

  defp create_fixed_tool!(actor, name, alias_value) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-web-search",
        name: name,
        alias: alias_value,
        config: %{},
        secrets: %{"token" => "token"},
        max_output_tokens: 2000
      },
      actor: actor
    )
    |> Ash.create!()
  end
end
