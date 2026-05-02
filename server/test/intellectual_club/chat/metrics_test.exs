defmodule IntellectualClub.Chat.MetricsTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.Metrics
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmProvider

  test "returns prompt and history token counters for active branch" do
    %{user: actor} = user_fixture()

    bot_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Bot block", version: "v1", content: "bot block content"},
        actor: actor
      )
      |> Ash.create!()

    chat_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Chat block", version: "v1", content: "chat block content"},
        actor: actor
      )
      |> Ash.create!()

    config_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config block", version: "v1", content: "config block content"},
        actor: actor
      )
      |> Ash.create!()

    user_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "User block", version: "v1", content: "user block content"},
        actor: actor
      )
      |> Ash.create!()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Metrics bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: bot_block.id, enabled: true, sequence: 10},
        actor: actor
      )
      |> Ash.create!()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Demo", type: :demo, base_url: nil, api_key: nil},
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "demo",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 1024,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
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
          sequence: 30
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Metrics chat",
          bot_id: bot.id,
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _ =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, knowledge_block_id: chat_block.id, enabled: true, sequence: 20},
        actor: actor
      )
      |> Ash.create!()

    _ =
      UserKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: user_block.id, enabled: true, sequence: 40},
        actor: actor
      )
      |> Ash.create!()

    {:ok, root} = Threads.add_message(chat, :user, "root", actor: actor, parent_id: nil)

    {:ok, _a1} =
      Threads.add_message(chat, :assistant, "branch A", actor: actor, parent_id: root.id)

    {:ok, b1} =
      Threads.add_message(chat, :assistant, "branch B", actor: actor, parent_id: root.id)

    # Keep B active to verify history counters use active branch only.
    {:ok, _branch} = Threads.activate_branch(chat.id, b1.id, actor)

    counters = Metrics.counters(chat.id, actor)

    expected_prompt_tokens =
      bot_block.token_count + chat_block.token_count + config_block.token_count +
        user_block.token_count

    expected_history_tokens = root.token_count + b1.token_count

    assert counters.prompt_token_count == expected_prompt_tokens
    assert counters.history_token_count == expected_history_tokens
    assert counters.history_message_count == 2
    assert counters.total_token_count == expected_prompt_tokens + expected_history_tokens
  end
end
