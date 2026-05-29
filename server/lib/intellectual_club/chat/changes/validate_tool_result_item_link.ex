defmodule IntellectualClub.Chat.Changes.ValidateToolResultItemLink do
  @moduledoc """
  Validates the canonical link from a tool result item to its tool call item.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Chat.ChatMessageItem

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      type = changeset_attribute(changeset, :type)
      tool_call_item_id = changeset_attribute(changeset, :tool_call_item_id)

      cond do
        type != :tool_result ->
          Changeset.force_change_attribute(changeset, :tool_call_item_id, nil)

        is_nil(tool_call_item_id) ->
          Changeset.add_error(changeset,
            field: :tool_call_item_id,
            message: "is required for tool result items"
          )

        true ->
          validate_tool_call_item(changeset, tool_call_item_id)
      end
    end)
  end

  defp validate_tool_call_item(changeset, tool_call_item_id) when is_integer(tool_call_item_id) do
    actor = changeset.context[:private][:actor]

    case Ash.get(ChatMessageItem, tool_call_item_id, actor: actor) do
      {:ok, %ChatMessageItem{} = tool_call_item} ->
        expected_step_id = changeset_attribute(changeset, :chat_message_step_id)
        expected_owner_id = changeset_attribute(changeset, :owner_id)

        cond do
          tool_call_item.type != :tool_call ->
            invalid_link(changeset)

          not is_nil(expected_step_id) and tool_call_item.chat_message_step_id != expected_step_id ->
            invalid_link(changeset)

          not is_nil(expected_owner_id) and tool_call_item.owner_id != expected_owner_id ->
            invalid_link(changeset)

          true ->
            changeset
        end

      _other ->
        invalid_link(changeset)
    end
  end

  defp validate_tool_call_item(changeset, _tool_call_item_id), do: invalid_link(changeset)

  defp changeset_attribute(changeset, field) when is_atom(field) do
    Changeset.get_attribute(changeset, field) || Map.get(changeset.data || %{}, field)
  end

  defp invalid_link(changeset) do
    Changeset.add_error(changeset,
      field: :tool_call_item_id,
      message: "must reference a tool call item from the same step"
    )
  end
end
