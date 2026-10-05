defmodule IntellectualClub.Catalogs.CrudTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeTag
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmProvider

  require Ash.Query

  describe "knowledge blocks" do
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
  end

  describe "knowledge tags" do
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

    test "rejects moving a tag under its own descendant" do
      %{user: actor} = user_fixture()

      root =
        KnowledgeTag
        |> Ash.Changeset.for_create(:create, %{name: "Root", parent_id: nil}, actor: actor)
        |> Ash.create!(actor: actor)

      child =
        KnowledgeTag
        |> Ash.Changeset.for_create(:create, %{name: "Child", parent_id: root.id}, actor: actor)
        |> Ash.create!(actor: actor)

      grandchild =
        KnowledgeTag
        |> Ash.Changeset.for_create(:create, %{name: "Grandchild", parent_id: child.id},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      root
      |> Ash.Changeset.for_update(:update, %{parent_id: grandchild.id}, actor: actor)
      |> Ash.update(actor: actor)
      |> case do
        {:ok, _tag} ->
          flunk("expected cycle validation to fail")

        {:error, %Ash.Error.Invalid{errors: errors}} ->
          assert Enum.any?(errors, fn
                   %Ash.Error.Changes.InvalidAttribute{field: :parent_id} -> true
                   _ -> false
                 end)
      end
    end
  end

  describe "bots, providers and configurations" do
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
  end

  describe "Bot.sort_activity_at" do
    test "uses the latest message timestamp across actor chats for the bot" do
      %{user: actor} = user_fixture()

      bot = create_bot!(actor, history_mode: :agent, name: "Sort bot")
      chat_one = create_chat!(actor, bot_id: bot.id)
      chat_two = create_chat!(actor, bot_id: bot.id)

      {:ok, first_message} = Threads.add_message_to_end(chat_one, :user, "First", actor: actor)

      {:ok, second_message} =
        Threads.add_message_to_end(chat_two, :assistant, "Second", actor: actor)

      loaded_bot = load_bot_with_sort_activity!(bot.id, actor)

      expected_latest =
        [first_message.created_at, second_message.created_at]
        |> Enum.max_by(&datetime_unix_microseconds/1)

      assert %DateTime{} = loaded_bot.sort_activity_at
      assert datetime_iso(loaded_bot.sort_activity_at) == datetime_iso(expected_latest)
    end

    test "falls back to bot update timestamp when messages are absent" do
      %{user: actor} = user_fixture()
      bot = create_bot!(actor, history_mode: :agent, name: "Fallback bot")

      loaded_bot = load_bot_with_sort_activity!(bot.id, actor)

      assert %DateTime{} = loaded_bot.sort_activity_at
      assert datetime_iso(loaded_bot.sort_activity_at) == datetime_iso(bot.updated_at)
    end

    test "uses only the current actor chats for shared bot activity" do
      %{user: owner} = user_fixture()
      %{user: recipient} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})

      bot = create_bot!(owner, history_mode: :agent, name: "Shared sort bot")
      owner_chat = create_chat!(owner, bot_id: bot.id)

      {:ok, _owner_message} =
        Threads.add_message_to_end(owner_chat, :user, "Owner activity", actor: owner)

      share_bot!(owner, bot, group)

      shared_bot_without_recipient_chats = load_bot_with_sort_activity!(bot.id, recipient)

      assert datetime_iso(shared_bot_without_recipient_chats.sort_activity_at) ==
               datetime_iso(bot.updated_at)

      recipient_chat = create_chat!(recipient, bot_id: bot.id)

      {:ok, recipient_message} =
        Threads.add_message_to_end(recipient_chat, :user, "Recipient activity", actor: recipient)

      shared_bot_with_recipient_chat = load_bot_with_sort_activity!(bot.id, recipient)

      assert datetime_iso(shared_bot_with_recipient_chat.sort_activity_at) ==
               datetime_iso(recipient_message.created_at)
    end
  end

  defp load_bot_with_sort_activity!(bot_id, actor) do
    Bot
    |> Ash.Query.filter(id == ^bot_id)
    |> Ash.Query.load(:sort_activity_at)
    |> Ash.read!(actor: actor)
    |> List.first()
  end

  defp datetime_unix_microseconds(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp datetime_unix_microseconds(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp datetime_unix_microseconds(_value), do: 0

  defp datetime_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp datetime_iso(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp datetime_iso(nil), do: nil
  defp datetime_iso(_value), do: nil
end
