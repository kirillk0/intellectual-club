defmodule IntellectualClub.Chat.ChatSharingTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatKnowledgeBlock,
    ChatMessage,
    ChatMessageContent,
    Continuation,
    Threads
  }

  alias IntellectualClub.Files
  alias IntellectualClub.Llm.LlmConfigurationShare
  alias IntellectualClub.Sharing
  alias IntellectualClub.Tools.ChatToolBinding

  require Ash.Query

  test "owner can share a chat only when bot and configuration are shared with the group" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, max_tool_rounds: 300)
    configuration = create_configuration!(owner, note: "shared")
    chat = create_chat!(owner, bot_id: bot.id, llm_configuration_id: configuration.id)
    {:ok, message} = Threads.add_message_to_end(chat, :user, "hello", actor: owner)

    share_bot!(owner, bot, group)

    assert {:error, {:validation, message_text}} =
             Sharing.replace_chat_share_state(chat.id, [group.id], owner)

    assert message_text =~ "bot and configuration"

    share_configuration!(owner, configuration, group)

    assert {:ok, state} = Sharing.replace_chat_share_state(chat.id, [group.id], owner)
    assert state.group_ids == [group.id]

    owner_view =
      Ash.get!(Chat, chat.id,
        actor: owner,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    recipient_view =
      Ash.get!(Chat, chat.id,
        actor: recipient,
        load: [:can_edit, :shared_incoming, :shared_outgoing]
      )

    assert owner_view.can_edit == true
    assert owner_view.shared_outgoing == true
    assert recipient_view.can_edit == false
    assert recipient_view.shared_incoming == true

    message_id = message.id

    assert {:ok, %ChatMessage{id: ^message_id}} =
             Ash.get(ChatMessage, message_id, actor: recipient)

    assert {:error, _} =
             recipient_view
             |> Ash.Changeset.for_update(:update, %{note: "recipient edit"}, actor: recipient)
             |> Ash.update()

    LlmConfigurationShare
    |> Ash.Query.filter(llm_configuration_id == ^configuration.id and user_group_id == ^group.id)
    |> Ash.read_one!(actor: owner)
    |> Ash.destroy!(actor: owner)

    assert {:error, _} = Ash.get(Chat, chat.id, actor: recipient)
    assert {:error, _} = Ash.get(ChatMessage, message.id, actor: recipient)
  end

  test "chat sharing rejects chats with chat blocks or chat tools" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, max_tool_rounds: 300)
    configuration = create_configuration!(owner, note: "shared")
    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)

    block_chat = create_chat!(owner, bot_id: bot.id, llm_configuration_id: configuration.id)
    block = create_knowledge_block!(owner, name: "Block")

    ChatKnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: block_chat.id, knowledge_block_id: block.id, enabled: true, sequence: 0},
      actor: owner
    )
    |> Ash.create!()

    assert {:error, {:validation, message}} =
             Sharing.replace_chat_share_state(block_chat.id, [group.id], owner)

    assert message =~ "chat blocks"

    tool_chat = create_chat!(owner, bot_id: bot.id, llm_configuration_id: configuration.id)
    tool = create_tool_instance!(owner, name: "Tool", alias: "tool")

    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: tool_chat.id, tool_instance_id: tool.id, enabled: true, sequence: 0},
      actor: owner
    )
    |> Ash.create!()

    assert {:error, {:validation, message}} =
             Sharing.replace_chat_share_state(tool_chat.id, [group.id], owner)

    assert message =~ "chat tools"
  end

  test "continuation copies only active branch and cancels active generating messages" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, max_tool_rounds: 300)
    configuration = create_configuration!(owner, note: "shared")
    historical_configuration = create_configuration!(owner, note: "shared")
    share_bot!(owner, bot, group)
    share_configuration!(owner, configuration, group)

    chat = create_chat!(owner, bot_id: bot.id, llm_configuration_id: configuration.id)
    assert {:ok, _state} = Sharing.replace_chat_share_state(chat.id, [group.id], owner)
    {:ok, root} = Threads.add_message_to_end(chat, :user, "root", actor: owner)

    {:ok, active_answer} =
      Threads.add_message_to_end(chat, :assistant, "active",
        actor: owner,
        llm_configuration_id: historical_configuration.id
      )

    {:ok, source_file} = Files.create_from_binary("artifact.txt", "text/plain", "payload")

    {:ok, _generating} =
      Threads.add_message_to_end(chat, :assistant, "",
        actor: owner,
        status: :generating,
        contents: [%{kind: :media, file_id: source_file.id}]
      )

    {:ok, _inactive} =
      Threads.add_message(chat, :assistant, "inactive",
        actor: owner,
        parent_id: root.id
      )

    {:ok, _meta} = Threads.activate_branch(chat.id, active_answer.id, owner)

    {:ok, _generating_again} =
      Threads.add_message_to_end(chat, :assistant, "tail",
        actor: owner,
        status: :generating,
        llm_configuration_id: configuration.id
      )

    assert {:ok, copied_chat} = Continuation.continue_chat(chat.id, recipient)

    source_messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.read!(actor: owner)

    copied_messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^copied_chat.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: recipient)

    assert length(source_messages) == 5
    assert length(copied_messages) == 4
    assert Enum.all?(copied_messages, &(&1.owner_id == recipient.id))
    assert Enum.count(copied_messages, &(&1.llm_configuration_id == configuration.id)) == 1

    refute Enum.any?(
             copied_messages,
             &(&1.llm_configuration_id == historical_configuration.id)
           )

    copied_branch = Threads.active_branch(copied_chat.id, recipient)
    assert Enum.map(copied_branch, & &1.status) == [:done, :done, :canceled, :canceled]

    source_media_content =
      ChatMessageContent
      |> Ash.Query.filter(
        not is_nil(file_id) and
          chat_message_item.chat_message_step.chat_message.chat_id == ^chat.id
      )
      |> Ash.read!(actor: owner)
      |> Enum.find(&(&1.file_id == source_file.id))

    copied_media_content =
      ChatMessageContent
      |> Ash.Query.filter(
        not is_nil(file_id) and
          chat_message_item.chat_message_step.chat_message.chat_id == ^copied_chat.id
      )
      |> Ash.read!(actor: recipient)
      |> List.first()

    assert source_media_content.file_id == source_file.id
    assert is_integer(copied_media_content.file_id)
    assert copied_media_content.file_id != source_file.id
  end
end
