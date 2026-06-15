defmodule IntellectualClub.Chat.Search do
  @moduledoc """
  Search helpers for chats and chat messages.

  All queries go through Ash and therefore respect authorization policies.
  """

  alias Ash.CiString
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.MessageContentFts
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Db

  require Ash.Query

  @default_message_limit 50
  @default_chat_limit 50
  @default_message_candidate_limit 500
  @trace_read_chunk_size 200
  @searchable_trace_item_types [:input, :answer]

  @type bot_filter :: nil | :none | integer()
  @type content_search :: {:contains, String.t()} | {:fts, MessageContentFts.t()}

  @type message_hit :: %{
          id: integer(),
          role: String.t(),
          content: String.t(),
          snippet: String.t() | nil,
          created_at: String.t() | nil,
          finished_at: String.t() | nil,
          llm_configuration_id: integer() | nil
        }

  @type chat_match_type :: :meta | :active_message | :inactive_message

  @type chat_search_entry :: %{
          chat: Chat.t(),
          match_type: chat_match_type(),
          snippet: String.t() | nil,
          message_id: integer() | nil,
          message_role: String.t() | nil,
          message_count: non_neg_integer()
        }

  @spec search_messages_in_chat(integer(), String.t() | nil, any(), keyword()) :: %{
          active: list(message_hit()),
          inactive: list(message_hit())
        }
  def search_messages_in_chat(chat_id, term, actor, opts \\ [])
      when is_integer(chat_id) and is_list(opts) do
    term = normalize_term(term)

    case message_content_search(term) do
      :empty ->
        %{active: [], inactive: []}

      search ->
        limit = Keyword.get(opts, :limit, @default_message_limit)

        chat = Ash.get!(Chat, chat_id, actor: actor)
        active_ids = Threads.active_branch_ids(chat, actor)

        messages =
          ChatMessage
          |> Ash.Query.filter(chat_id == ^chat_id)
          |> filter_trace_search(search)
          |> Ash.Query.sort(created_at: :asc, id: :asc)
          |> Ash.Query.limit(limit)
          |> Ash.read!(actor: actor)

        trace_text_by_message = load_message_trace_texts(messages, actor)

        {active_hits, inactive_hits} =
          Enum.reduce(messages, {[], []}, fn message, {active_acc, inactive_acc} ->
            hit =
              message_to_hit(message, search, Map.get(trace_text_by_message, message.id, ""))

            if MapSet.member?(active_ids, message.id) do
              {[hit | active_acc], inactive_acc}
            else
              {active_acc, [hit | inactive_acc]}
            end
          end)

        %{
          active: Enum.reverse(active_hits),
          inactive: Enum.reverse(inactive_hits)
        }
    end
  end

  @spec search_chats(String.t() | nil, any(), keyword()) :: list(chat_search_entry())
  def search_chats(term, actor, opts \\ []) when is_list(opts) do
    term = normalize_term(term)

    if term == "" do
      []
    else
      search = message_content_search(term)
      bot_filter = Keyword.get(opts, :bot_filter)
      chat_limit = Keyword.get(opts, :limit, @default_chat_limit)

      message_limit =
        Keyword.get(
          opts,
          :message_candidate_limit,
          min(max(chat_limit * 10, chat_limit), @default_message_candidate_limit)
        )

      meta_chats = search_meta_chats(term, bot_filter, chat_limit, actor)
      meta_ids = MapSet.new(Enum.map(meta_chats, & &1.id))

      meta_message_count_by_chat =
        Threads.active_branch_counts_by_chat(Enum.map(meta_chats, & &1.id), actor)

      meta_entries =
        Enum.map(meta_chats, fn chat ->
          %{
            chat: chat,
            match_type: :meta,
            snippet: nil,
            message_id: nil,
            message_role: nil,
            message_count: Map.get(meta_message_count_by_chat, chat.id, 0)
          }
        end)

      remaining_limit = max(chat_limit - length(meta_entries), 0)

      if remaining_limit == 0 do
        meta_entries
      else
        message_candidates =
          case search do
            :empty ->
              []

            search ->
              search_message_candidates(search, bot_filter, meta_ids, message_limit, actor)
          end

        chat_ids = message_candidates |> Enum.map(& &1.chat_id) |> Enum.uniq()

        active_ids_by_chat = Threads.active_branch_ids_by_chat(chat_ids, actor)

        {active_match, inactive_match} =
          Enum.reduce(message_candidates, {%{}, %{}}, fn message, {active_acc, inactive_acc} ->
            chat_id = message.chat_id
            active_ids = Map.get(active_ids_by_chat, chat_id, MapSet.new())

            cond do
              Map.has_key?(active_acc, chat_id) ->
                {active_acc, inactive_acc}

              MapSet.member?(active_ids, message.id) ->
                {Map.put(active_acc, chat_id, message), inactive_acc}

              Map.has_key?(inactive_acc, chat_id) ->
                {active_acc, inactive_acc}

              true ->
                {active_acc, Map.put(inactive_acc, chat_id, message)}
            end
          end)

        inactive_match =
          Enum.reduce(Map.keys(active_match), inactive_match, fn chat_id, acc ->
            Map.delete(acc, chat_id)
          end)

        active_chat_ids = Map.keys(active_match)
        active_chats = load_chats_by_ids(active_chat_ids, remaining_limit, actor)

        active_chat_id_set =
          active_chats
          |> Enum.map(& &1.id)
          |> MapSet.new()

        remaining_limit = max(remaining_limit - length(active_chats), 0)

        inactive_chat_ids = Map.keys(inactive_match)
        inactive_chats = load_chats_by_ids(inactive_chat_ids, remaining_limit, actor)

        message_count_by_chat =
          Threads.active_branch_counts_by_chat(
            Enum.map(active_chats ++ inactive_chats, & &1.id),
            actor
          )

        selected_messages =
          active_match
          |> Map.take(MapSet.to_list(active_chat_id_set))
          |> Map.values()
          |> Kernel.++(
            inactive_match
            |> Map.take(Enum.map(inactive_chats, & &1.id))
            |> Map.values()
          )

        snippet_by_message = load_message_snippets(selected_messages, search, actor)

        match_by_chat =
          Map.new(selected_messages, fn message ->
            {message.chat_id,
             %{
               snippet: Map.get(snippet_by_message, message.id),
               message_id: message.id,
               message_role: role_to_string(message.role)
             }}
          end)

        active_entries =
          Enum.map(active_chats, fn chat ->
            match = Map.get(match_by_chat, chat.id, %{})

            %{
              chat: chat,
              match_type: :active_message,
              snippet: Map.get(match, :snippet),
              message_id: Map.get(match, :message_id),
              message_role: Map.get(match, :message_role),
              message_count: Map.get(message_count_by_chat, chat.id, 0)
            }
          end)

        inactive_entries =
          Enum.map(inactive_chats, fn chat ->
            match = Map.get(match_by_chat, chat.id, %{})

            %{
              chat: chat,
              match_type: :inactive_message,
              snippet: Map.get(match, :snippet),
              message_id: Map.get(match, :message_id),
              message_role: Map.get(match, :message_role),
              message_count: Map.get(message_count_by_chat, chat.id, 0)
            }
          end)

        meta_entries ++ active_entries ++ inactive_entries
      end
    end
  end

  defp normalize_term(term) do
    term
    |> to_string()
    |> String.trim()
  end

  defp role_to_string(:user), do: "user"
  defp role_to_string(:assistant), do: "assistant"
  defp role_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp role_to_string(value) when is_binary(value), do: value
  defp role_to_string(_other), do: nil

  defp message_content_search(""), do: :empty

  defp message_content_search(term) when is_binary(term) do
    if Db.sqlite?() do
      case MessageContentFts.build(term) do
        %MessageContentFts{} = query -> {:fts, query}
        _other -> :empty
      end
    else
      {:contains, term}
    end
  end

  defp filter_trace_search(query, {:fts, %MessageContentFts{} = fts}) do
    Ash.Query.for_read(query, :fts_search, %{fts_match: MessageContentFts.match_query(fts)})
  end

  defp filter_trace_search(query, {:contains, term}) when is_binary(term) do
    term = contains_query_term(term)

    Ash.Query.filter(
      query,
      exists(
        steps,
        exists(
          items,
          (type == :input or type == :answer) and
            exists(contents, kind == :text and contains(content_text, ^term))
        )
      )
    )
  end

  defp message_to_hit(message, search, content) do
    %{
      id: message.id,
      role: role_to_string(message.role),
      content: content,
      snippet: build_snippet(content, search),
      created_at: datetime_iso(message.created_at),
      finished_at: datetime_iso(Map.get(message, :finished_at)),
      llm_configuration_id: message.llm_configuration_id
    }
  end

  defp datetime_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp datetime_iso(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp datetime_iso(_other), do: nil

  defp load_message_trace_texts([], _actor), do: %{}

  defp load_message_trace_texts(messages, actor) when is_list(messages) do
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

  defp read_steps_for_messages([], _actor), do: []

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

  defp load_message_snippets([], _search, _actor), do: %{}

  defp load_message_snippets(messages, search, actor) when is_list(messages) do
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
              build_snippet(content.content_text, search)

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
        chat_message_item_id in ^chunk and kind == :text and contains(content_text, ^term)
      )
      |> Ash.Query.select([:id, :chat_message_item_id, :sequence, :content_text])
      |> Ash.read!(actor: actor)
    end)
  end

  defp read_matching_text_contents_for_items(item_ids, {:fts, %MessageContentFts{} = fts}, actor)
       when is_list(item_ids) do
    item_ids
    |> chunk_ids()
    |> Enum.flat_map(fn chunk ->
      ChatMessageContent
      |> Ash.Query.filter(chat_message_item_id in ^chunk and kind == :text)
      |> Ash.Query.for_read(:fts_search, %{fts_match: MessageContentFts.match_query(fts)})
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
      :user -> :input
      "user" -> :input
      :assistant -> :answer
      "assistant" -> :answer
      _ -> nil
    end
  end

  defp trace_item_type_matches?(_item, nil), do: false

  defp trace_item_type_matches?(item, wanted_type) do
    Map.get(item, :type) == wanted_type
  end

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp sort_key(record) do
    {sort_seq(record), Map.get(record, :id, 0)}
  end

  defp build_snippet(text, search, radius \\ 60)

  defp build_snippet(text, {:fts, %MessageContentFts{} = fts}, radius)
       when is_integer(radius) do
    MessageContentFts.build_snippet(text, fts, radius)
  end

  defp build_snippet(text, {:contains, term}, radius) when is_integer(radius) do
    build_exact_snippet(text, term, radius)
  end

  defp build_snippet(_text, _search, _radius), do: nil

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

  defp search_meta_chats(term, bot_filter, limit, actor) do
    term = contains_query_term(term)

    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(contains(note, ^term) or exists(bot, contains(name, ^term)))
    |> apply_bot_filter(bot_filter)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load([
      :bot,
      :last_message,
      :can_edit,
      :shared_incoming,
      :shared_outgoing,
      llm_configuration: [:model_name, :note, :provider]
    ])
    |> Ash.read!(actor: actor)
  end

  defp search_message_candidates(search, bot_filter, meta_ids, limit, actor)
       when is_tuple(search) do
    meta_list = MapSet.to_list(meta_ids)

    ChatMessage
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> filter_trace_search(search)
    |> maybe_exclude_chat_ids(meta_list)
    |> apply_bot_filter_via_chat(bot_filter)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: actor)
  end

  defp maybe_exclude_chat_ids(query, []), do: query

  defp maybe_exclude_chat_ids(query, chat_ids) when is_list(chat_ids) do
    Ash.Query.filter(query, chat_id not in ^chat_ids)
  end

  defp apply_bot_filter(query, nil), do: query
  defp apply_bot_filter(query, :none), do: Ash.Query.filter(query, is_nil(bot_id))

  defp apply_bot_filter(query, bot_id) when is_integer(bot_id) do
    Ash.Query.filter(query, bot_id == ^bot_id)
  end

  defp apply_bot_filter(query, _other), do: query

  defp apply_bot_filter_via_chat(query, nil), do: query

  defp apply_bot_filter_via_chat(query, :none),
    do: Ash.Query.filter(query, exists(chat, is_nil(bot_id)))

  defp apply_bot_filter_via_chat(query, bot_id) when is_integer(bot_id) do
    Ash.Query.filter(query, exists(chat, bot_id == ^bot_id))
  end

  defp apply_bot_filter_via_chat(query, _other), do: query

  defp load_chats_by_ids([], _limit, _actor), do: []
  defp load_chats_by_ids(_chat_ids, limit, _actor) when is_integer(limit) and limit <= 0, do: []

  defp load_chats_by_ids(chat_ids, limit, actor)
       when is_list(chat_ids) and is_integer(limit) do
    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(id in ^chat_ids)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load([
      :bot,
      :last_message,
      :can_edit,
      :shared_incoming,
      :shared_outgoing,
      llm_configuration: [:model_name, :note, :provider]
    ])
    |> Ash.read!(actor: actor)
  end

  defp contains_query_term(term) when is_binary(term) do
    if Db.postgres?() do
      CiString.new(term)
    else
      term
    end
  end
end
