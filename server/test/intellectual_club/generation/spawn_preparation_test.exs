defmodule IntellectualClub.Generation.SpawnPreparationTest do
  use IntellectualClub.DataCase, async: false

  require Ash.Query

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageItem, ChatMessageStep, Spawn}
  alias IntellectualClub.Tools.{ExecutionContext, ToolInstance}

  test "nesting rejection precedes transaction authority and preserves the expected reason" do
    %{user: actor} = user_fixture()

    root =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{note: ""}, actor: actor)
      |> Ash.create!(actor: actor)

    source =
      Chat
      |> Ash.Changeset.for_create(
        :create_empty,
        %{note: "", parent_chat_id: root.id, parent_relation_kind: :spawn, subagent: true},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{chat_id: source.id, role: :assistant, status: :done, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_id: message.id, sequence: 1},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    call =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 1, type: :tool_call},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.id,
      message_id: message.id,
      assistant_message_id: message.id,
      step_id: step.id,
      tool_call_item_id: call.id,
      generation_fence_token: Ash.UUID.generate()
    }

    tool = %ToolInstance{type: "native-agent-management", config: %{"nested_subchats_limit" => 0}}

    reason =
      "Nested subchat creation is unavailable for this subagent. " <>
        "Continue working on the task yourself without creating another subchat."

    for opts <- [[], [background_task_authority: :invalid]] do
      assert {:error, ^reason} =
               Spawn.start_or_resume(tool, "Brief", "Task", context, actor, opts)
    end

    assert [] == Chat |> Ash.Query.filter(parent_chat_id == ^source.id) |> Ash.read!(actor: actor)
    assert Ash.get!(ChatMessage, message.id, actor: actor).status == :done
    assert Ash.get!(Chat, source.id, actor: actor).last_message_id == message.id
  end
end
