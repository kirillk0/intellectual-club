defmodule IntellectualClub.Chat.Search do
  @moduledoc """
  Search helpers for chats and chat messages.

  All queries go through Ash and therefore respect authorization policies.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Listing
  alias IntellectualClub.Chat.MessageText
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Chat.SearchDeadline

  require Ash.Query

  @default_message_limit 50
  @default_chat_limit 50
  @default_message_candidate_limit 500
  @snippet_radius 240
  @snippet_preview_limit @snippet_radius * 2

  @type bot_filter :: nil | :none | integer()
  @type content_search :: {:contains, String.t()}

  @type message_hit :: %{
          id: integer(),
          role: String.t(),
          content: String.t(),
          snippet: String.t() | nil,
          created_at: String.t() | nil,
          finished_at: String.t() | nil,
          llm_configuration_id: integer() | nil,
          llm_configuration_label_snapshot: String.t() | nil
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
          |> Ash.Query.sort(created_at: :asc, id: :asc)
          |> Ash.Query.for_read(:search, %{q: term, chat_id: chat_id}, actor: actor)
          |> Ash.Query.limit(limit)
          |> Ash.read!(actor: actor, page: false)

        trace_text_by_message = MessageText.load_texts(messages, actor)

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

  @doc """
  Returns cursor pages without counting all matches. Common terms use a short
  correlated probe; rare terms fall back to the ordinary trigram plan. Both
  plans apply the same actor, hierarchy, section, bot and cursor filters.
  """
  def search_chat_sections(term, actor, bot_filter, opts) when is_list(opts) do
    SearchDeadline.run(fn ->
      term = normalize_term(term)
      sections = Keyword.fetch!(opts, :sections)
      pages = Keyword.get(opts, :pages, %{})
      cursors = Keyword.get(opts, :cursors, %{})
      per_page = Keyword.fetch!(opts, :per_page)

      section_pages =
        Map.new(sections, fn section ->
          number = Map.get(pages, section, 1)
          scope = cursor_scope(term, actor, bot_filter, section, per_page)
          position = decode_cursor(Map.get(cursors, section), scope, number)

          rows =
            if term == "",
              do: [],
              else: read_section(term, actor, bot_filter, section, position, per_page + 1)

          visible = Enum.take(rows, per_page)
          has_next = length(rows) > per_page
          cursor = if has_next, do: encode_cursor(List.last(visible), section, scope), else: nil

          {section,
           %{
             ids: Enum.map(visible, & &1.id),
             number: number,
             per_page: per_page,
             total: nil,
             has_next: has_next,
             next_cursor: cursor
           }}
        end)

      page_ids = sections |> Enum.flat_map(&section_pages[&1].ids) |> Enum.uniq()
      entries = SearchDeadline.query(fn -> page_entries(term, actor, bot_filter, page_ids) end)

      %{
        entries: entries,
        sections: section_pages,
        text_search?: MessageText.indexable_term?(term)
      }
    end)
  end

  @doc "Compatibility for clients still using section/page and an exact total."
  def search_chat_page(term, actor, bot_filter, pagination) do
    SearchDeadline.run(fn ->
      term = normalize_term(term)

      if term == "" do
        %{entries: [], total: 0}
      else
        page =
          SearchDeadline.query(fn ->
            section_query(term, actor, bot_filter, pagination.section, nil, :indexed)
            |> Ash.Query.page(
              limit: pagination.per_page,
              offset: (pagination.page - 1) * pagination.per_page,
              count: true
            )
            |> Ash.read!(actor: actor)
          end)

        entries =
          SearchDeadline.query(fn ->
            page_entries(term, actor, bot_filter, Enum.map(page.results, & &1.id))
          end)

        %{entries: entries, total: page.count}
      end
    end)
  end

  def search_chat_list(term, actor, opts \\ []) do
    SearchDeadline.run(fn -> SearchDeadline.query(fn -> search_chats(term, actor, opts) end) end)
  end

  defp read_section(term, actor, bot_filter, section, position, limit) do
    indexed = fn ->
      section_query(term, actor, bot_filter, section, position, :indexed)
      |> Ash.Query.limit(limit)
      |> Ash.read!(actor: actor, page: false)
    end

    if MessageText.indexable_term?(term) do
      # Select section membership before evaluating text. SQL conjunct order is
      # not an evaluation barrier, even for a section with only one or two chats.
      window = max(32, limit * 2)

      candidates =
        SearchDeadline.query(fn ->
          section_candidates(actor, bot_filter, section, position)
          |> Ash.Query.limit(window + 1)
          |> Ash.read!(actor: actor, page: false)
        end)

      ids = candidates |> Enum.take(window) |> Enum.map(& &1.id)

      if ids == [] do
        []
      else
        probe =
          SearchDeadline.probe(fn ->
            section_query(term, actor, bot_filter, section, position, :correlated)
            |> Ash.Query.filter(id in ^ids)
            |> Ash.Query.limit(limit)
            |> Ash.read!(actor: actor, page: false)
          end)

        case probe do
          {:ok, rows} when length(rows) >= limit or length(candidates) <= window -> rows
          _ -> SearchDeadline.query(indexed)
        end
      end
    else
      SearchDeadline.query(indexed)
    end
  end

  defp section_query(term, actor, bot_filter, section, position, strategy) do
    section_candidates(actor, bot_filter, section, position)
    |> Ash.Query.for_read(:search_list, %{q: term, strategy: strategy}, actor: actor)
  end

  defp section_candidates(actor, bot_filter, section, position) do
    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Listing.apply_hierarchy_filter(actor, section)
    |> Listing.apply_bot_filter(bot_filter)
    |> Listing.apply_section(section)
    |> apply_page_sort(section)
    |> Ash.Query.select([:id, :updated_at])
    |> load_cursor_field(section)
    |> after_position(section, position)
  end

  defp load_cursor_field(query, "drafts"), do: Ash.Query.load(query, :personal_draft_updated_at)
  defp load_cursor_field(query, _section), do: query
  defp after_position(query, _section, nil), do: query

  defp after_position(query, "drafts", {time, id}),
    do:
      Ash.Query.filter(
        query,
        personal_draft_updated_at < ^time or (personal_draft_updated_at == ^time and id < ^id)
      )

  defp after_position(query, _section, {time, id}),
    do: Ash.Query.filter(query, updated_at < ^time or (updated_at == ^time and id < ^id))

  defp cursor_scope(term, actor, bot_filter, section, per_page),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({term, actor.id, bot_filter, section, per_page})
      )

  defp encode_cursor(chat, section, scope) do
    time = if section == "drafts", do: chat.personal_draft_updated_at, else: chat.updated_at

    Phoenix.Token.sign(
      IntellectualClubWeb.Endpoint,
      "chat-search-page-v1",
      {scope, datetime_iso(time), chat.id}
    )
  end

  defp decode_cursor(nil, _scope, 1), do: nil

  defp decode_cursor(cursor, scope, _number)
       when is_binary(cursor) and byte_size(cursor) <= 2048 do
    with {:ok, {^scope, time, id}} when is_integer(id) and id > 0 and is_binary(time) <-
           Phoenix.Token.verify(IntellectualClubWeb.Endpoint, "chat-search-page-v1", cursor,
             max_age: 86_400
           ),
         {:ok, datetime, 0} <- DateTime.from_iso8601(time) do
      {datetime, id}
    else
      _ -> throw(:invalid_search_cursor)
    end
  end

  defp decode_cursor(_cursor, _scope, _number), do: throw(:invalid_search_cursor)

  defp apply_page_sort(query, "drafts"),
    do: Listing.apply_section_sort(query, "drafts")

  defp apply_page_sort(query, _section),
    do: Ash.Query.sort(query, updated_at: :desc, id: :desc)

  @spec search_chats(String.t() | nil, any(), keyword()) :: list(chat_search_entry())
  def search_chats(term, actor, opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :chat_ids) do
      ids when is_list(ids) ->
        page_entries(normalize_term(term), actor, Keyword.get(opts, :bot_filter), ids)

      _ ->
        search_flat_chats(term, actor, opts)
    end
  end

  defp search_flat_chats(term, actor, opts) do
    term = normalize_term(term)

    if term == "" do
      []
    else
      search =
        if MessageText.indexable_term?(term), do: message_content_search(term), else: :empty

      bot_filter = Keyword.get(opts, :bot_filter)

      scoped_ids = Keyword.get(opts, :chat_ids)

      chat_limit =
        if is_list(scoped_ids),
          do: nil,
          else: Keyword.get(opts, :limit, @default_chat_limit)

      message_limit =
        Keyword.get(
          opts,
          :message_candidate_limit,
          if(is_nil(chat_limit),
            do: nil,
            else: min(max(chat_limit * 10, chat_limit), @default_message_candidate_limit)
          )
        )

      meta_chats = search_meta_chats(term, bot_filter, chat_limit, actor, scoped_ids)
      meta_ids = MapSet.new(Enum.map(meta_chats, & &1.id))

      meta_active_branch_summaries =
        Threads.active_branch_summaries_by_chat(Enum.map(meta_chats, & &1.id), actor)

      meta_first_message_previews =
        Listing.active_root_message_previews(
          meta_chats,
          meta_active_branch_summaries,
          @snippet_preview_limit,
          actor
        )

      meta_entries =
        Enum.map(meta_chats, fn chat ->
          active_branch_summary = Map.get(meta_active_branch_summaries, chat.id, %{})

          {first_message_preview, _first_message_role} =
            Map.get(meta_first_message_previews, chat.id, {nil, nil})

          %{
            chat: chat,
            match_type: :meta,
            snippet: first_message_preview,
            message_id: nil,
            message_role: nil,
            message_count: Map.get(active_branch_summary, :message_count, 0)
          }
        end)

      remaining_limit = remaining_limit(chat_limit, length(meta_entries))

      if remaining_limit == 0 do
        meta_entries
      else
        message_candidates =
          case search do
            :empty ->
              []

            search ->
              search_message_candidates(
                search,
                bot_filter,
                meta_ids,
                message_limit,
                actor,
                scoped_ids
              )
          end

        chat_ids = message_candidates |> Enum.map(& &1.chat_id) |> Enum.uniq()

        active_ids_by_chat = Threads.active_branch_ids_by_chat(chat_ids, actor)

        {active_candidates_by_chat, inactive_candidates_by_chat} =
          Enum.reduce(message_candidates, {%{}, %{}}, fn message, {active_acc, inactive_acc} ->
            chat_id = message.chat_id
            active_ids = Map.get(active_ids_by_chat, chat_id, MapSet.new())

            if MapSet.member?(active_ids, message.id) do
              {put_message_candidate(active_acc, message), inactive_acc}
            else
              {active_acc, put_message_candidate(inactive_acc, message)}
            end
          end)

        active_match = select_message_candidates(active_candidates_by_chat)
        inactive_match = select_message_candidates(inactive_candidates_by_chat)

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

        remaining_limit = remaining_limit(remaining_limit, length(active_chats))

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

        snippet_by_message = MessageText.load_snippets(selected_messages, search, actor)

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

  defp page_entries(_term, _actor, _bot_filter, []), do: []

  defp page_entries(term, actor, bot_filter, ids) do
    meta_chats = search_meta_chats(term, bot_filter, nil, actor, ids)
    meta_ids = MapSet.new(meta_chats, & &1.id)
    other_ids = Enum.reject(ids, &MapSet.member?(meta_ids, &1))
    chats = load_chats_by_ids(other_ids, nil, actor)
    active_ids = Threads.active_branch_ids_by_chat(other_ids, actor)
    summaries = Threads.active_branch_summaries_by_chat(ids, actor)

    previews =
      Listing.active_root_message_previews(meta_chats, summaries, @snippet_preview_limit, actor)

    messages =
      Enum.flat_map(chats, fn chat ->
        ChatMessage
        |> Ash.Query.for_read(
          :list_search_hit,
          %{
            q: term,
            chat_id: chat.id,
            active_ids: MapSet.to_list(Map.get(active_ids, chat.id, MapSet.new()))
          },
          actor: actor
        )
        |> Ash.Query.select([:id, :chat_id, :role, :created_at])
        |> Ash.read!(actor: actor, page: false)
      end)

    snippets = MessageText.load_snippets(messages, {:contains, term}, actor)
    message_by_chat = Map.new(messages, &{&1.chat_id, &1})

    by_id =
      Map.new(meta_chats ++ chats, fn chat ->
        message = Map.get(message_by_chat, chat.id)

        entry =
          cond do
            MapSet.member?(meta_ids, chat.id) ->
              {preview, _role} = Map.get(previews, chat.id, {nil, nil})
              %{match_type: :meta, snippet: preview, message_id: nil, message_role: nil}

            message ->
              active? = MapSet.member?(Map.get(active_ids, chat.id, MapSet.new()), message.id)

              %{
                match_type: if(active?, do: :active_message, else: :inactive_message),
                snippet: snippets[message.id],
                message_id: message.id,
                message_role: role_to_string(message.role)
              }

            true ->
              nil
          end

        {chat.id,
         if(entry,
           do:
             Map.merge(entry, %{
               chat: chat,
               message_count: get_in(summaries, [chat.id, :message_count]) || 0
             })
         )}
      end)

    Enum.flat_map(ids, &List.wrap(by_id[&1]))
  end

  defp remaining_limit(nil, _used), do: nil
  defp remaining_limit(limit, used), do: max(limit - used, 0)

  defp normalize_term(term) do
    term
    |> to_string()
    |> String.trim()
  end

  defp role_to_string(:user), do: "user"
  defp role_to_string(:assistant), do: "assistant"
  defp role_to_string(_other), do: nil

  defp message_content_search(""), do: :empty

  defp message_content_search(term) when is_binary(term) do
    {:contains, term}
  end

  defp message_to_hit(message, search, content) do
    %{
      id: message.id,
      role: role_to_string(message.role),
      content: content,
      snippet: MessageText.snippet(content, search),
      created_at: datetime_iso(message.created_at),
      finished_at: datetime_iso(Map.get(message, :finished_at)),
      llm_configuration_id: message.llm_configuration_id,
      llm_configuration_label_snapshot: message.llm_configuration_label_snapshot
    }
  end

  defp datetime_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp datetime_iso(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp datetime_iso(_other), do: nil

  # Explicit IDs were already filtered by the paginated section query.
  defp apply_search_hierarchy(query, _actor, ids) when is_list(ids), do: query

  defp apply_search_hierarchy(query, actor, _ids),
    do: Listing.apply_hierarchy_filter(query, actor, nil)

  defp search_meta_chats(term, bot_filter, limit, actor, scoped_ids) do
    pattern = MessageText.like_pattern(term)

    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> apply_search_hierarchy(actor, scoped_ids)
    |> maybe_filter_chat_ids(scoped_ids, :id)
    |> Ash.Query.filter(
      fragment("? ILIKE ?", note, ^pattern) or exists(bot, fragment("? ILIKE ?", name, ^pattern))
    )
    |> apply_bot_filter(bot_filter)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load([
      :read_state,
      :bot,
      :last_message,
      :blocks_count,
      :tools_count,
      :can_edit,
      :shared_incoming,
      :shared_outgoing,
      llm_configuration: [:model_name, :note, :provider]
    ])
    |> Ash.read!(actor: actor)
  end

  defp search_message_candidates(search, bot_filter, meta_ids, limit, actor, scoped_ids)
       when is_tuple(search) do
    read_message_candidates(
      search,
      bot_filter,
      meta_ids,
      if(is_nil(limit), do: nil, else: limit * 2),
      actor,
      scoped_ids
    )
  end

  defp read_message_candidates(search, bot_filter, meta_ids, limit, actor, scoped_ids)
       when is_tuple(search) do
    meta_list = MapSet.to_list(meta_ids)
    handoff_relation_kind = Handoff.relation_kind()
    scoped? = is_list(scoped_ids)

    ChatMessage
    |> MessageText.filter(search, owner_id: actor.id)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(
      ^scoped? or
        exists(
          chat,
          subagent == false and
            not exists(
              child_chats,
              owner_id == ^actor.id and parent_relation_kind == ^handoff_relation_kind
            )
        )
    )
    |> Ash.Query.filter(role in [:user, :assistant])
    |> maybe_filter_chat_ids(scoped_ids, :chat_id)
    |> maybe_exclude_chat_ids(meta_list)
    |> apply_bot_filter_via_chat(bot_filter)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: actor, page: false)
  end

  defp put_message_candidate(acc, message) do
    Map.update(acc, message.chat_id, initial_message_candidate(message), fn candidate ->
      update_message_candidate(candidate, message)
    end)
  end

  defp initial_message_candidate(message), do: update_message_candidate(%{}, message)

  defp update_message_candidate(candidate, message) do
    key = if preferred_message_candidate?(message), do: :preferred, else: :fallback

    if Map.has_key?(candidate, key) do
      candidate
    else
      Map.put(candidate, key, message)
    end
  end

  defp preferred_message_candidate?(message), do: message.role == :user

  defp select_message_candidates(candidates_by_chat) when is_map(candidates_by_chat) do
    Map.new(candidates_by_chat, fn {chat_id, candidate} ->
      {chat_id, Map.get(candidate, :preferred) || Map.get(candidate, :fallback)}
    end)
  end

  defp maybe_filter_chat_ids(query, nil, _field), do: query
  defp maybe_filter_chat_ids(query, ids, :id), do: Ash.Query.filter(query, id in ^ids)
  defp maybe_filter_chat_ids(query, ids, :chat_id), do: Ash.Query.filter(query, chat_id in ^ids)

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
       when is_list(chat_ids) do
    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(id in ^chat_ids)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load([
      :read_state,
      :bot,
      :last_message,
      :blocks_count,
      :tools_count,
      :can_edit,
      :shared_incoming,
      :shared_outgoing,
      llm_configuration: [:model_name, :note, :provider]
    ])
    |> Ash.read!(actor: actor)
  end
end
