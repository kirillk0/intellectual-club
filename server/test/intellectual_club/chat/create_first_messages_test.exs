defmodule IntellectualClub.Chat.CreateFirstMessagesTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage

  require Ash.Query

  test "chat creation populates assistant first messages" do
    %{user: user} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{name: "FM Bot", first_messages: ["Hello", "Alt branch", "{{missing}}"]},
        actor: user
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, note: ""},
        actor: user
      )
      |> Ash.create!()

    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.load(steps: [items: [:contents]])
      |> Ash.read!(actor: user)

    assert Enum.map(messages, &message_answer_text/1) == ["Hello", "Alt branch", "{{missing}}"]
    assert Enum.all?(messages, &(&1.role == :assistant))
    assert Enum.all?(messages, &is_nil(&1.parent_id))
    assert Enum.all?(messages, &is_nil(&1.llm_configuration_id))
  end

  test "first messages preserve placeholder text" do
    %{user: user} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Vars Bot",
          first_messages: ["Hello {{ x }}!", "Name: {{name}}; missing: {{missing}}"]
        },
        actor: user
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          note: ""
        },
        actor: user
      )
      |> Ash.create!()

    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.load(steps: [items: [:contents]])
      |> Ash.read!(actor: user)

    assert Enum.map(messages, &message_answer_text/1) == [
             "Hello {{ x }}!",
             "Name: {{name}}; missing: {{missing}}"
           ]
  end

  test "chat creation without bot does not create messages" do
    %{user: user} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create, %{note: ""}, actor: user)
      |> Ash.create!()

    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.read!(actor: user)

    assert messages == []
  end

  defp message_answer_text(message) do
    (message.steps || [])
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.filter(&(&1.type == :answer))
    |> Enum.flat_map(&(&1.contents || []))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", fn content -> content.content_text || "" end)
  end
end
