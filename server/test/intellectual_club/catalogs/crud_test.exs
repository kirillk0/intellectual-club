defmodule IntellectualClub.Catalogs.CrudTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeTag
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmProvider

  test "knowledge blocks store token_count on create and update" do
    %{user: actor} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Test block",
          version: "v1",
          content: "hello\n//// internal note"
        },
        actor: actor
      )
      |> Ash.create!()

    assert block.token_count == 2

    updated =
      block
      |> Ash.Changeset.for_update(
        :update,
        %{content: "hello world\n//// still ignored"},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert updated.token_count == 4
  end

  test "knowledge block accepts empty version" do
    %{user: actor} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Rules block",
          content: "hello"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert block.version == ""
  end

  test "knowledge block external_id is unique per owner" do
    %{user: actor} = user_fixture()
    %{user: other_actor} = user_fixture()
    external_id = "11111111-1111-4111-8111-111111111111"

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :import_markdown,
        %{
          external_id: external_id,
          name: "Shared source",
          content: "source"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    other_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :import_markdown,
        %{
          external_id: external_id,
          name: "Imported copy",
          content: "copy"
        },
        actor: other_actor
      )
      |> Ash.create!(actor: other_actor)

    assert block.external_id == other_block.external_id
    assert block.owner_id != other_block.owner_id

    assert {:error, _error} =
             KnowledgeBlock
             |> Ash.Changeset.for_create(
               :import_markdown,
               %{
                 external_id: external_id,
                 name: "Duplicate",
                 content: "duplicate"
               },
               actor: actor
             )
             |> Ash.create(actor: actor)
  end

  test "knowledge tags store full_name based on parent" do
    %{user: actor} = user_fixture()

    parent =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Writing"}, actor: actor)
      |> Ash.create!(actor: actor)

    assert parent.full_name == "Writing"

    child =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Style", parent_id: parent.id}, actor: actor)
      |> Ash.create!(actor: actor)

    assert child.full_name == "Writing / Style"

    updated =
      child
      |> Ash.Changeset.for_update(:update, %{name: "Tone"}, actor: actor)
      |> Ash.update!(actor: actor)

    assert updated.full_name == "Writing / Tone"
  end

  test "knowledge tags update descendant full_name when a branch is moved" do
    %{user: actor} = user_fixture()

    source =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Writing"}, actor: actor)
      |> Ash.create!(actor: actor)

    target =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Library"}, actor: actor)
      |> Ash.create!(actor: actor)

    child =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Style", parent_id: source.id}, actor: actor)
      |> Ash.create!(actor: actor)

    grandchild =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Tone", parent_id: child.id}, actor: actor)
      |> Ash.create!(actor: actor)

    moved =
      child
      |> Ash.Changeset.for_update(:update, %{name: child.name, parent_id: target.id},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    reloaded_grandchild = Ash.get!(KnowledgeTag, grandchild.id, actor: actor)

    assert moved.full_name == "Library / Style"
    assert reloaded_grandchild.full_name == "Library / Style / Tone"
  end

  test "bots, providers, configurations, and bindings have basic CRUD" do
    %{user: actor} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "KB",
          version: "v1",
          content: "abc"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Bot",
          first_messages: ["Hi"],
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    binding =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          knowledge_block_id: block.id,
          enabled: true,
          sequence: 1
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert binding.bot_id == bot.id
    assert binding.knowledge_block_id == block.id

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Demo",
          type: :demo,
          base_url: "http://localhost",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    config =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "demo",
          note: "test",
          parameters: %{"temperature" => 0.2},
          enabled: true,
          timeout_seconds: 30,
          context_length: 1024,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    cfg_binding =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: config.id,
          knowledge_block_id: block.id,
          selection: :top,
          enabled: true,
          sequence: 1
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert cfg_binding.llm_configuration_id == config.id
    assert cfg_binding.knowledge_block_id == block.id
    assert cfg_binding.selection == :top

    _ = Ash.destroy!(cfg_binding, actor: actor)
    _ = Ash.destroy!(config, actor: actor)
    _ = Ash.destroy!(provider, actor: actor)
    _ = Ash.destroy!(binding, actor: actor)
    _ = Ash.destroy!(bot, actor: actor)
    _ = Ash.destroy!(block, actor: actor)
  end

  test "llm configuration uses timeout default and keeps context length empty" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Demo provider",
          type: :demo,
          base_url: "http://localhost",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    config =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "demo"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert config.timeout_seconds == 300
    assert is_nil(config.context_length)
    assert config.fix_role_alteration == false
  end

  test "llm provider defaults to openrouter type" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Default provider",
          base_url: "https://openrouter.ai/api/v1",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert provider.type == "openrouter_chat_completion"
  end
end
