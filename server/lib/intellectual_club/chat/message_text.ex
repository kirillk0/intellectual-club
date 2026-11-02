defmodule IntellectualClub.Chat.MessageText do
  @moduledoc """
  Actor-authorized user-facing message text and substring matching shared by
  Ash actions and the UI search. Tool calls, reasoning and opaque contents are
  deliberately excluded.

  A search is a non-empty list of literal terms. A stored text content matches
  when it contains every term as a case-insensitive substring; terms are not
  matched across different contents of the same message.
  """

  alias IntellectualClub.Chat.{ChatMessageContent, ChatMessageItem, ChatMessageStep}
  require Ash.Query
  require Ash.Expr

  @snippet_radius 240
  @trace_read_chunk_size 200
  @max_terms 16
  @searchable_trace_item_types [
    :input,
    :handoff_request,
    :handoff_history,
    :handoff_message,
    :answer,
    :handoff_summary
  ]

  @type search :: {:terms, nonempty_list(String.t())}

  @doc "Item types whose text contents are searchable, as strings for raw SQL fragments."
  def searchable_trace_item_type_strings, do: Enum.map(@searchable_trace_item_types, &to_string/1)

  @doc """
  Splits a raw query into search terms.

  With `exact?` the whole trimmed query is one literal term, spaces included.
  Otherwise whitespace separates terms and every term must match. Returns `[]`
  for a blank query.
  """
  @spec terms(String.t() | nil, boolean()) :: [String.t()]
  def terms(query, exact?) do
    query = query |> to_string() |> String.trim()

    cond do
      query == "" -> []
      exact? -> [query]
      true -> query |> String.split() |> Enum.uniq() |> Enum.take(@max_terms)
    end
  end

  @doc "Wraps terms as a search, or returns `:empty`."
  @spec search(String.t() | nil, boolean()) :: search() | :empty
  def search(query, exact?) do
    case terms(query, exact?) do
      [] -> :empty
      terms -> {:terms, terms}
    end
  end

  @doc """
  Filters `ChatMessage` queries to messages with a text content containing
  every term (case-insensitive literal substrings).

  The partial trigram index is over raw `content_text`. Its kind and item-type
  predicates must be present so PostgreSQL can use it for ILIKE rechecks.
  """
  def filter(query, search, opts \\ [])

  def filter(query, {:terms, [_ | _] = terms}, opts) do
    owner_id = Keyword.get(opts, :owner_id)
    content_owner = if owner_id, do: Ash.Expr.expr(owner_id == ^owner_id), else: true
    text_predicate = contents_predicate(terms)

    query =
      Ash.Query.filter(
        query,
        exists(
          steps,
          exists(
            items,
            type in ^@searchable_trace_item_types and
              exists(
                contents,
                kind == :text and item_type in ^@searchable_trace_item_types and
                  ^content_owner and ^text_predicate
              )
          )
        )
      )

    if owner_id, do: Ash.Query.filter(query, owner_id == ^owner_id), else: query
  end

  @doc "An Ash expression over `ChatMessageContent` matching every term."
  def contents_predicate([_ | _] = terms) do
    Enum.reduce(terms, true, fn term, acc ->
      pattern = like_pattern(term)
      Ash.Expr.expr(^acc and fragment("? ILIKE ?", content_text, ^pattern))
    end)
  end

  @doc """
  Whether a search can be narrowed by the trigram index: some term has a run
  of at least three letters or digits. Shorter terms alone would have to scan
  every stored text; combined with an indexable term they only filter.
  """
  def indexable?({:terms, terms}), do: Enum.any?(terms, &indexable_term?/1)
  def indexable?(_search), do: false

  @doc "Whether `term` has a run of at least three letters or digits."
  def indexable_term?(term) when is_binary(term), do: Regex.match?(~r/[\p{L}\p{N}]{3}/u, term)
  def indexable_term?(_term), do: false

  def like_pattern(term) do
    escaped = String.replace(term, ["\\", "%", "_"], fn char -> "\\" <> char end)
    "%" <> escaped <> "%"
  end

  @doc "ILIKE patterns for every term, in search order."
  def like_patterns({:terms, terms}), do: Enum.map(terms, &like_pattern/1)

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

  defp read_matching_text_contents_for_items(item_ids, {:terms, [_ | _] = terms}, actor)
       when is_list(item_ids) do
    text_predicate = contents_predicate(terms)

    item_ids
    |> chunk_ids()
    |> Enum.flat_map(fn chunk ->
      ChatMessageContent
      |> Ash.Query.filter(
        chat_message_item_id in ^chunk and item_type in ^@searchable_trace_item_types and
          kind == :text and ^text_predicate
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
      :user -> [:input, :handoff_request, :handoff_history, :handoff_message]
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

  @doc """
  A window of `text` around the earliest occurrence of any term, or `nil` when
  no term occurs. Callers highlight terms themselves.
  """
  def snippet(text, search, radius \\ @snippet_radius)

  def snippet(text, {:terms, [_ | _] = terms}, radius) when is_integer(radius) do
    text = to_string(text || "")

    if text == "" do
      nil
    else
      terms
      |> Enum.map(&normalize_term/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn term ->
        case Regex.run(Regex.compile!(Regex.escape(term), "iu"), text, return: :index) do
          [{start, length} | _] -> [{start, length}]
          nil -> []
        end
      end)
      |> Enum.min(fn -> nil end)
      |> case do
        nil ->
          nil

        {match_start_bytes, match_len_bytes} ->
          window(text, match_start_bytes, match_len_bytes, radius)
      end
    end
  end

  def snippet(_text, _search, _radius), do: nil

  defp window(text, match_start_bytes, match_len_bytes, radius) do
    prefix_len = if match_start_bytes <= 0, do: 0, else: grapheme_length(text, match_start_bytes)
    match_end_bytes = match_start_bytes + match_len_bytes
    match_end_len = if match_end_bytes <= 0, do: 0, else: grapheme_length(text, match_end_bytes)
    total_len = String.length(text)
    start_idx = max(0, prefix_len - radius)
    end_idx = min(total_len, match_end_len + radius)
    snippet = String.slice(text, start_idx, end_idx - start_idx)
    prefix = if start_idx > 0, do: "...", else: ""
    suffix = if end_idx < total_len, do: "...", else: ""
    prefix <> snippet <> suffix
  end

  defp grapheme_length(text, bytes), do: text |> binary_part(0, bytes) |> String.length()

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
end
