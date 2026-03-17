defmodule IntellectualClub.Chat.MessageContentFtsSyncTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Search
  alias IntellectualClub.Chat.Threads

  require Ash.Query

  test "search index tracks text updates and kind changes" do
    %{user: actor} = user_fixture()

    chat = create_chat!(actor, "FTS sync chat")
    {:ok, message} = Threads.add_message_to_end(chat, :user, "Alpha beta", actor: actor)
    content = load_content_by_message!(message.id, actor)

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

  test "search index removes deleted text contents" do
    %{user: actor} = user_fixture()

    chat = create_chat!(actor, "FTS delete chat")
    {:ok, message} = Threads.add_message_to_end(chat, :user, "Delete me", actor: actor)
    content = load_content_by_message!(message.id, actor)

    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "delete", actor)) == [
             message.id
           ]

    Ash.destroy!(content, actor: actor)

    assert active_hit_ids(Search.search_messages_in_chat(chat.id, "delete", actor)) == []
  end

  defp create_chat!(actor, title) do
    Chat
    |> Ash.Changeset.for_create(:create, %{title: title, note: "", variables: %{}}, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp load_content_by_message!(message_id, actor) do
    step =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^message_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read_one!(actor: actor)

    item =
      ChatMessageItem
      |> Ash.Query.filter(chat_message_step_id == ^step.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read_one!(actor: actor)

    ChatMessageContent
    |> Ash.Query.filter(chat_message_item_id == ^item.id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read_one!(actor: actor)
  end

  defp active_hit_ids(%{active: hits}) do
    Enum.map(hits, & &1.id)
  end
end
