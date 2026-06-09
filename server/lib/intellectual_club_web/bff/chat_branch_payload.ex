defmodule IntellectualClubWeb.Bff.ChatBranchPayload do
  @moduledoc """
  Lean chat branch payload builder for SPA chat state and polling.
  """

  alias IntellectualClub.Chat.Bookmarking
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  @display_item_types [:input, :answer, :artifact]
  @display_content_kinds [:text, :media]
  @chunk_size 500

  def branch(messages, branch_meta_by_id, actor, opts \\ []) when is_list(messages) do
    runtime_steps_by_message_id = Keyword.get(opts, :runtime_steps_by_message_id, %{})
    message_ids = messages |> Enum.map(& &1.id) |> Enum.filter(&is_integer/1) |> Enum.uniq()

    steps = read_steps_for_messages(message_ids, actor)
    display = read_display_payload(steps, actor)
    retry_errors_by_message_id = read_retry_error_payload(steps, actor)
    steps_by_message_id = Enum.group_by(steps, & &1.chat_message_id)

    bookmarked_message_ids = Bookmarking.bookmarked_message_id_set(message_ids, actor)

    Enum.map(messages, fn message ->
      runtime_step = Map.get(runtime_steps_by_message_id, message.id)

      extras =
        extras_for_message(
          message,
          Map.get(steps_by_message_id, message.id, []),
          display,
          Map.get(retry_errors_by_message_id, message.id, []),
          runtime_step
        )

      Serializer.branch_message_light(message, branch_meta_by_id, bookmarked_message_ids, extras)
    end)
  end

  def message(%ChatMessage{} = message, actor, opts \\ []) do
    branch([message], %{}, actor, opts)
    |> List.first()
  end

  def working_payload(message_id, requested_step_id, actor) when is_integer(message_id) do
    with {:ok, %ChatMessage{} = _message} <- Ash.get(ChatMessage, message_id, actor: actor) do
      steps = read_steps_for_messages([message_id], actor)
      summaries = steps |> Enum.map(&Serializer.working_step_summary/1) |> sort_by_sequence()
      selected_step_id = resolve_selected_step_id(summaries, requested_step_id)

      step =
        if selected_step_id, do: load_step_detail(message_id, selected_step_id, actor), else: nil

      if is_integer(selected_step_id) and is_nil(step) do
        {:error, :not_found}
      else
        {:ok,
         %{
           message_id: message_id,
           step_count: length(summaries),
           steps: summaries,
           selected_step_id: selected_step_id,
           step: if(step, do: Serializer.step(step), else: nil)
         }}
      end
    end
  end

  defp extras_for_message(%ChatMessage{} = message, steps, display, retry_errors, runtime_step) do
    steps = sort_by_sequence(steps)
    persisted_summaries = Enum.map(steps, &Serializer.working_step_summary/1)

    runtime_summary =
      if runtime_step, do: Serializer.working_step_summary(runtime_step), else: nil

    summaries = maybe_upsert_runtime_summary(persisted_summaries, runtime_summary)

    persisted_content = display_content_for_message(message, steps, display)
    runtime_content = runtime_content_for_message(message, runtime_step)
    content = merge_runtime_content(persisted_content, runtime_content)

    %{
      content: content,
      usage: Serializer.usage_summary(summaries),
      working: Serializer.working_summary(summaries, retry_errors)
    }
  end

  defp read_steps_for_messages([], _actor), do: []

  defp read_steps_for_messages(message_ids, actor) when is_list(message_ids) do
    message_ids
    |> chunk_ids()
    |> Enum.flat_map(fn chunk ->
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id in ^chunk)
      |> Ash.Query.select([
        :id,
        :chat_message_id,
        :sequence,
        :created_at,
        :finished_at,
        :status,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :first_token_at,
        :cost
      ])
      |> Ash.read!(actor: actor)
    end)
  end

  defp read_display_payload([], _actor) do
    %{items_by_step_id: %{}, contents_by_item_id: %{}}
  end

  defp read_display_payload(steps, actor) when is_list(steps) do
    step_ids = steps |> Enum.map(& &1.id) |> Enum.filter(&is_integer/1) |> Enum.uniq()

    items =
      step_ids
      |> chunk_ids()
      |> Enum.flat_map(fn chunk ->
        ChatMessageItem
        |> Ash.Query.filter(chat_message_step_id in ^chunk and type in ^@display_item_types)
        |> Ash.Query.select([
          :id,
          :chat_message_step_id,
          :sequence,
          :created_at,
          :type,
          :tool_call_item_id
        ])
        |> Ash.read!(actor: actor)
      end)

    item_ids = items |> Enum.map(& &1.id) |> Enum.filter(&is_integer/1) |> Enum.uniq()

    contents =
      item_ids
      |> chunk_ids()
      |> Enum.flat_map(fn chunk ->
        ChatMessageContent
        |> Ash.Query.filter(chat_message_item_id in ^chunk and kind in ^@display_content_kinds)
        |> Ash.Query.select([
          :id,
          :chat_message_item_id,
          :external_id,
          :sequence,
          :kind,
          :content_text,
          :content_json,
          :file_id
        ])
        |> Ash.Query.load(file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256])
        |> Ash.read!(actor: actor)
      end)

    %{
      items_by_step_id: Enum.group_by(items, & &1.chat_message_step_id),
      contents_by_item_id: Enum.group_by(contents, & &1.chat_message_item_id)
    }
  end

  defp read_retry_error_payload([], _actor), do: %{}

  defp read_retry_error_payload(steps, actor) when is_list(steps) do
    step_by_id =
      steps
      |> Enum.filter(
        &(is_integer(Map.get(&1, :id)) and is_integer(Map.get(&1, :chat_message_id)))
      )
      |> Map.new(&{&1.id, &1})

    step_ids = Map.keys(step_by_id)

    items =
      step_ids
      |> chunk_ids()
      |> Enum.flat_map(fn chunk ->
        ChatMessageItem
        |> Ash.Query.filter(chat_message_step_id in ^chunk and type == :error)
        |> Ash.Query.select([:id, :chat_message_step_id, :sequence, :created_at, :type])
        |> Ash.read!(actor: actor)
      end)

    item_ids = items |> Enum.map(& &1.id) |> Enum.filter(&is_integer/1) |> Enum.uniq()

    contents_by_item_id =
      item_ids
      |> chunk_ids()
      |> Enum.flat_map(fn chunk ->
        ChatMessageContent
        |> Ash.Query.filter(chat_message_item_id in ^chunk and kind in [:text, :opaque])
        |> Ash.Query.select([
          :id,
          :chat_message_item_id,
          :sequence,
          :kind,
          :content_text,
          :content_json
        ])
        |> Ash.read!(actor: actor)
      end)
      |> Enum.group_by(& &1.chat_message_item_id)

    items
    |> Enum.flat_map(fn item ->
      step = Map.get(step_by_id, item.chat_message_step_id)
      text = retry_error_item_text(item, contents_by_item_id)
      metadata = retry_error_item_metadata(item, contents_by_item_id)

      if is_nil(step) or String.trim(text) == "" or not retry_error_diagnostic_metadata?(metadata) do
        []
      else
        [
          %{
            message_id: step.chat_message_id,
            step_id: step.id,
            step_sequence: step.sequence,
            item_id: item.id,
            item_sequence: item.sequence,
            text: text,
            created_at: item.created_at || step.created_at
          }
        ]
      end
    end)
    |> Enum.group_by(&Map.get(&1, :message_id))
  end

  defp retry_error_item_text(%ChatMessageItem{} = item, contents_by_item_id)
       when is_map(contents_by_item_id) do
    contents_by_item_id
    |> Map.get(item.id, [])
    |> sort_by_sequence()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("", &to_string(Map.get(&1, :content_text) || ""))
  end

  defp retry_error_item_metadata(%ChatMessageItem{} = item, contents_by_item_id)
       when is_map(contents_by_item_id) do
    contents_by_item_id
    |> Map.get(item.id, [])
    |> sort_by_sequence()
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.map(&Map.get(&1, :content_json))
    |> Enum.find(%{}, &retry_error_diagnostic_metadata?/1)
  end

  defp retry_error_diagnostic_metadata?(%{} = metadata) do
    Map.get(metadata, "retryable") == true and is_integer(Map.get(metadata, "attempt"))
  end

  defp retry_error_diagnostic_metadata?(_metadata), do: false

  defp display_content_for_message(%ChatMessage{} = message, steps, display) do
    role = atom_to_string(message.role)

    {parts, media} =
      Enum.reduce(steps, {[], []}, fn step, {parts_acc, media_acc} ->
        items =
          display
          |> Map.get(:items_by_step_id, %{})
          |> Map.get(step.id, [])
          |> sort_by_sequence()

        Enum.reduce(items, {parts_acc, media_acc}, fn item, {parts_acc, media_acc} ->
          contents =
            display
            |> Map.get(:contents_by_item_id, %{})
            |> Map.get(item.id, [])
            |> sort_by_sequence()

          parts_acc =
            if text_item_for_role?(item, role) do
              text_parts =
                contents
                |> Enum.filter(&(kind_string(&1) == "text"))
                |> Enum.map(&Serializer.message_content_snapshot(&1, item, step))
                |> Enum.reject(&(to_string(Map.get(&1, :text) || "") == ""))

              parts_acc ++ text_parts
            else
              parts_acc
            end

          media_acc =
            if media_item_for_role?(item, role) do
              media_items =
                contents
                |> Enum.filter(&(kind_string(&1) == "media"))
                |> Enum.map(&Serializer.media_content_snapshot(&1, item, step))
                |> Enum.filter(&(Map.get(&1, :media) != nil))

              media_acc ++ media_items
            else
              media_acc
            end

          {parts_acc, media_acc}
        end)
      end)

    %{parts: parts, media: media}
  end

  defp runtime_content_for_message(_message, nil), do: %{parts: [], media: []}

  defp runtime_content_for_message(%ChatMessage{} = message, runtime_step)
       when is_map(runtime_step) do
    role = atom_to_string(message.role)
    step_id = map_get(runtime_step, :id, "id")
    step_sequence = map_get(runtime_step, :sequence, "sequence")
    step_created_at = map_get(runtime_step, :created_at, "created_at")

    items =
      runtime_step
      |> map_get(:items, "items", [])
      |> List.wrap()
      |> sort_by_sequence()

    {parts, media} =
      Enum.reduce(items, {[], []}, fn item, {parts_acc, media_acc} ->
        contents =
          item
          |> map_get(:contents, "contents", [])
          |> List.wrap()
          |> sort_by_sequence()

        item_type = item |> map_get(:type, "type") |> atom_to_string()
        item_id = map_get(item, :id, "id")
        item_sequence = map_get(item, :sequence, "sequence")
        item_created_at = map_get(item, :created_at, "created_at") || step_created_at

        parts_acc =
          if text_item_for_role?(item_type, role) do
            text_parts =
              contents
              |> Enum.filter(&(kind_string(&1) == "text"))
              |> Enum.map(fn content ->
                %{
                  step_id: step_id,
                  step_sequence: step_sequence,
                  item_id: item_id,
                  item_sequence: item_sequence,
                  content_id: map_get(content, :id, "id"),
                  sequence: map_get(content, :sequence, "sequence"),
                  text: to_string(map_get(content, :content_text, "content_text", "")),
                  content_text_truncated:
                    map_get(content, :content_text_truncated, "content_text_truncated") == true,
                  created_at: item_created_at
                }
              end)
              |> Enum.reject(&(to_string(Map.get(&1, :text) || "") == ""))

            parts_acc ++ text_parts
          else
            parts_acc
          end

        media_acc =
          if media_item_for_role?(item_type, role) do
            media_items =
              contents
              |> Enum.filter(&(kind_string(&1) == "media"))
              |> Enum.map(fn content ->
                content
                |> normalize_runtime_content_media()
                |> Map.merge(%{
                  step_id: step_id,
                  step_sequence: step_sequence,
                  item_id: item_id,
                  item_sequence: item_sequence
                })
              end)
              |> Enum.filter(&(Map.get(&1, :media) != nil))

            media_acc ++ media_items
          else
            media_acc
          end

        {parts_acc, media_acc}
      end)

    %{parts: parts, media: media}
  end

  defp merge_runtime_content(persisted, %{parts: [], media: []}), do: persisted

  defp merge_runtime_content(persisted, runtime) do
    runtime_step_sequences =
      (Map.get(runtime, :parts, []) ++ Map.get(runtime, :media, []))
      |> Enum.map(&Map.get(&1, :step_sequence))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if MapSet.size(runtime_step_sequences) == 0 do
      persisted
    else
      %{
        parts:
          persisted
          |> Map.get(:parts, [])
          |> Enum.reject(&MapSet.member?(runtime_step_sequences, Map.get(&1, :step_sequence)))
          |> Kernel.++(Map.get(runtime, :parts, []))
          |> sort_by_part_sequence(),
        media:
          persisted
          |> Map.get(:media, [])
          |> Enum.reject(&MapSet.member?(runtime_step_sequences, Map.get(&1, :step_sequence)))
          |> Kernel.++(Map.get(runtime, :media, []))
          |> sort_by_part_sequence()
      }
    end
  end

  defp maybe_upsert_runtime_summary(summaries, nil), do: summaries

  defp maybe_upsert_runtime_summary(summaries, runtime_summary) when is_map(runtime_summary) do
    runtime_sequence = Map.get(runtime_summary, :sequence)
    runtime_id = Map.get(runtime_summary, :id)

    summaries
    |> Enum.reject(fn summary ->
      (not is_nil(runtime_sequence) and Map.get(summary, :sequence) == runtime_sequence) or
        (not is_nil(runtime_id) and Map.get(summary, :id) == runtime_id)
    end)
    |> Kernel.++([runtime_summary])
    |> sort_by_sequence()
  end

  defp resolve_selected_step_id([], _requested_step_id), do: nil
  defp resolve_selected_step_id(_summaries, step_id) when is_integer(step_id), do: step_id

  defp resolve_selected_step_id(summaries, _requested_step_id) do
    summaries
    |> sort_by_sequence()
    |> List.last()
    |> case do
      nil -> nil
      summary -> Map.get(summary, :id)
    end
  end

  defp load_step_detail(message_id, step_id, actor) do
    ChatMessageStep
    |> Ash.Query.filter(id == ^step_id and chat_message_id == ^message_id)
    |> Ash.Query.select([
      :id,
      :chat_message_id,
      :sequence,
      :created_at,
      :finished_at,
      :status,
      :response_final,
      :input_tokens,
      :output_tokens,
      :cached_input_tokens,
      :reasoning_tokens,
      :first_token_at,
      :cost
    ])
    |> Ash.Query.load(
      [
        items: [
          :id,
          :sequence,
          :created_at,
          :type,
          :tool_call_item_id,
          contents: [
            :id,
            :external_id,
            :sequence,
            :kind,
            :content_text,
            :content_json,
            :file_id,
            file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
          ]
        ]
      ],
      strict?: true
    )
    |> Ash.read!(actor: actor)
    |> List.first()
  end

  defp text_item_for_role?(%ChatMessageItem{} = item, role),
    do: text_item_for_role?(item.type, role)

  defp text_item_for_role?(item_type, "user"), do: atom_to_string(item_type) == "input"
  defp text_item_for_role?(item_type, "assistant"), do: atom_to_string(item_type) == "answer"
  defp text_item_for_role?(_item_type, _role), do: false

  defp media_item_for_role?(%ChatMessageItem{} = item, role),
    do: media_item_for_role?(item.type, role)

  defp media_item_for_role?(item_type, "user"), do: atom_to_string(item_type) == "input"
  defp media_item_for_role?(item_type, "assistant"), do: atom_to_string(item_type) == "artifact"
  defp media_item_for_role?(_item_type, _role), do: false

  defp normalize_runtime_content_media(content) when is_map(content) do
    %{
      id: map_get(content, :id, "id"),
      external_id: map_get(content, :external_id, "external_id"),
      sequence: map_get(content, :sequence, "sequence"),
      kind: kind_string(content),
      content_text: map_get(content, :content_text, "content_text"),
      content_text_truncated: map_get(content, :content_text_truncated, "content_text_truncated"),
      content_json: map_get(content, :content_json, "content_json"),
      media: map_get(content, :media, "media")
    }
  end

  defp kind_string(value), do: value |> map_get(:kind, "kind") |> atom_to_string()

  defp sort_by_sequence(values) when is_list(values) do
    Enum.sort_by(values, &{sequence_value(&1), id_value(&1)})
  end

  defp sort_by_part_sequence(values) when is_list(values) do
    Enum.sort_by(values, fn value ->
      {
        Map.get(value, :step_sequence) || 0,
        Map.get(value, :item_sequence) || 0,
        Map.get(value, :sequence) || 0,
        Map.get(value, :content_id) || Map.get(value, :id) || 0
      }
    end)
  end

  defp sequence_value(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sequence_value(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sequence_value(_value), do: 0

  defp id_value(%{id: id}) when is_integer(id), do: id
  defp id_value(%{"id" => id}) when is_integer(id), do: id
  defp id_value(_value), do: 0

  defp chunk_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk_size)
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value) when is_binary(value), do: value
  defp atom_to_string(value), do: to_string(value)

  defp map_get(map, atom_key, string_key, default \\ nil) when is_map(map) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end
end
