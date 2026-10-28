defmodule IntellectualClub.Chat.MessageText do
  @moduledoc """
  Actor-authorized user-facing message text and substring matching shared by
  Ash actions and the UI search. Tool calls, reasoning and opaque contents are
  deliberately excluded. Matching is within individual stored text contents.
  """

  alias Ash.CiString
  alias IntellectualClub.Chat.{ChatMessageContent, ChatMessageItem, ChatMessageStep}
  require Ash.Query

  @snippet_radius 240
  @trace_read_chunk_size 200
  @searchable_trace_item_types [
    :input,
    :handoff_request,
    :handoff_context,
    :handoff_history,
    :handoff_message,
    :answer,
    :handoff_summary
  ]

  def filter(query, {:contains, term}) when is_binary(term) do
    term = contains_query_term(term)

    Ash.Query.filter(
      query,
      exists(
        steps,
        exists(
          items,
          type in ^@searchable_trace_item_types and
            exists(
              contents,
              item_type in ^@searchable_trace_item_types and kind == :text and
                contains(content_text, ^term)
            )
        )
      )
    )
  end

  def load_texts([], _actor), do: %{}

  def load_texts(messages, actor) when is_list(messages) do
    message_ids =
      messages
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if message_ids == [] do
      %{}
    else
      wanted_type_by_message =
        Map.new(messages, fn message ->
          {message.id, wanted_trace_item_type(message)}
        end)

      steps = read_steps_for_messages(message_ids, actor)

      items =
        steps
        |> Enum.map(& &1.id)
        |> read_items_for_steps(actor)

      contents =
        items
        |> Enum.map(& &1.id)
        |> read_text_contents_for_items(actor)

      steps_by_message = Enum.group_by(steps, & &1.chat_message_id)
      items_by_step = Enum.group_by(items, & &1.chat_message_step_id)
      contents_by_item = Enum.group_by(contents, & &1.chat_message_item_id)

      Map.new(messages, fn message ->
        text =
          steps_by_message
          |> Map.get(message.id, [])
          |> Enum.sort_by(&sort_key/1)
          |> Enum.flat_map(fn step ->
            items_by_step
            |> Map.get(step.id, [])
            |> Enum.sort_by(&sort_key/1)
          end)
          |> Enum.filter(fn item ->
            trace_item_type_matches?(item, Map.get(wanted_type_by_message, message.id))
          end)
          |> Enum.map(fn item ->
            contents_by_item
            |> Map.get(item.id, [])
            |> Enum.sort_by(&sort_key/1)
            |> Enum.map_join("", fn content -> to_string(content.content_text || "") end)
          end)
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.join("\n\n")

        {message.id, text}
      end)
    end
  end

  defp read_steps_for_messages(message_ids, actor) when is_list(message_ids) do
    message_ids
    |> chunk_ids()
    |> Enum.flat_map(fn chunk ->
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id in ^chunk)
      |> Ash.Query.select([:id, :chat_message_id, :sequence])
      |> Ash.read!(actor: actor)
    end)
  end

  defp read_items_for_steps([], _actor), do: []

  defp read_items_for_steps(step_ids, actor) when is_list(step_ids) do
    step_ids
    |> chunk_ids()
    |> Enum.flat_map(fn chunk ->
      ChatMessageItem
      |> Ash.Query.filter(
        chat_message_step_id in ^chunk and type in ^@searchable_trace_item_types
      )
      |> Ash.Query.select([:id, :chat_message_step_id, :sequence, :type])
      |> Ash.read!(actor: actor)
    end)
  end

  defp read_text_contents_for_items([], _actor), do: []

  defp read_text_contents_for_items(item_ids, actor) when is_list(item_ids) do
    item_ids
    |> chunk_ids()
    |> Enum.flat_map(fn chunk ->
      ChatMessageContent
      |> Ash.Query.filter(chat_message_item_id in ^chunk and kind == :text)
      |> Ash.Query.select([:id, :chat_message_item_id, :sequence, :content_text])
      |> Ash.read!(actor: actor)
    end)
  end

  def load_snippets([], _search, _actor), do: %{}

  def load_snippets(messages, search, actor) when is_list(messages) do
    message_ids =
      messages
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if message_ids == [] do
      %{}
    else
      wanted_type_by_message =
        Map.new(messages, fn message ->
          {message.id, wanted_trace_item_type(message)}
        end)

      steps = read_steps_for_messages(message_ids, actor)
      step_by_id = Map.new(steps, &{&1.id, &1})

      items =
        steps
        |> Enum.map(& &1.id)
        |> read_items_for_steps(actor)
        |> Enum.filter(fn item ->
          case Map.get(step_by_id, item.chat_message_step_id) do
            nil ->
              false

            step ->
              trace_item_type_matches?(
                item,
                Map.get(wanted_type_by_message, step.chat_message_id)
              )
          end
        end)

      item_by_id = Map.new(items, &{&1.id, &1})

      contents =
        items
        |> Enum.map(& &1.id)
        |> read_matching_text_contents_for_items(search, actor)

      best_content_by_message =
        Enum.reduce(contents, %{}, fn content, acc ->
          with %ChatMessageItem{} = item <- Map.get(item_by_id, content.chat_message_item_id),
               %ChatMessageStep{} = step <- Map.get(step_by_id, item.chat_message_step_id) do
            message_id = step.chat_message_id
            candidate = {sort_key(step), sort_key(item), sort_key(content), content}

            case Map.get(acc, message_id) do
              nil ->
                Map.put(acc, message_id, candidate)

              current when candidate < current ->
                Map.put(acc, message_id, candidate)

              _current ->
                acc
            end
          else
            _other ->
              acc
          end
        end)

      Map.new(messages, fn message ->
        snippet =
          case Map.get(best_content_by_message, message.id) do
            {_step_key, _item_key, _content_key, content} ->
              snippet(content.content_text, search)

            _other ->
              nil
          end

        {message.id, snippet}
      end)
    end
  end

  defp read_matching_text_contents_for_items([], _search, _actor), do: []

  defp read_matching_text_contents_for_items(item_ids, {:contains, term}, actor)
       when is_list(item_ids) and is_binary(term) do
    term = contains_query_term(term)

    item_ids
    |> chunk_ids()
    |> Enum.flat_map(fn chunk ->
      ChatMessageContent
      |> Ash.Query.filter(
        chat_message_item_id in ^chunk and item_type in ^@searchable_trace_item_types and
          kind == :text and contains(content_text, ^term)
      )
      |> Ash.Query.select([:id, :chat_message_item_id, :sequence, :content_text])
      |> Ash.read!(actor: actor)
    end)
  end

  defp chunk_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.chunk_every(@trace_read_chunk_size)
  end

  defp wanted_trace_item_type(message) do
    case Map.get(message, :role) do
      :user -> [:input, :handoff_request, :handoff_context, :handoff_history, :handoff_message]
      :assistant -> [:answer, :handoff_summary]
      _ -> []
    end
  end

  defp trace_item_type_matches?(_item, []), do: false

  defp trace_item_type_matches?(item, wanted_types) when is_list(wanted_types) do
    Map.get(item, :type) in wanted_types
  end

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp sort_key(record) do
    {sort_seq(record), Map.get(record, :id, 0)}
  end

  def snippet(text, search, radius \\ @snippet_radius)

  def snippet(text, {:contains, term}, radius) when is_integer(radius) do
    build_exact_snippet(text, term, radius)
  end

  def snippet(_text, _search, _radius), do: nil

  defp build_exact_snippet(text, term, radius) when is_integer(radius) do
    text = to_string(text || "")
    term = normalize_term(term)

    if text == "" or term == "" do
      nil
    else
      regex = Regex.compile!(Regex.escape(term), "iu")

      case Regex.run(regex, text, return: :index) do
        nil ->
          nil

        [{match_start_bytes, match_len_bytes} | _] ->
          prefix_len =
            if match_start_bytes <= 0 do
              0
            else
              text
              |> binary_part(0, match_start_bytes)
              |> String.length()
            end

          match_end_bytes = match_start_bytes + match_len_bytes

          match_end_len =
            if match_end_bytes <= 0 do
              0
            else
              text
              |> binary_part(0, match_end_bytes)
              |> String.length()
            end

          total_len = String.length(text)
          start_idx = max(0, prefix_len - radius)
          end_idx = min(total_len, match_end_len + radius)

          snippet = String.slice(text, start_idx, end_idx - start_idx)
          prefix = if start_idx > 0, do: "...", else: ""
          suffix = if end_idx < total_len, do: "...", else: ""

          prefix <> snippet <> suffix
      end
    end
  end

  @doc "Returns text from an already authorized, possibly projected fork trace."
  def from_loaded(message) do
    message.steps
    |> Enum.sort_by(&sort_key/1)
    |> Enum.flat_map(fn step -> Enum.sort_by(step.items, &sort_key/1) end)
    |> Enum.filter(&trace_item_type_matches?(&1, wanted_trace_item_type(message)))
    |> Enum.map(fn item ->
      item.contents
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.sort_by(&sort_key/1)
      |> Enum.map_join("", &to_string(&1.content_text || ""))
    end)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp normalize_term(term), do: term |> to_string() |> String.trim()
  defp contains_query_term(term), do: CiString.new(term)
end
