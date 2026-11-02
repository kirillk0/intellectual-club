defmodule IntellectualClub.Chat.Search do
  @moduledoc """
  Text search over user-facing message text for the chat list and one chat.

  Chat-list search returns message hits newest first, plus chats whose note
  matches. All reads go through Ash and respect authorization policies; list
  search is additionally owner-only.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Listing
  alias IntellectualClub.Chat.MessageText
  alias IntellectualClub.Chat.SearchDeadline
  alias IntellectualClub.Chat.Threads

  require Ash.Query
  require Ash.Expr

  @default_message_limit 50
  @default_hit_limit 30
  @max_hit_limit 100
  @notes_limit 20
  @default_probe_window 300
  @default_probe_chunk 50
  @cursor_salt "chat-search-hits-v2"

  @type bot_filter :: nil | :none | integer()

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

  @type hit :: %{
          message_id: integer(),
          chat_id: integer(),
          role: String.t() | nil,
          created_at: String.t() | nil,
          active?: boolean(),
          snippet: String.t() | nil
        }

  @type list_result :: %{
          chats: list(Chat.t()),
          notes: list(integer()),
          hits: list(hit()),
          message_counts: %{integer() => non_neg_integer()},
          next_cursor: String.t() | nil,
          text_search?: boolean(),
          terms: list(String.t())
        }

  @doc """
  Searches one chat's stored messages, split into active and inactive branch hits.

  Options: `exact?` (whole query as one substring, default `false`), `limit`.
  """
  @spec search_messages_in_chat(integer(), String.t() | nil, any(), keyword()) :: %{
          active: list(message_hit()),
          inactive: list(message_hit())
        }
  def search_messages_in_chat(chat_id, query, actor, opts \\ [])
      when is_integer(chat_id) and is_list(opts) do
    exact? = Keyword.get(opts, :exact?, false)

    case MessageText.search(query, exact?) do
      :empty ->
        %{active: [], inactive: []}

      search ->
        limit = Keyword.get(opts, :limit, @default_message_limit)

        chat = Ash.get!(Chat, chat_id, actor: actor)
        active_ids = Threads.active_branch_ids(chat, actor)

        messages =
          ChatMessage
          |> Ash.Query.sort(created_at: :asc, id: :asc)
          |> Ash.Query.for_read(:search, %{q: query, exact: exact?, chat_id: chat_id},
            actor: actor
          )
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
  Searches the actor's chat list.

  Returns chats whose note matches (first page only) and message hits newest
  first, with a cursor for the next page. Message text is searched only when
  some term can use the trigram index (`text_search?`). The page is read with
  a short correlated probe over the newest messages and the trigram plan for
  the rest, so neither common nor rare terms scan everything.

  Options: `exact?`, `bot_filter`, `after` (cursor), `limit`.
  """
  @spec search_chat_list(String.t() | nil, any(), keyword()) ::
          {:ok, list_result()} | {:error, :timeout | :invalid_cursor}
  def search_chat_list(query, actor, opts \\ []) when is_list(opts) do
    SearchDeadline.run(fn ->
      exact? = Keyword.get(opts, :exact?, false)
      bot_filter = Keyword.get(opts, :bot_filter)
      limit = opts |> Keyword.get(:limit, @default_hit_limit) |> min(@max_hit_limit) |> max(1)
      search = MessageText.search(query, exact?)
      scope = cursor_scope(search, actor, bot_filter)
      position = decode_cursor(Keyword.get(opts, :after), scope)

      case search do
        :empty ->
          empty_result()

        {:terms, terms} ->
          notes =
            if is_nil(position),
              do: SearchDeadline.query(fn -> note_chats(search, actor, bot_filter) end),
              else: []

          text_search? = MessageText.indexable?(search)

          {messages, has_next?} =
            if text_search?,
              do:
                read_hits(
                  %{q: query, exact?: exact?, search: search},
                  actor,
                  bot_filter,
                  position,
                  limit
                ),
              else: {[], false}

          note_ids = Enum.map(notes, & &1.id)
          hit_chat_ids = messages |> Enum.map(& &1.chat_id) |> Enum.uniq()

          # Chats follow their first hit so grouped rendering stays stable.
          hit_chats =
            SearchDeadline.query(fn -> load_chats_by_ids(hit_chat_ids -- note_ids, actor) end)
            |> Enum.sort_by(&Enum.find_index(hit_chat_ids, fn id -> id == &1.id end))

          active_ids_by_chat =
            SearchDeadline.query(fn ->
              Threads.active_branch_ids_by_chat(Enum.uniq(note_ids ++ hit_chat_ids), actor)
            end)

          snippets =
            SearchDeadline.query(fn -> MessageText.load_snippets(messages, search, actor) end)

          hits =
            Enum.map(messages, fn message ->
              active_ids = Map.get(active_ids_by_chat, message.chat_id, MapSet.new())

              %{
                message_id: message.id,
                chat_id: message.chat_id,
                role: role_to_string(message.role),
                created_at: datetime_iso(message.created_at),
                active?: MapSet.member?(active_ids, message.id),
                snippet: Map.get(snippets, message.id)
              }
            end)

          %{
            chats: notes ++ hit_chats,
            notes: note_ids,
            hits: hits,
            message_counts:
              Map.new(active_ids_by_chat, fn {id, ids} -> {id, MapSet.size(ids)} end),
            next_cursor: if(has_next?, do: encode_cursor(List.last(messages), scope), else: nil),
            text_search?: text_search?,
            terms: terms
          }
      end
    end)
  end

  defp empty_result do
    %{
      chats: [],
      notes: [],
      hits: [],
      message_counts: %{},
      next_cursor: nil,
      text_search?: false,
      terms: []
    }
  end

  # Returns `{messages, has_next?}` with at most `limit` messages.
  #
  # The newest `window` candidate messages are checked in chunks, newest first,
  # until the page fills. After each chunk the hit rate so far projects whether
  # the window can fill the page at all; when it cannot, the trigram plan takes
  # over immediately and covers only what the probe did not check.
  defp read_hits(context, actor, bot_filter, position, limit) do
    window = probe_window()

    candidates =
      SearchDeadline.query(fn ->
        window_candidates(context, actor, bot_filter, position, window)
      end)

    probe =
      if candidates == [],
        do: {:ok, {[], nil}},
        else:
          SearchDeadline.probe(fn ->
            probe_chunks(context, actor, bot_filter, candidates, limit + 1)
          end)

    # A short window means every message after the cursor was a candidate.
    exhausted? = fn checked ->
      length(candidates) < window and
        checked == candidates |> List.last() |> then(&{&1.created_at, &1.id})
    end

    case probe do
      {:ok, {rows, _checked}} when length(rows) > limit ->
        page(rows, limit)

      {:ok, {rows, checked}} ->
        if candidates == [] or exhausted?.(checked) do
          {rows, false}
        else
          rest =
            SearchDeadline.query(fn ->
              hits_query(context, actor, bot_filter, :indexed)
              |> after_position(checked)
              |> Ash.Query.limit(limit + 1 - length(rows))
              |> Ash.read!(actor: actor, page: false)
            end)

          page(rows ++ rest, limit)
        end

      {:error, :statement_timeout} ->
        rows =
          SearchDeadline.query(fn ->
            hits_query(context, actor, bot_filter, :indexed)
            |> after_position(position)
            |> Ash.Query.limit(limit + 1)
            |> Ash.read!(actor: actor, page: false)
          end)

        page(rows, limit)
    end
  end

  defp page(rows, limit), do: {Enum.take(rows, limit), length(rows) > limit}

  # Returns `{rows, last_checked}` where `last_checked` is the oldest candidate
  # whose contents were inspected, as a `{created_at, id}` position.
  defp probe_chunks(context, actor, bot_filter, candidates, wanted) do
    total = length(candidates)

    candidates
    |> Enum.chunk_every(probe_chunk_size())
    |> Enum.reduce_while({[], nil, 0}, fn chunk, {rows, _checked, checked_count} ->
      ids = Enum.map(chunk, & &1.id)

      found =
        hits_query(context, actor, bot_filter, :correlated)
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.limit(wanted - length(rows))
        |> Ash.read!(actor: actor, page: false)

      rows = rows ++ found
      checked_count = checked_count + length(chunk)
      last = List.last(chunk)
      state = {rows, {last.created_at, last.id}, checked_count}
      projected = length(rows) * total / checked_count

      if length(rows) >= wanted or projected < wanted,
        do: {:halt, state},
        else: {:cont, state}
    end)
    |> then(fn {rows, checked, _count} -> {rows, checked} end)
  end

  defp hits_query(%{q: query, exact?: exact?}, actor, bot_filter, strategy) do
    ChatMessage
    |> chat_filters(bot_filter)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.select([:id, :chat_id, :role, :created_at])
    |> Ash.Query.for_read(:list_search, %{q: query, exact: exact?, strategy: strategy},
      actor: actor
    )
  end

  # The newest messages a probe may inspect, oldest last.
  defp window_candidates(_context, actor, bot_filter, position, window) do
    ChatMessage
    |> Ash.Query.filter(owner_id == ^actor.id and role in [:user, :assistant])
    |> chat_filters(bot_filter)
    |> after_position(position)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.select([:id, :created_at])
    |> Ash.Query.limit(window)
    |> Ash.read!(actor: actor, page: false)
  end

  defp chat_filters(query, bot_filter) do
    query
    |> Ash.Query.filter(exists(chat, subagent == false))
    |> apply_bot_filter_via_chat(bot_filter)
  end

  defp probe_chunk_size do
    Application.get_env(:intellectual_club, :chat_search_probe_chunk, @default_probe_chunk)
  end

  defp probe_window do
    Application.get_env(:intellectual_club, :chat_search_probe_window, @default_probe_window)
  end

  defp after_position(query, nil), do: query

  defp after_position(query, {time, id}),
    do: Ash.Query.filter(query, created_at < ^time or (created_at == ^time and id < ^id))

  defp note_chats(search, actor, bot_filter) do
    predicate = note_predicate(search)

    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Listing.apply_hierarchy_filter(actor, nil)
    |> Listing.apply_bot_filter(bot_filter)
    |> Ash.Query.filter(^predicate)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(@notes_limit)
    |> Ash.Query.load(summary_loads())
    |> Ash.read!(actor: actor)
  end

  defp note_predicate({:terms, terms}) do
    Enum.reduce(terms, true, fn term, acc ->
      pattern = MessageText.like_pattern(term)
      Ash.Expr.expr(^acc and fragment("? ILIKE ?", note, ^pattern))
    end)
  end

  defp cursor_scope(search, actor, bot_filter),
    do: :crypto.hash(:sha256, :erlang.term_to_binary({search, actor.id, bot_filter}))

  defp encode_cursor(message, scope) do
    Phoenix.Token.sign(
      IntellectualClubWeb.Endpoint,
      @cursor_salt,
      {scope, datetime_iso(message.created_at), message.id}
    )
  end

  defp decode_cursor(nil, _scope), do: nil
  defp decode_cursor("", _scope), do: nil

  defp decode_cursor(cursor, scope) when is_binary(cursor) and byte_size(cursor) <= 2048 do
    with {:ok, {^scope, time, id}} when is_integer(id) and id > 0 and is_binary(time) <-
           Phoenix.Token.verify(IntellectualClubWeb.Endpoint, @cursor_salt, cursor,
             max_age: 86_400
           ),
         {:ok, datetime, 0} <- DateTime.from_iso8601(time) do
      {datetime, id}
    else
      _ -> throw(:invalid_search_cursor)
    end
  end

  defp decode_cursor(_cursor, _scope), do: throw(:invalid_search_cursor)

  defp role_to_string(:user), do: "user"
  defp role_to_string(:assistant), do: "assistant"
  defp role_to_string(_other), do: nil

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

  defp apply_bot_filter_via_chat(query, nil), do: query

  defp apply_bot_filter_via_chat(query, :none),
    do: Ash.Query.filter(query, exists(chat, is_nil(bot_id)))

  defp apply_bot_filter_via_chat(query, bot_id) when is_integer(bot_id) do
    Ash.Query.filter(query, exists(chat, bot_id == ^bot_id))
  end

  defp apply_bot_filter_via_chat(query, _other), do: query

  defp summary_loads do
    [
      :read_state,
      :bot,
      :last_message,
      :blocks_count,
      :tools_count,
      :can_edit,
      :shared_incoming,
      :shared_outgoing,
      llm_configuration: [:model_name, :note, :provider]
    ]
  end

  defp load_chats_by_ids([], _actor), do: []

  defp load_chats_by_ids(chat_ids, actor) when is_list(chat_ids) do
    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(id in ^chat_ids)
    |> Ash.Query.load(summary_loads())
    |> Ash.read!(actor: actor)
  end
end
