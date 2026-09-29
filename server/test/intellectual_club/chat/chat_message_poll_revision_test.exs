defmodule IntellectualClub.Chat.ChatMessagePollRevisionTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessagePollRevision,
    ChatMessageStep
  }

  alias IntellectualClub.StepRequestsFixtures

  require Ash.Query

  setup do
    %{user: actor} = user_fixture()
    message = StepRequestsFixtures.request_message!(actor)
    Map.merge(trace!(message, actor), %{actor: actor, message: message})
  end

  test "rolling back a content edit restores both content and revision", f do
    before = revision!(f.message, f.actor)

    assert {:error, _} =
             Ash.transaction([ChatMessageContent, ChatMessagePollRevision], fn ->
               f.content
               |> Ash.Changeset.for_update(:update, %{content_text: "Uncommitted"},
                 actor: f.actor
               )
               |> Ash.update!(actor: f.actor)

               assert Ash.get!(ChatMessageContent, f.content.id, actor: f.actor).content_text ==
                        "Uncommitted"

               assert revision!(f.message, f.actor) > before
               Ash.DataLayer.rollback(ChatMessageContent, :deliberate_rollback)
             end)

    assert revision!(f.message, f.actor) == before

    assert Ash.get!(ChatMessageContent, f.content.id, actor: f.actor).content_text ==
             f.content.content_text
  end

  test "rolling back a step cascade restores the trace and its revision", f do
    before = revision!(f.message, f.actor)

    assert {:error, _} =
             Ash.transaction(
               [ChatMessageStep, ChatMessageItem, ChatMessageContent, ChatMessagePollRevision],
               fn ->
                 Ash.destroy!(f.step, actor: f.actor)
                 assert_missing(ChatMessageStep, f.step.id, f.actor)
                 assert_missing(ChatMessageItem, f.item.id, f.actor)
                 assert_missing(ChatMessageContent, f.content.id, f.actor)
                 assert revision!(f.message, f.actor) > before
                 Ash.DataLayer.rollback(ChatMessageStep, :deliberate_rollback)
               end
             )

    assert revision!(f.message, f.actor) == before
    assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor).chat_message_id == f.message.id
    assert Ash.get!(ChatMessageItem, f.item.id, actor: f.actor).chat_message_step_id == f.step.id

    assert Ash.get!(ChatMessageContent, f.content.id, actor: f.actor).content_text ==
             f.content.content_text
  end

  for resource <- [ChatMessageStep, ChatMessageItem, ChatMessageContent] do
    @resource resource

    test "supported Ash bulk create, update and destroy invalidate #{inspect(resource)}", f do
      resource = @resource
      other_message = StepRequestsFixtures.request_message!(f.actor)
      trace!(other_message, f.actor)
      other_revision = revision!(other_message, f.actor)
      before = revision!(f.message, f.actor)
      {attrs, update} = bulk_attributes(resource, f)

      assert %Ash.BulkResult{status: :success, records: records} =
               Ash.bulk_create(attrs, resource, :create,
                 actor: f.actor,
                 return_records?: true,
                 return_errors?: true,
                 transaction: :all
               )

      assert length(records) == 2
      created_revision = revision!(f.message, f.actor)
      assert created_revision > before
      assert revision!(other_message, f.actor) == other_revision
      ids = Enum.map(records, & &1.id)
      query = Ash.Query.filter(resource, id in ^ids)

      assert %Ash.BulkResult{status: :success, records: updated} =
               Ash.bulk_update(query, :update, update,
                 actor: f.actor,
                 strategy: [:atomic, :stream],
                 return_records?: true,
                 return_errors?: true,
                 transaction: :all
               )

      assert length(updated) == 2

      for record <- Ash.read!(query, actor: f.actor), {field, value} <- update do
        assert Map.fetch!(record, field) == value
      end

      updated_revision = revision!(f.message, f.actor)
      assert updated_revision > created_revision
      assert revision!(other_message, f.actor) == other_revision

      assert %Ash.BulkResult{status: :success, records: destroyed} =
               Ash.bulk_destroy(query, :destroy, %{},
                 actor: f.actor,
                 strategy: [:atomic, :stream],
                 return_records?: true,
                 return_errors?: true,
                 transaction: :all
               )

      assert length(destroyed) == 2
      assert Ash.read!(query, actor: f.actor) == []
      assert revision!(f.message, f.actor) > updated_revision
      assert revision!(other_message, f.actor) == other_revision
      assert Ash.get!(ChatMessageContent, f.content.id, actor: f.actor).content_text == "Original"
    end
  end

  for target <- [:step, :item] do
    @target target

    test "deleting a #{target} cascades to content and invalidates only its message", f do
      other_message = StepRequestsFixtures.request_message!(f.actor)
      other = trace!(other_message, f.actor)
      other_revision = revision!(other_message, f.actor)
      before = revision!(f.message, f.actor)

      Ash.destroy!(Map.fetch!(f, @target), actor: f.actor)

      assert_missing(ChatMessageItem, f.item.id, f.actor)
      assert_missing(ChatMessageContent, f.content.id, f.actor)

      if @target == :step do
        assert_missing(ChatMessageStep, f.step.id, f.actor)
      else
        assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor).id == f.step.id
      end

      assert Ash.get!(ChatMessage, f.message.id, actor: f.actor).id == f.message.id
      assert revision!(f.message, f.actor) > before
      assert revision!(other_message, f.actor) == other_revision

      assert Ash.get!(ChatMessageContent, other.content.id, actor: f.actor).content_text ==
               "Original"
    end
  end

  test "owner and shared viewer can read a revision, but a revoked viewer cannot", f do
    %{user: viewer} = user_fixture()
    %{user: stranger} = user_fixture()
    message = StepRequestsFixtures.shared_request_message!(f.actor, viewer)
    trace!(message, f.actor)
    owner_revision = revision!(message, f.actor)

    assert revision!(message, viewer) == owner_revision
    assert {:error, _} = Ash.get(ChatMessagePollRevision, message.id, actor: stranger)

    query = Ash.Query.filter(ChatMessagePollRevision, chat_message_id == ^message.id)
    assert [%ChatMessagePollRevision{revision: ^owner_revision}] = Ash.read!(query, actor: viewer)

    assert {:ok, _} =
             IntellectualClub.Sharing.replace_chat_share_state(message.chat_id, [], f.actor)

    assert {:error, _} = Ash.get(ChatMessagePollRevision, message.id, actor: viewer)
    assert Ash.read!(query, actor: viewer) == []
    assert revision!(message, f.actor) == owner_revision
  end

  defp trace!(message, actor) do
    step =
      create!(ChatMessageStep, %{chat_message_id: message.id, sequence: 1, status: :done}, actor)

    item =
      create!(
        ChatMessageItem,
        %{chat_message_step_id: step.id, sequence: 1, type: :answer},
        actor
      )

    content =
      create!(
        ChatMessageContent,
        %{chat_message_item_id: item.id, sequence: 1, kind: :text, content_text: "Original"},
        actor
      )

    %{step: step, item: item, content: content}
  end

  defp bulk_attributes(ChatMessageStep, f) do
    {for(
       sequence <- 2..3,
       do: %{chat_message_id: f.message.id, sequence: sequence, status: :done}
     ), %{output_tokens: 17}}
  end

  defp bulk_attributes(ChatMessageItem, f) do
    {for(
       sequence <- 2..3,
       do: %{chat_message_step_id: f.step.id, sequence: sequence, type: :answer}
     ), %{type: :reasoning}}
  end

  defp bulk_attributes(ChatMessageContent, f) do
    {for(
       sequence <- 2..3,
       do: %{
         chat_message_item_id: f.item.id,
         sequence: sequence,
         kind: :text,
         content_text: "Bulk original"
       }
     ), %{content_text: "Bulk edited"}}
  end

  defp revision!(message, actor) do
    Ash.get!(ChatMessagePollRevision, message.id, actor: actor).revision
  end

  defp assert_missing(resource, id, actor) do
    assert Ash.get!(resource, id, actor: actor, not_found_error?: false) == nil
  end

  defp create!(resource, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end
end
