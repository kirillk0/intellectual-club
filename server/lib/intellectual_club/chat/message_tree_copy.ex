defmodule IntellectualClub.Chat.MessageTreeCopy do
  @moduledoc """
  Copies chat message trees with their persisted generation trace.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Files
  alias IntellectualClub.Llm.LlmConfiguration

  @spec copy_messages!([ChatMessage.t()], Chat.t(), map()) :: %{integer() => integer()}
  def copy_messages!(messages, %Chat{} = target, actor) when is_list(messages) do
    copy_messages!(messages, target, %{}, actor)
  end

  @spec copy_messages!([ChatMessage.t()], Chat.t(), %{integer() => integer()}, map()) ::
          %{integer() => integer()}
  def copy_messages!(messages, %Chat{} = target, copied_ids, actor)
      when is_list(messages) and is_map(copied_ids) do
    Enum.reduce(messages, copied_ids, fn message, copied_ids ->
      copied = copy_message!(message, target, copied_ids, actor)
      Map.put(copied_ids, message.id, copied.id)
    end)
  end

  @spec load_spec() :: list()
  def load_spec do
    [
      :id,
      :role,
      :parent_id,
      :llm_configuration_id,
      :status,
      :error_detail,
      :token_count,
      steps: [
        :id,
        :sequence,
        :status,
        :raw_request,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at,
        items: [
          :id,
          :sequence,
          :type,
          :tool_call_item_id,
          contents: [
            :id,
            :sequence,
            :kind,
            :content_text,
            :content_json,
            :file_id
          ]
        ]
      ]
    ]
  end

  defp copy_message!(%ChatMessage{} = message, %Chat{} = target, copied_ids, actor) do
    copied =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: target.id,
          role: message.role,
          parent_id: mapped_parent_id(message.parent_id, copied_ids),
          llm_configuration_id:
            readable_llm_configuration_id(message.llm_configuration_id, actor),
          status: copy_message_status(message.status),
          error_detail: copy_error_detail(message),
          token_count: message.token_count || 0
        },
        actor: actor
      )
      |> Ash.create!()

    Enum.each(ordered(message.steps), &copy_step!(&1, copied, actor))
    copied
  end

  defp mapped_parent_id(nil, _copied_ids), do: nil

  defp mapped_parent_id(parent_id, copied_ids) when is_integer(parent_id) do
    Map.fetch!(copied_ids, parent_id)
  end

  defp copy_message_status(:generating), do: :canceled
  defp copy_message_status("generating"), do: :canceled
  defp copy_message_status(status) when status in [:done, :canceled, :error], do: status
  defp copy_message_status(status) when status in ["done", "canceled", "error"], do: status
  defp copy_message_status(_status), do: :done

  defp copy_error_detail(%ChatMessage{status: status})
       when status in [:generating, "generating"] do
    "Copied from an active generation."
  end

  defp copy_error_detail(%ChatMessage{error_detail: error_detail}), do: error_detail

  defp copy_step!(%ChatMessageStep{} = step, %ChatMessage{} = copied_message, actor) do
    copied =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: copied_message.id,
          sequence: step.sequence,
          status: copy_step_status(step.status),
          raw_request: step.raw_request || %{},
          raw_response: step.raw_response,
          response_final: step.response_final || false,
          input_tokens: step.input_tokens,
          output_tokens: step.output_tokens,
          cached_input_tokens: step.cached_input_tokens,
          reasoning_tokens: step.reasoning_tokens,
          cost: step.cost,
          first_token_at: step.first_token_at
        },
        actor: actor
      )
      |> Ash.create!()

    items = ordered(step.items)

    {copied_items_by_source_id, copied_tool_call_ids_by_sequence} =
      items
      |> Enum.reject(&(item_type(&1) == :tool_result))
      |> Enum.reduce({%{}, %{}}, fn item, {by_source_id, by_sequence} ->
        copied_item = copy_item!(item, copied, actor, nil)

        by_sequence =
          if item_type(item) == :tool_call do
            Map.put(by_sequence, item.sequence, copied_item.id)
          else
            by_sequence
          end

        {Map.put(by_source_id, item.id, copied_item), by_sequence}
      end)

    items
    |> Enum.filter(&(item_type(&1) == :tool_result))
    |> Enum.each(fn item ->
      tool_call_item_id =
        item
        |> Map.get(:tool_call_item_id)
        |> case do
          source_id when is_integer(source_id) ->
            case Map.get(copied_items_by_source_id, source_id) do
              %ChatMessageItem{id: copied_id} -> copied_id
              _other -> nil
            end

          _other ->
            nil
        end

      tool_call_item_id =
        tool_call_item_id || preceding_tool_call_item_id(item, copied_tool_call_ids_by_sequence)

      if is_integer(tool_call_item_id) do
        copy_item!(item, copied, actor, tool_call_item_id)
      end
    end)
  end

  defp copy_step_status(status) when status in [:waiting_provider, :waiting_tools],
    do: :canceled

  defp copy_step_status(status) when status in ["waiting_provider", "waiting_tools"],
    do: :canceled

  defp copy_step_status(status) when status in [:done, :canceled, :error], do: status
  defp copy_step_status(status) when status in ["done", "canceled", "error"], do: status
  defp copy_step_status(_status), do: :done

  defp copy_item!(
         %ChatMessageItem{} = item,
         %ChatMessageStep{} = copied_step,
         actor,
         tool_call_item_id
       ) do
    copied =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_step_id: copied_step.id,
          sequence: item.sequence,
          type: item.type,
          tool_call_item_id: tool_call_item_id
        },
        actor: actor
      )
      |> Ash.create!()

    Enum.each(ordered(item.contents), &copy_content!(&1, copied, actor))
    copied
  end

  defp item_type(%ChatMessageItem{type: type}), do: type

  defp preceding_tool_call_item_id(%ChatMessageItem{} = item, copied_tool_call_ids_by_sequence) do
    copied_tool_call_ids_by_sequence
    |> Enum.filter(fn {sequence, _id} -> sequence < item.sequence end)
    |> Enum.max_by(fn {sequence, _id} -> sequence end, fn -> nil end)
    |> case do
      {_sequence, id} -> id
      nil -> nil
    end
  end

  defp copy_content!(%ChatMessageContent{} = content, %ChatMessageItem{} = copied_item, actor) do
    file_id = duplicate_file_id!(content.file_id)

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: copied_item.id,
        sequence: content.sequence,
        kind: content.kind,
        content_text: content.content_text || "",
        content_json: content.content_json,
        file_id: file_id
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp duplicate_file_id!(file_id) when is_integer(file_id) do
    case Files.duplicate_file(file_id) do
      {:ok, file} -> file.id
      {:error, error} -> raise "Failed to duplicate chat attachment: #{inspect(error)}"
    end
  end

  defp duplicate_file_id!(_file_id), do: nil

  defp readable_llm_configuration_id(value, actor) when is_integer(value) do
    case Ash.get(LlmConfiguration, value, actor: actor) do
      {:ok, %LlmConfiguration{id: id}} -> id
      _other -> nil
    end
  end

  defp readable_llm_configuration_id(_value, _actor), do: nil

  defp ordered(values) when is_list(values) do
    Enum.sort_by(values, fn value ->
      {Map.get(value, :sequence) || 0, Map.get(value, :id) || 0}
    end)
  end

  defp ordered(_values), do: []
end
