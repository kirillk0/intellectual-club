defmodule IntellectualClub.Chat.Changes.ValidateLinkedFork do
  @moduledoc """
  Validates private live-fork anchors, including attributes set with force_change.

  Callers create linked forks with `create_empty` and force-change the two private
  attributes before executing the action. Public create/update inputs cannot set
  them. Legacy copies without an anchor retain their existing behavior.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep

  @anchor_fields [
    :fork_source_step_id,
    :fork_task,
    :parent_chat_id,
    :parent_message_id,
    :parent_tool_call_item_id,
    :parent_relation_kind,
    :owner_id
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &validate/1)
  end

  defp validate(changeset) do
    source_id = Changeset.get_attribute(changeset, :fork_source_step_id)
    task = Changeset.get_attribute(changeset, :fork_task)

    cond do
      changeset.action_type == :update and
          not Enum.any?(@anchor_fields, &Changeset.changing_attribute?(changeset, &1)) ->
        changeset

      changeset.action_type == :update and not is_nil(changeset.data.fork_task) and
          Enum.any?(@anchor_fields, &Changeset.changing_attribute?(changeset, &1)) ->
        invalid(changeset, "cannot change a live fork source")

      changeset.action_type == :update and
          Enum.any?(
            [:fork_source_step_id, :fork_task],
            &Changeset.changing_attribute?(changeset, &1)
          ) ->
        invalid(changeset, "cannot change a live fork anchor or task")

      is_nil(source_id) and is_nil(task) ->
        changeset

      changeset.action_type == :create and changeset.action.name != :create_empty ->
        invalid(changeset, "must be created with create_empty")

      not is_integer(source_id) or not is_binary(task) ->
        invalid(changeset, "requires both a source step and task")

      true ->
        validate_anchor(changeset, source_id)
    end
  end

  defp validate_anchor(changeset, source_id) do
    actor = changeset.context[:private][:actor]
    owner_id = Changeset.get_attribute(changeset, :owner_id)
    chat_id = Changeset.get_attribute(changeset, :parent_chat_id)
    message_id = Changeset.get_attribute(changeset, :parent_message_id)
    item_id = Changeset.get_attribute(changeset, :parent_tool_call_item_id)

    with %{id: ^owner_id} when not is_nil(owner_id) <- actor,
         :fork <- Changeset.get_attribute(changeset, :parent_relation_kind),
         {:ok, %{owner_id: ^owner_id}} <- owned(Chat, chat_id, actor),
         {:ok, %{owner_id: ^owner_id, chat_id: ^chat_id, role: :assistant}} <-
           owned(ChatMessage, message_id, actor),
         {:ok, %{owner_id: ^owner_id, chat_message_id: ^message_id}} <-
           owned(ChatMessageStep, source_id, actor),
         {:ok, %{owner_id: ^owner_id, chat_message_step_id: ^source_id, type: :tool_call}} <-
           owned(ChatMessageItem, item_id, actor),
         :ok <- acyclic_parent(chat_id, changeset.data.id, actor, MapSet.new()) do
      changeset
    else
      _ -> invalid(changeset, "must reference an owned source chat, message, step and tool call")
    end
  end

  defp owned(resource, id, actor) when is_integer(id), do: Ash.get(resource, id, actor: actor)
  defp owned(_resource, _id, _actor), do: {:error, :invalid_anchor}

  defp acyclic_parent(nil, _target_id, _actor, _visited), do: :ok

  defp acyclic_parent(id, target_id, actor, visited) do
    if id == target_id or MapSet.member?(visited, id) do
      {:error, :cycle}
    else
      with {:ok, chat} <- owned(Chat, id, actor) do
        acyclic_parent(chat.parent_chat_id, target_id, actor, MapSet.put(visited, id))
      end
    end
  end

  defp invalid(changeset, message) do
    Changeset.add_error(changeset, field: :fork_source_step_id, message: message)
  end
end
