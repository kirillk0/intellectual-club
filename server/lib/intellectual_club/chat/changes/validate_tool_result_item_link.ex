defmodule IntellectualClub.Chat.Changes.ValidateToolResultItemLink do
  @moduledoc """
  Validates the canonical link from a tool result item to its tool call item.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Chat.ChatMessageItem

  @impl true
  def batch_callbacks?(_changesets, _opts, context), do: Map.get(context, :bulk?, false)

  @impl true
  def batch_change(changesets, _opts, _context), do: changesets

  @impl true
  def before_batch(changesets, _opts, %{actor: actor}) do
    ids =
      changesets
      |> Enum.filter(&(changeset_attribute(&1, :type) == :tool_result))
      |> Enum.map(&changeset_attribute(&1, :tool_call_item_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    calls =
      if ids == [] do
        %{}
      else
        ChatMessageItem
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.select([:id, :type, :chat_message_step_id, :owner_id])
        |> Ash.read!(actor: actor, authorize?: true)
        |> Map.new(&{&1.id, &1})
      end

    Enum.map(changesets, fn changeset ->
      if changeset_attribute(changeset, :type) == :tool_result do
        validate_call(
          changeset,
          Map.get(calls, changeset_attribute(changeset, :tool_call_item_id))
        )
      else
        Changeset.force_change_attribute(changeset, :tool_call_item_id, nil)
      end
    end)
  end

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
        validate_call(changeset, tool_call_item)

      _other ->
        invalid_link(changeset)
    end
  end

  defp validate_tool_call_item(changeset, _tool_call_item_id), do: invalid_link(changeset)

  defp validate_call(changeset, %ChatMessageItem{type: :tool_call} = call) do
    step_id = changeset_attribute(changeset, :chat_message_step_id)
    owner_id = changeset_attribute(changeset, :owner_id)

    if (is_nil(step_id) or call.chat_message_step_id == step_id) and
         (is_nil(owner_id) or call.owner_id == owner_id),
       do: changeset,
       else: invalid_link(changeset)
  end

  defp validate_call(changeset, _call), do: invalid_link(changeset)

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
