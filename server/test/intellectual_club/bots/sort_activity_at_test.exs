defmodule IntellectualClub.Bots.SortActivityAtTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.{Bot, BotShare}
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Threads

  require Ash.Query

  test "uses the latest message timestamp across actor chats for the bot" do
    %{user: actor} = user_fixture()

    bot = create_bot!(actor, "Sort bot")
    chat_one = create_chat!(actor, bot.id, "Chat one")
    chat_two = create_chat!(actor, bot.id, "Chat two")

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
    bot = create_bot!(actor, "Fallback bot")

    loaded_bot = load_bot_with_sort_activity!(bot.id, actor)

    assert %DateTime{} = loaded_bot.sort_activity_at
    assert datetime_iso(loaded_bot.sort_activity_at) == datetime_iso(bot.updated_at)
  end

  test "uses only the current actor chats for shared bot activity" do
    %{user: owner} = user_fixture()
    %{user: recipient} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    bot = create_bot!(owner, "Shared sort bot")
    owner_chat = create_chat!(owner, bot.id, "Owner chat")

    {:ok, _owner_message} =
      Threads.add_message_to_end(owner_chat, :user, "Owner activity", actor: owner)

    share_bot!(owner, bot, group)

    shared_bot_without_recipient_chats = load_bot_with_sort_activity!(bot.id, recipient)

    assert datetime_iso(shared_bot_without_recipient_chats.sort_activity_at) ==
             datetime_iso(bot.updated_at)

    recipient_chat = create_chat!(recipient, bot.id, "Recipient chat")

    {:ok, recipient_message} =
      Threads.add_message_to_end(recipient_chat, :user, "Recipient activity", actor: recipient)

    shared_bot_with_recipient_chat = load_bot_with_sort_activity!(bot.id, recipient)

    assert datetime_iso(shared_bot_with_recipient_chat.sort_activity_at) ==
             datetime_iso(recipient_message.created_at)
  end

  defp load_bot_with_sort_activity!(bot_id, actor) do
    Bot
    |> Ash.Query.filter(id == ^bot_id)
    |> Ash.Query.load(:sort_activity_at)
    |> Ash.read!(actor: actor)
    |> List.first()
  end

  defp create_bot!(actor, name) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        max_tool_rounds: 20,
        context_soft_limit_percent: 80
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_chat!(actor, bot_id, _title) do
    Chat
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot_id, note: ""},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp share_bot!(actor, bot, group) do
    BotShare
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!()
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
