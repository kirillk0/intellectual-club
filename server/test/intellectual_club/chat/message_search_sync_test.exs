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

  test "searches canonical fragments across item and step boundaries in their display order" do
    %{user: actor} = user_fixture()
    chat = create_empty_chat!(actor)
    message = create_message!(actor, chat)
    later = create_step!(actor, message, sequence: 2)
    earlier = create_step!(actor, message, sequence: 1)
    create_text_item!(actor, later, "финал")
    item = create_item!(actor, earlier, type: :answer, sequence: 2)
    create_content!(actor, item, sequence: 2, content_text: "данных")
    create_content!(actor, item, sequence: 1, content_text: "мета")
    moved = create_text_item!(actor, earlier, "поиск", sequence: 1)

    assert search_ids(actor, "поис метадан фин", exact: true) == [message.id]
    assert search_ids(actor, "данных", exact: true) == []

    moved
    |> Ash.Changeset.for_update(:update, %{sequence: 3}, actor: actor)
    |> Ash.update!(actor: actor)

    assert search_ids(actor, "поис метадан", exact: true) == []
    assert search_ids(actor, "метадан поис фин", exact: true) == [message.id]

    Ash.destroy!(earlier, actor: actor)
    assert search_ids(actor, "метадан", exact: true) == []
    assert search_ids(actor, "фин", exact: true) == [message.id]
  end

  test "search edits and their results roll back together" do
    %{user: actor} = user_fixture()
    chat = create_empty_chat!(actor)
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    item = create_text_item!(actor, step, "прежний")
    [content] = item.contents

    assert {:error, _} =
             Ash.transaction(ChatMessageContent, fn ->
               edit_text!(actor, content, "новый")

               assert search_ids(actor, "нов") == [message.id]
               assert search_ids(actor, "преж") == []
               Ash.DataLayer.rollback(ChatMessageContent, :deliberate)
             end)

    assert search_ids(actor, "преж") == [message.id]
    assert search_ids(actor, "нов") == []
  end

  test "moving a trace step removes its terms from the old message and indexes the new one" do
    %{user: actor} = user_fixture()
    chat = create_empty_chat!(actor)
    before = create_message!(actor, chat)
    after_move = create_message!(actor, chat)
    step = create_step!(actor, before)
    create_text_item!(actor, step, "searchable payload")
    assert search_ids(actor, "paylo") == [before.id]

    # The API makes this FK immutable; maintenance/import SQL can still move a step.
    Repo.query!("UPDATE chat_message_steps SET chat_message_id=$1 WHERE id=$2", [
      after_move.id,
      step.id
    ])

    assert search_ids(actor, "paylo") == [after_move.id]
  end

  test "deleting a complete trace subtree in one statement removes its searchable text" do
    %{user: actor} = user_fixture()
    chat = create_empty_chat!(actor)
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    item = create_text_item!(actor, step, "discarded payload")
    assert search_ids(actor, "discard") == [message.id]

    Repo.query!(
      """
      WITH removed AS (
        DELETE FROM chat_message_contents WHERE chat_message_item_id=$1 RETURNING chat_message_item_id
      ), removed_items AS (
        DELETE FROM chat_message_items WHERE id IN (SELECT chat_message_item_id FROM removed)
        RETURNING chat_message_step_id
      )
      DELETE FROM chat_message_steps WHERE id IN (SELECT chat_message_step_id FROM removed_items)
      """,
      [item.id]
    )

    assert search_ids(actor, "discard") == []
  end

  test "a text larger than PostgreSQL's lexeme storage limit can still be saved in full" do
    %{user: actor} = user_fixture()
    chat = create_empty_chat!(actor)
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    text = "searchable beginning " <> Enum.map_join(1..120_000, " ", &"token#{&1}")
    item = create_text_item!(actor, step, text)

    assert [content] = item.contents
    assert content.content_text == text
    assert search_ids(actor, "begin") == [message.id]
  end

  @tag :whitebox
  @tag sandbox: false
  test "concurrent committed fragment edits publish the vector of both final values" do
    alias IntellectualClub.Chat.DbRaceHelpers, as: Race

    %{user: actor} = user_fixture()
    on_exit(fn -> Race.cleanup_committed_owner!(actor) end)
    chat = create_empty_chat!(actor)
    message = create_message!(actor, chat)
    item = create_item!(actor, create_step!(actor, message))
    first = create_content!(actor, item, content_text: "initial ")
    second = create_content!(actor, item, sequence: 2, content_text: "text")
    parent = self()

    holder =
      Race.db_task!(fn ->
        Repo.transaction(fn ->
          edit_text!(actor, first, "updated ")
          backend = backend_pid!()
          send(parent, {:first_edited, self()})

          receive do
            {:verify_wait, waiter} -> Race.await_blocked!(waiter, backend)
          after
            10_000 -> flunk("Concurrent editor did not start")
          end

          :ok
        end)
      end)

    assert_receive {:first_edited, pid}, 10_000

    contender =
      Race.db_task!(fn ->
        send(parent, {:second_editor, backend_pid!()})
        edit_text!(actor, second, "words")
        :ok
      end)

    assert_receive {:second_editor, backend}, 10_000
    send(pid, {:verify_wait, backend})
    assert {:ok, :ok} = Race.finish!(holder)
    assert :ok = Race.finish!(contender)
    assert search_ids(actor, "updat word", exact: true) == [message.id]
    assert search_ids(actor, "initial") == []
  end

  @tag :whitebox
  @tag sandbox: false
  test "a generation fence does not block indexing a visible trace fragment" do
    alias IntellectualClub.Chat.DbRaceHelpers, as: Race

    %{user: actor} = user_fixture()
    on_exit(fn -> Race.cleanup_committed_owner!(actor) end)
    chat = create_empty_chat!(actor)
    message = create_message!(actor, chat)
    item = create_item!(actor, create_step!(actor, message))
    parent = self()

    holder =
      Race.db_task!(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM chat_messages WHERE id=$1 FOR NO KEY UPDATE", [message.id])
          send(parent, {:message_fenced, self()})

          receive do
            :release_message -> :ok
          after
            10_000 -> flunk("Fence was not released")
          end
        end)
      end)

    assert_receive {:message_fenced, pid}, 10_000

    writer =
      Race.db_task!(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout='2s'")
          create_content!(actor, item, content_text: "visible.new.text")
          :written
        end)
      end)

    try do
      assert {:ok, :written} = Race.finish!(writer)
      assert search_ids(actor, "vis new tex", exact: true) == [message.id]
    after
      send(pid, :release_message)
      assert {:ok, :ok} = Race.finish!(holder)
    end
  end

  @tag :whitebox
  @tag sandbox: false
  test "the first committed fragment and a concurrent item reorder leave canonical positions" do
    alias IntellectualClub.Chat.DbRaceHelpers, as: Race

    %{user: actor} = user_fixture()
    on_exit(fn -> Race.cleanup_committed_owner!(actor) end)
    chat = create_empty_chat!(actor)
    message = create_message!(actor, chat)
    step = create_step!(actor, message)
    empty = create_item!(actor, step, type: :answer, sequence: 1)
    create_text_item!(actor, step, "existing", sequence: 2)
    parent = self()

    insert =
      Race.db_task!(fn ->
        Repo.transaction(fn ->
          create_content!(actor, empty, content_text: "inserted")
          backend = backend_pid!()
          send(parent, {:fragment_inserted, self()})

          receive do
            {:verify_reorder_wait, waiter} -> Race.await_blocked!(waiter, backend)
          after
            10_000 -> flunk("Reorder did not start")
          end

          :inserted
        end)
      end)

    assert_receive {:fragment_inserted, pid}, 10_000

    reorder =
      Race.db_task!(fn ->
        send(parent, {:reorder_backend, backend_pid!()})

        empty
        |> Ash.Changeset.for_update(:update, %{sequence: 3}, actor: actor)
        |> Ash.update!(actor: actor)

        :reordered
      end)

    assert_receive {:reorder_backend, backend}, 10_000
    send(pid, {:verify_reorder_wait, backend})
    assert {:ok, :inserted} = Race.finish!(insert)
    assert :reordered = Race.finish!(reorder)
    assert search_ids(actor, "exist insert", exact: true) == [message.id]
    assert search_ids(actor, "insert exist", exact: true) == []
  end

  describe "Ash message actions" do
    test "search returns each matching message once before pagination" do
      %{user: actor} = user_fixture()
      chat = create_empty_chat!(actor)
      {:ok, first} = Threads.add_message_to_end(chat, :user, "Matchable text ", actor: actor)
      message = create_message!(actor, chat)
      step = create_step!(actor, message)
      item = create_text_item!(actor, step, "Matchable text ", type: :answer)
      create_content!(actor, item, sequence: 2, content_text: "Matchable text ", kind: :text)
      Threads.add_message_to_end(chat, :assistant, "Overmatched", actor: actor)
      query = ChatMessage |> Ash.Query.for_read(:search, %{q: "matchab"}, actor: actor)
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
      create_text_item!(actor, step, "Wrong role input", type: :input, sequence: 5)
      loaded = Ash.load!(message, :text, actor: actor)
      assert loaded.text == "Visible answer\n\nHandoff summary"

      for term <- ["Private reasoning", "Tool arguments", "Wrong role input"] do
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

  defp search_ids(actor, query, opts \\ []) do
    ChatMessage
    |> Ash.Query.for_read(:search, Map.new([q: query] ++ opts), actor: actor)
    |> Ash.read!(actor: actor, page: false)
    |> Enum.map(& &1.id)
  end

  defp edit_text!(actor, content, text) do
    content
    |> Ash.Changeset.for_update(:update, %{content_text: text}, actor: actor)
    |> Ash.update!(actor: actor)
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
