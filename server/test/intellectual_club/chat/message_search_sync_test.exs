defmodule IntellectualClub.Chat.MessageSearchSyncTest do
  use IntellectualClub.DataCase, async: false
  alias IntellectualClub.Chat.{Chat, ChatMessage}
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Search
  alias IntellectualClub.Chat.Threads

  require Ash.Query

  test "message search tracks text updates and kind changes" do
    %{user: actor} = user_fixture()

    chat = create_chat!(actor)
    {:ok, message} = Threads.add_message_to_end(chat, :user, "Alpha beta", actor: actor)
    content = load_content_by_message!(message.id, actor)

    assert content.item_type == :input
    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "alpha", actor)) == [message.id]
    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "beta", actor)) == [message.id]

    content =
      content
      |> Ash.Changeset.for_update(:update, %{content_text: "Gamma delta"}, actor: actor)
      |> Ash.update!(actor: actor)

    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "gamma", actor)) == [message.id]
    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "alpha", actor)) == []

    _content =
      content
      |> Ash.Changeset.for_update(
        :update,
        %{kind: :opaque, content_text: "", content_json: %{"value" => "hidden"}},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "gamma", actor)) == []
  end

  test "content item type follows its parent item type" do
    %{user: actor} = user_fixture()

    chat = create_chat!(actor)
    {:ok, message} = Threads.add_message_to_end(chat, :user, "Searchable text", actor: actor)
    item = load_item_by_message!(message.id, actor)

    assert load_content_by_message!(message.id, actor).item_type == :input

    _item =
      item
      |> Ash.Changeset.for_update(:update, %{type: :reasoning}, actor: actor)
      |> Ash.update!(actor: actor)

    assert load_content_by_message!(message.id, actor).item_type == :reasoning
    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "searchable", actor)) == []
  end

  test "message search excludes deleted text contents" do
    %{user: actor} = user_fixture()

    chat = create_chat!(actor)
    {:ok, message} = Threads.add_message_to_end(chat, :user, "Delete me", actor: actor)
    content = load_content_by_message!(message.id, actor)

    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "delete", actor)) == [
             message.id
           ]

    Ash.destroy!(content, actor: actor)

    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "delete", actor)) == []
  end

  describe "Ash message actions" do
    test "search uses literal substrings and returns each message once before pagination" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, first} = Threads.add_message_to_end(chat, :user, "100%_matched", actor: actor)
      message = create_message!(actor, chat)
      step = create_step!(actor, message)
      item = create_text_item!(actor, step, "100%_matched", type: :answer)
      create_content!(actor, item, sequence: 2, content_text: "100%_matched", kind: :text)
      Threads.add_message_to_end(chat, :assistant, "100XXmatched", actor: actor)
      query = ChatMessage |> Ash.Query.for_read(:search, %{q: "%_"}, actor: actor)
      page = Ash.read!(query, page: [limit: 1, count: true])
      assert page.count == 2
      assert [hit] = page.results
      assert hit.id == message.id
      assert page.more?
      next = Ash.read!(query, page: [limit: 1, offset: 1])
      assert Enum.map(next.results, & &1.id) == [first.id]
      refute next.more?
    end

    test "text excludes tool and reasoning traces and includes handoff text" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      message = create_message!(actor, chat)
      step = create_step!(actor, message)
      create_text_item!(actor, step, "Private reasoning", type: :reasoning, sequence: 1)
      create_text_item!(actor, step, "Tool arguments", type: :tool_call, sequence: 2)
      create_text_item!(actor, step, "Visible answer", type: :answer, sequence: 3)
      create_text_item!(actor, step, "Handoff summary", type: :handoff_summary, sequence: 4)
      loaded = Ash.load!(message, :text, actor: actor)
      assert loaded.text == "Visible answer\n\nHandoff summary"

      for term <- ["Private reasoning", "Tool arguments"] do
        assert [] ==
                 ChatMessage
                 |> Ash.Query.for_read(:search, %{q: term}, actor: actor)
                 |> Ash.read!(page: false)
      end

      assert [hit] =
               ChatMessage
               |> Ash.Query.for_read(:search, %{q: "summary"}, actor: actor)
               |> Ash.read!(page: false)

      assert hit.id == message.id
    end

    test "read_messages includes projected fork history without later source text" do
      import IntellectualClub.Chat.ForkFixtures
      %{user: actor} = user_fixture()
      source = create_fork_source!(actor)
      child = create_fork_child!(actor, source)
      later = create_step!(actor, source.message, sequence: 2)
      create_text_item!(actor, later, "LATER PRIVATE ANSWER")
      {:ok, local} = Threads.add_message_to_end(child, :user, "Local question", actor: actor)

      page =
        Chat
        |> Ash.ActionInput.for_action(:read_messages, %{id: child.id}, actor: actor)
        |> Ash.run_action!()

      assert Enum.map(page.messages, & &1.id) == [source.root.id, source.message.id, local.id]
      assert Enum.map(page.messages, & &1.inherited) == [true, true, false]

      assert Enum.map(page.messages, & &1.text) == [
               "Root question",
               "Parent completed response",
               "Local question"
             ]
    end

    test "shared chats are readable but shared forks do not grant access to their source" do
      import IntellectualClub.Chat.ForkFixtures
      %{user: actor} = user_fixture()
      %{user: reader} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [actor, reader]})
      bot = create_bot!(actor)
      provider = create_provider!(actor)
      config = create_configuration!(actor, provider: provider)

      source =
        create_fork_source!(actor, chat_attrs: %{bot_id: bot.id, llm_configuration_id: config.id})

      child = create_fork_child!(actor, source)
      share_chat!(actor, child, group)
      input = Ash.ActionInput.for_action(Chat, :read_messages, %{id: child.id}, actor: reader)
      assert {:error, _error} = Ash.run_action(input)

      assert [] ==
               ChatMessage
               |> Ash.Query.for_read(:search, %{q: "Root question"}, actor: reader)
               |> Ash.read!(page: false)

      share_chat!(actor, source.chat, group)
      page = Ash.run_action!(input)
      assert Enum.map(page.messages, & &1.text) == ["Root question", "Parent completed response"]

      assert [hit] =
               ChatMessage
               |> Ash.Query.for_read(:search, %{q: "Root question"}, actor: reader)
               |> Ash.Query.load(:text)
               |> Ash.read!(page: false)

      assert hit.text == "Root question"
    end

    test "messages without user-facing text retain an empty text field" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      message = create_message!(actor, chat)
      assert Ash.load!(message, :text, actor: actor).text == ""

      page =
        Chat
        |> Ash.ActionInput.for_action(:read_messages, %{id: chat.id}, actor: actor)
        |> Ash.run_action!()

      assert [%{text: ""}] = page.messages
    end

    test "an empty conversation returns an empty page and anonymous readers are rejected" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)

      page =
        Chat
        |> Ash.ActionInput.for_action(:read_messages, %{id: chat.id}, actor: actor)
        |> Ash.run_action!()

      assert page.messages == []
      refute page.has_more
      assert page.next_offset == nil

      assert {:error, _} =
               Chat
               |> Ash.ActionInput.for_action(:read_messages, %{id: chat.id})
               |> Ash.run_action()
    end
  end

  defp load_content_by_message!(message_id, actor) do
    item = load_item_by_message!(message_id, actor)

    ChatMessageContent
    |> Ash.Query.filter(chat_message_item_id == ^item.id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read_one!(actor: actor)
  end

  defp load_item_by_message!(message_id, actor) do
    step =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^message_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read_one!(actor: actor)

    ChatMessageItem
    |> Ash.Query.filter(chat_message_step_id == ^step.id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read_one!(actor: actor)
  end

  defp active_hit_ids(%{active: hits}) do
    Enum.map(hits, & &1.id)
  end
end
