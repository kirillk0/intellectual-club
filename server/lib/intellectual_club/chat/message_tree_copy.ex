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
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.RequestImages.Walker
  alias IntellectualClub.Llm.LlmConfiguration

  require Ash.Query

  @doc """
  Materializes request-image markers for already loaded source messages.

  Callers must run this before opening any transaction that copies or moves the
  messages. The source message and every source step are re-authorized for the
  supplied actor before the internal materializer is invoked.
  """
  @spec materialize_loaded_messages([ChatMessage.t()], map()) ::
          {:ok, [ChatMessage.t()]} | {:error, term()}
  def materialize_loaded_messages(messages, actor) when is_list(messages) and is_map(actor) do
    Enum.reduce_while(messages, {:ok, messages}, fn message, {:ok, messages} ->
      case materialize_loaded_message(message, actor) do
        :ok -> {:cont, {:ok, messages}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def materialize_loaded_messages(_messages, _actor),
    do: {:error, :invalid_loaded_messages}

  @spec materialize_loaded_messages!([ChatMessage.t()], map()) :: [ChatMessage.t()]
  def materialize_loaded_messages!(messages, actor) do
    case materialize_loaded_messages(messages, actor) do
      {:ok, messages} ->
        messages

      {:error, reason} ->
        raise "Failed to materialize copied request files: #{inspect(reason)}"
    end
  end

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
        request_files: [
          :reference_key,
          :source_file_external_id,
          :variant_key,
          file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
        ],
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
  defp copy_message_status(status) when status in [:done, :canceled, :error], do: status
  defp copy_message_status(_status), do: :done

  defp copy_error_detail(%ChatMessage{status: :generating}) do
    "Copied from an active generation."
  end

  defp copy_error_detail(%ChatMessage{error_detail: error_detail}), do: error_detail

  defp copy_step!(%ChatMessageStep{} = step, %ChatMessage{} = copied_message, actor) do
    source_step =
      Ash.get!(ChatMessageStep, step.id,
        actor: actor,
        load: [request_files: [:reference_key, :source_file_external_id]]
      )

    ensure_request_markers_bound!(source_step)

    copied =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: copied_message.id,
          sequence: source_step.sequence,
          status: copy_step_status(source_step.status),
          raw_request: source_step.raw_request || %{},
          raw_response: source_step.raw_response,
          response_final: source_step.response_final || false,
          input_tokens: source_step.input_tokens,
          output_tokens: source_step.output_tokens,
          cached_input_tokens: source_step.cached_input_tokens,
          reasoning_tokens: source_step.reasoning_tokens,
          cost: source_step.cost,
          first_token_at: source_step.first_token_at
        },
        actor: actor
      )
      |> Ash.create!()

    :ok = clone_request_files!(source_step.id, copied.id)

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

  defp copy_step_status(status) when status in [:done, :canceled, :error], do: status
  defp copy_step_status(_status), do: :done

  defp materialize_loaded_message(%ChatMessage{id: message_id}, actor)
       when is_integer(message_id) do
    with {:ok, %ChatMessage{}} <- Ash.get(ChatMessage, message_id, actor: actor),
         {:ok, steps} <- authorized_steps_for_message(message_id, actor) do
      Enum.reduce_while(ordered(steps), :ok, fn step, :ok ->
        case materialize_authorized_step(step, message_id, actor) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp materialize_loaded_message(_message, _actor),
    do: {:error, :invalid_loaded_message}

  defp authorized_steps_for_message(message_id, actor) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^message_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.read(actor: actor)
  end

  defp materialize_authorized_step(%ChatMessageStep{id: step_id}, message_id, actor)
       when is_integer(step_id) do
    with {:ok, %ChatMessageStep{} = step} <- Ash.get(ChatMessageStep, step_id, actor: actor),
         true <- step.chat_message_id == message_id,
         {:ok, _compact_request} <-
           RequestImages.materialize_and_persist(step.raw_request || %{}, step.id) do
      :ok
    else
      false -> {:error, {:request_step_message_mismatch, step_id, message_id}}
      {:error, reason} -> {:error, {:request_file_materialization_failed, step_id, reason}}
    end
  end

  defp materialize_authorized_step(_step, message_id, _actor),
    do: {:error, {:invalid_request_step, message_id}}

  defp ensure_request_markers_bound!(%ChatMessageStep{} = step) do
    {_request, descriptors} =
      Walker.map_images(step.raw_request || %{}, %{}, fn _shape, block, marker, descriptors ->
        reference_key = Map.get(marker, "reference_key")
        source_file_external_id = Map.get(marker, "source_file_external_id")

        if is_binary(reference_key) and is_binary(source_file_external_id) do
          case Map.get(descriptors, reference_key) do
            nil ->
              {block, Map.put(descriptors, reference_key, source_file_external_id)}

            ^source_file_external_id ->
              {block, descriptors}

            other_source_file_external_id ->
              raise "Conflicting source files for copied request reference #{reference_key}: #{other_source_file_external_id} and #{source_file_external_id}"
          end
        else
          raise "Invalid request file marker on copied step #{step.id}"
        end
      end)

    bound_descriptors =
      step.request_files
      |> Map.new(fn binding ->
        {to_string(binding.reference_key), to_string(binding.source_file_external_id)}
      end)

    missing = Map.keys(descriptors) -- Map.keys(bound_descriptors)

    if missing != [] do
      raise "Copied step #{step.id} has unresolved request file references: #{inspect(missing)}"
    end

    mismatched =
      Enum.filter(descriptors, fn {reference_key, source_file_external_id} ->
        Map.get(bound_descriptors, reference_key) != source_file_external_id
      end)

    if mismatched != [] do
      raise "Copied step #{step.id} has mismatched request file sources: #{inspect(mismatched)}"
    end

    :ok
  end

  defp clone_request_files!(source_step_id, target_step_id) do
    case RequestImages.clone_bindings(source_step_id, target_step_id) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to copy request files: #{inspect(reason)}"
    end
  end

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
