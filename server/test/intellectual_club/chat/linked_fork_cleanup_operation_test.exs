defmodule IntellectualClub.Chat.LinkedForkCleanupOperationTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, LinkedForkCleanup, Threads}
  alias IntellectualClub.Chat.LinkedForkCleanup.Operation

  require Ash.Query

  setup do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(:create_empty, %{}, actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, message} = Threads.add_message_to_end(chat, :assistant, "Operation", actor: actor)
    message = Ash.load!(message, :steps, actor: actor)
    %{actor: actor, chat: chat, message: message, step: hd(message.steps)}
  end

  test "capability expires even within the same outer transaction", f do
    assert {:ok, :verified} =
             Ash.transaction(Chat, fn ->
               operation =
                 LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                   assert Operation.record!(operation, ChatMessageStep, f.step.id, f.actor).id ==
                            f.step.id

                   operation
                 end)

               assert_raise ArgumentError, "Cleanup operation is no longer active", fn ->
                 Operation.state!(operation, f.actor)
               end

               assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor)
               :verified
             end)
  end

  test "capability cannot be forged, widened or used for another actor", f do
    %{user: other} = user_fixture()

    assert {:ok, :verified} =
             Ash.transaction(Chat, fn ->
               LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                 assert_raise ArgumentError, fn -> Operation.state!(operation, other) end

                 assert_raise ArgumentError, fn ->
                   Operation.state!(%{operation | token: make_ref()}, f.actor)
                 end

                 assert_raise ArgumentError, "Record is outside the cleanup operation", fn ->
                   Operation.record!(operation, Chat, f.chat.id, f.actor)
                 end

                 assert_raise ArgumentError, "Cleanup plan does not match the retry range", fn ->
                   LinkedForkCleanup.retry_steps!(operation, f.message.id, 1, f.actor)
                 end

                 :verified
               end)
             end)
  end

  test "capability is removed on callback exceptions and outer rollback", f do
    assert {:ok, :verified} =
             Ash.transaction(Chat, fn ->
               try do
                 LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                   send(self(), {:operation, operation})
                   raise "deliberate callback failure"
                 end)
               rescue
                 RuntimeError -> :ok
               end

               assert_receive {:operation, operation}
               assert_raise ArgumentError, fn -> Operation.state!(operation, f.actor) end
               :verified
             end)

    assert {:error, _} =
             Ash.transaction(Chat, fn ->
               LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, fn operation ->
                 send(self(), {:rolled_back_operation, operation})
                 Ash.DataLayer.rollback(Chat, :deliberate_rollback)
               end)
             end)

    assert_receive {:rolled_back_operation, operation}
    assert_raise ArgumentError, fn -> Operation.state!(operation, f.actor) end
    assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor)
  end

  test "a captured capability cannot bypass a later destroy's preflight", f do
    assert {:ok, operation} =
             Ash.transaction(Chat, fn ->
               LinkedForkCleanup.with_scope({:step, f.step.id}, f.actor, & &1)
             end)

    assert {:error, _} =
             f.step
             |> Ash.Changeset.for_destroy(:destroy, %{},
               actor: f.actor,
               context: LinkedForkCleanup.context(operation)
             )
             |> Ash.destroy(actor: f.actor)

    assert Ash.get!(ChatMessageStep, f.step.id, actor: f.actor)
    assert :ok = Ash.destroy(f.step, actor: f.actor)
  end

  for {resource, field, action} <- [
        {Chat, :chat, :destroy},
        {ChatMessage, :message, :destroy},
        {ChatMessage, :message, :destroy_with_children},
        {ChatMessageStep, :step, :destroy}
      ] do
    @resource resource
    @field field
    @action action
    test "bulk #{@resource}.#{@action} preserves the single cleanup scope", f do
      record = Map.fetch!(f, @field)
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:intellectual_club, :linked_fork_cleanup, :plan],
          &__MODULE__.observe_plan/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      result =
        @resource
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.bulk_destroy(@action, %{},
          actor: f.actor,
          notify?: true,
          return_errors?: true,
          return_records?: true,
          strategy: [:atomic, :stream, :atomic_batches],
          load: [:id]
        )

      assert result.status == :success
      assert result.error_count == 0
      assert [%{id: id}] = result.records
      assert id == record.id
      assert_receive {:cleanup_plan, _scope}
      refute_receive {:cleanup_plan, _scope}, 0
      refute @resource |> Ash.Query.filter(id == ^record.id) |> Ash.exists?(actor: f.actor)
      refute ChatMessageStep |> Ash.Query.filter(id == ^f.step.id) |> Ash.exists?(actor: f.actor)
    end
  end

  @doc false
  def observe_plan(_event, _measurements, metadata, parent) do
    if self() == parent, do: send(parent, {:cleanup_plan, metadata.scope})
  end
end
