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
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Generation.RequestImages.Walker
  alias IntellectualClub.Llm.LlmConfiguration

  require Ash.Query

  @request_fields [
    :request_mode,
    :raw_request,
    :request_patch,
    :request_hash,
    :request_base_hash,
    :request_base_sequence,
    :request_checkpoint_distance
  ]

  @doc """
  Checks read access to a loaded copy snapshot without repairing its source.
  Request files are immutable pins; copying must never materialize source steps.
  """
  @spec prepare_loaded_messages([ChatMessage.t()], map()) ::
          {:ok, [ChatMessage.t()]} | {:error, term()}
  def prepare_loaded_messages(messages, actor) when is_list(messages) and is_map(actor) do
    message_ids = Enum.map(messages, & &1.id)

    readable_ids =
      ChatMessage
      |> Ash.Query.filter(id in ^message_ids)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: actor)
      |> MapSet.new(& &1.id)

    if MapSet.equal?(readable_ids, MapSet.new(message_ids)) do
      {:ok, messages}
    else
      {:error, :copy_source_unavailable}
    end
  rescue
    error -> {:error, error}
  end

  def prepare_loaded_messages(_messages, _actor), do: {:error, :invalid_loaded_messages}

  @spec prepare_loaded_messages!([ChatMessage.t()], map()) :: [ChatMessage.t()]
  def prepare_loaded_messages!(messages, actor) do
    case prepare_loaded_messages(messages, actor) do
      {:ok, messages} -> messages
      {:error, reason} -> raise "Copy source is unavailable: #{inspect(reason)}"
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
    messages = prepare_loaded_messages!(messages, actor)
    steps = Enum.flat_map(messages, &ordered(&1.steps))
    requests = StepRequests.requests_for_steps!(steps, actor: actor)

    # Cache only this copy's configuration selection. The message create action
    # still authorizes every related configuration before persisting its ID.
    configuration_ids =
      messages
      |> Enum.map(& &1.llm_configuration_id)
      |> Enum.uniq()
      |> Map.new(&{&1, readable_llm_configuration_id(&1, actor)})

    Enum.reduce(messages, copied_ids, fn message, copied_ids ->
      copied =
        copy_message!(
          message,
          target,
          copied_ids,
          actor,
          requests,
          Map.fetch!(configuration_ids, message.llm_configuration_id)
        )

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
        :request_mode,
        :request_patch,
        :request_hash,
        :request_base_hash,
        :request_base_sequence,
        :request_checkpoint_distance,
        :raw_response,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :cost,
        :first_token_at,
        :last_token_at,
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

  defp copy_message!(
         %ChatMessage{} = message,
         %Chat{} = target,
         copied_ids,
         actor,
         requests,
         configuration_id
       ) do
    copied =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: target.id,
          role: message.role,
          parent_id: mapped_parent_id(message.parent_id, copied_ids),
          llm_configuration_id: configuration_id,
          status: copy_message_status(message.status),
          error_detail: copy_error_detail(message),
          token_count: message.token_count || 0
        },
        actor: actor
      )
      |> Ash.create!()

    {item_groups, _previous} =
      Enum.map_reduce(ordered(message.steps), nil, fn step, previous ->
        request = Map.fetch!(requests, step.id)
        copied_step = copy_step!(step, copied, actor, request, previous)
        {{copied_step.id, ordered(step.items)}, %{step: copied_step, request: request}}
      end)

    copy_message_items!(item_groups, actor)
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

  defp copy_step!(%ChatMessageStep{} = source_step, copied_message, actor, request, previous) do
    ensure_request_markers_bound!(source_step, request)
    request_attrs = copy_request_attributes(source_step, request, previous)

    copied =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_id: copied_message.id,
          sequence: source_step.sequence,
          status: copy_step_status(source_step.status),
          raw_response: source_step.raw_response,
          response_final: source_step.response_final || false,
          input_tokens: source_step.input_tokens,
          output_tokens: source_step.output_tokens,
          cached_input_tokens: source_step.cached_input_tokens,
          reasoning_tokens: source_step.reasoning_tokens,
          cost: source_step.cost,
          first_token_at: source_step.first_token_at,
          last_token_at: source_step.last_token_at
        }
        |> Map.merge(request_attrs),
        actor: actor,
        private_arguments: %{request_base: previous && previous.request}
      )
      |> Ash.create!()

    :ok = clone_request_files!(source_step.id, copied.id)
    :ok = ensure_copied_request_files!(source_step, copied, request, actor)

    copied
  end

  defp copy_request_attributes(step, request, previous) do
    previous_step = previous && previous.step

    closed_chain? =
      step.request_mode == :full or
        (not is_nil(previous_step) and step.request_base_sequence == previous_step.sequence and
           step.request_base_hash == previous_step.request_hash and
           step.request_checkpoint_distance == previous_step.request_checkpoint_distance + 1)

    if closed_chain? do
      # The authorized reader already loaded and verified this logical request.
      # Keep its physical encoding without loading large full bodies twice.
      Map.take(step, @request_fields)
      |> Map.put(:raw_request, if(step.request_mode == :full, do: request, else: %{}))
    else
      StepRequests.create_attributes(request,
        sequence: step.sequence,
        previous_request: previous && previous.request,
        previous_step: previous_step,
        force_full: is_nil(previous_step)
      )
    end
  end

  defp copy_message_items!(item_groups, actor) do
    ordinary_copies =
      item_groups
      |> Enum.flat_map(fn {step_id, items} ->
        items
        |> Enum.reject(&(item_type(&1) == :tool_result))
        |> Enum.map(&item_attrs(&1, step_id, nil))
      end)
      |> bulk_create!(ChatMessageItem, actor)

    ordinary_by_step = Enum.group_by(ordinary_copies, & &1.chat_message_step_id)

    result_copies =
      item_groups
      |> Enum.flat_map(fn {step_id, items} ->
        tool_result_inputs(items, Map.get(ordinary_by_step, step_id, []), step_id)
      end)
      |> bulk_create!(ChatMessageItem, actor)

    # Bulk results need not preserve input order, and item sequences repeat in
    # each step. Resolve both contents and tool links within their copied step.
    copies_by_step_sequence =
      Map.new(ordinary_copies ++ result_copies, &{{&1.chat_message_step_id, &1.sequence}, &1})

    item_groups
    |> Enum.flat_map(fn {step_id, items} ->
      Enum.flat_map(items, fn item ->
        case Map.get(copies_by_step_sequence, {step_id, item.sequence}) do
          nil -> []
          copied_item -> Enum.map(ordered(item.contents), &content_attrs(&1, copied_item.id))
        end
      end)
    end)
    |> bulk_create!(ChatMessageContent, actor)

    :ok
  end

  defp tool_result_inputs(items, ordinary_copies, step_id) do
    ordinary_by_sequence = Map.new(ordinary_copies, &{&1.sequence, &1})

    copied_by_source_id =
      items
      |> Enum.reject(&(item_type(&1) == :tool_result))
      |> Map.new(fn item ->
        {item.id, Map.fetch!(ordinary_by_sequence, item.sequence)}
      end)

    tool_call_ids =
      ordinary_copies
      |> Enum.filter(&(&1.type == :tool_call))
      |> Map.new(&{&1.sequence, &1.id})

    items
    |> Enum.filter(&(item_type(&1) == :tool_result))
    |> Enum.flat_map(fn item ->
      copied_call = Map.get(copied_by_source_id, item.tool_call_item_id)

      call_id =
        (copied_call && copied_call.id) || preceding_tool_call_item_id(item, tool_call_ids)

      if is_integer(call_id), do: [item_attrs(item, step_id, call_id)], else: []
    end)
  end

  defp item_attrs(item, step_id, call_id) do
    %{
      chat_message_step_id: step_id,
      sequence: item.sequence,
      type: item.type,
      tool_call_item_id: call_id
    }
  end

  defp content_attrs(content, item_id) do
    %{
      chat_message_item_id: item_id,
      sequence: content.sequence,
      kind: content.kind,
      content_text: content.content_text || "",
      content_json: content.content_json,
      file_id: duplicate_file_id!(content.file_id)
    }
  end

  defp bulk_create!([], _resource, _actor), do: []

  defp bulk_create!(inputs, resource, actor) do
    case Ash.bulk_create(inputs, resource, :create,
           actor: actor,
           return_records?: true,
           return_errors?: true,
           stop_on_error?: true,
           transaction: :all,
           batch_size: 250
         ) do
      %Ash.BulkResult{status: :success, records: records} -> records
      result -> raise "Failed to copy trace records: #{inspect(result.errors)}"
    end
  end

  defp copy_step_status(status) when status in [:waiting_provider, :waiting_tools],
    do: :canceled

  defp copy_step_status(status) when status in [:done, :canceled, :error], do: status
  defp copy_step_status(_status), do: :done

  defp ensure_request_markers_bound!(%ChatMessageStep{} = step, request) do
    {_request, descriptors} =
      Walker.map_images(request, %{}, fn _shape, block, marker, descriptors ->
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

  defp ensure_copied_request_files!(%{request_files: []}, _copied, _request, _actor), do: :ok

  defp ensure_copied_request_files!(source, copied, request, actor) do
    target =
      Ash.load!(
        copied,
        [
          request_files: [
            :reference_key,
            :source_file_external_id,
            :variant_key,
            file: [:id, :sha256, :size_bytes]
          ]
        ],
        actor: actor
      )

    ensure_request_markers_bound!(target, request)

    unless request_pin_identity(source.request_files) ==
             request_pin_identity(target.request_files) do
      raise "Request file snapshot changed while copying step #{source.id}"
    end

    :ok
  end

  defp request_pin_identity(bindings) do
    Map.new(bindings, fn binding ->
      {to_string(binding.reference_key),
       {to_string(binding.source_file_external_id), binding.variant_key, binding.file.sha256,
        binding.file.size_bytes}}
    end)
  end

  defp clone_request_files!(source_step_id, target_step_id) do
    case RequestImages.clone_bindings(source_step_id, target_step_id) do
      :ok -> :ok
      {:error, reason} -> raise "Failed to copy request files: #{inspect(reason)}"
    end
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
