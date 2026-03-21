defmodule IntellectualClub.Chat.ThreadsTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads

  test "branch metadata and switching to rightmost leaf" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Branch chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, m1} = Threads.add_message(chat, :user, "root", actor: actor, parent_id: nil)
    {:ok, a1} = Threads.add_message(chat, :assistant, "A", actor: actor, parent_id: m1.id)
    {:ok, a1_u} = Threads.add_message(chat, :user, "A.u", actor: actor, parent_id: a1.id)

    {:ok, a1_u_a} =
      Threads.add_message(chat, :assistant, "A.u.a", actor: actor, parent_id: a1_u.id)

    {:ok, b1} = Threads.add_message(chat, :assistant, "B", actor: actor, parent_id: m1.id)
    {:ok, b1_u} = Threads.add_message(chat, :user, "B.u", actor: actor, parent_id: b1.id)

    {:ok, b1_u_a} =
      Threads.add_message(chat, :assistant, "B.u.a", actor: actor, parent_id: b1_u.id)

    {:ok, _branch} = Threads.activate_branch(chat.id, a1_u_a.id, actor)

    branch = Threads.get_branch_with_meta(chat.id, actor)
    assert Enum.map(branch, & &1.id) == [m1.id, a1.id, a1_u.id, a1_u_a.id]

    a1_node = Enum.at(branch, 1)
    assert a1_node.prev_sibling == nil
    assert a1_node.next_sibling == b1.id
    assert Enum.map(a1_node.siblings, & &1.id) == [a1.id, b1.id]

    size_by_id = Map.new(a1_node.siblings, &{&1.id, &1.size})
    assert size_by_id[a1.id] == 3
    assert size_by_id[b1.id] == 3

    {:ok, switched} = Threads.switch_branch(chat.id, a1.id, actor: actor, direction: :next)
    assert List.last(switched).id == b1_u_a.id

    chat = Ash.get!(Chat, chat.id, actor: actor)
    assert chat.last_message_id == b1_u_a.id
  end

  test "delete_message_keep_children rejects role mix when deleting alternative with replies" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Delete chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message(chat, :user, "root", actor: actor, parent_id: nil)
    {:ok, a1} = Threads.add_message(chat, :assistant, "A", actor: actor, parent_id: root.id)
    {:ok, _b1} = Threads.add_message(chat, :assistant, "B", actor: actor, parent_id: root.id)
    {:ok, _a1_u} = Threads.add_message(chat, :user, "A.u", actor: actor, parent_id: a1.id)

    assert {:error, :cannot_mix_roles} =
             Threads.delete_message_keep_children(chat.id, a1.id, actor)
  end

  test "delete_message_keep_children updates last_message to sibling branch leaf" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Delete last", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message(chat, :user, "root", actor: actor, parent_id: nil)
    {:ok, a1} = Threads.add_message(chat, :assistant, "A", actor: actor, parent_id: root.id)
    {:ok, b1} = Threads.add_message(chat, :assistant, "B", actor: actor, parent_id: root.id)

    {:ok, _branch} = Threads.activate_branch(chat.id, a1.id, actor)
    assert {:ok, _updated_branch} = Threads.delete_message_keep_children(chat.id, a1.id, actor)

    chat = Ash.get!(Chat, chat.id, actor: actor)
    assert chat.last_message_id == b1.id
  end

  test "delete_message_keep_children removes generation trace for deleted message" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Delete trace", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message(chat, :user, "root", actor: actor, parent_id: nil)
    {:ok, a1} = Threads.add_message(chat, :assistant, "A", actor: actor, parent_id: root.id)
    {:ok, b1} = Threads.add_message(chat, :assistant, "B", actor: actor, parent_id: root.id)

    a1_loaded =
      Ash.get!(ChatMessage, a1.id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    [step] = Enum.sort_by(a1_loaded.steps || [], & &1.sequence)
    [item] = Enum.sort_by(step.items || [], & &1.sequence)
    [content] = Enum.sort_by(item.contents || [], & &1.sequence)

    {:ok, _branch} = Threads.activate_branch(chat.id, a1.id, actor)
    assert {:ok, _updated_branch} = Threads.delete_message_keep_children(chat.id, a1.id, actor)

    assert {:error, _} = Ash.get(ChatMessage, a1.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageStep, step.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageItem, item.id, actor: actor)
    assert {:error, _} = Ash.get(ChatMessageContent, content.id, actor: actor)

    chat = Ash.get!(Chat, chat.id, actor: actor)
    assert chat.last_message_id == b1.id
  end

  test "adding a message stores token_count estimate" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Edit chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, message} = Threads.add_message(chat, :user, "hello", actor: actor, parent_id: nil)
    assert message.token_count == 2
  end

  test "adding a user message sets finished_at on the message and initial step" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Finished at chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, message} = Threads.add_message(chat, :user, "hello", actor: actor, parent_id: nil)

    loaded =
      Ash.get!(ChatMessage, message.id,
        actor: actor,
        load: [steps: [:finished_at]]
      )

    assert %DateTime{} = loaded.finished_at

    [step] = Enum.sort_by(loaded.steps || [], & &1.sequence)
    assert %DateTime{} = step.finished_at
  end

  test "add_user_message uses chat last_message as default parent" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Default parent", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    first =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_user_message,
        %{chat_id: chat.id, token_count: 1},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    second =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_user_message,
        %{chat_id: chat.id, token_count: 1},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert first.parent_id == nil
    assert second.parent_id == first.id
  end
end
