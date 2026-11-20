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

  @default_message_limit 50
  @default_hit_limit 30
  @max_hit_limit 100
  @notes_limit 20
  @default_probe_window 96
  @cursor_salt "chat-search-hits-v3"

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

  Options: `exact?` (consecutive word prefixes, default `false`), `limit`.
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

        chat = Ash.get!(Chat, chat_id, actor: actor, load: [:id, :last_message_id], strict?: true)

        messages =
          ChatMessage
          |> Ash.Query.sort(created_at: :asc, id: :asc)
          |> Ash.Query.for_read(:search, %{q: query, exact: exact?, chat_id: chat_id},
            actor: actor
          )
          |> Ash.Query.limit(limit)
          |> Ash.read!(actor: actor, page: false)

        active_ids =
          if messages == [],
            do: MapSet.new(),
            else: Map.fetch!(Threads.active_branch_ids_for_chats([chat], actor), chat_id)

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
  Searches the actor's inbox and archived chats together.

  Returns note matches (first page only) and unique message hits newest first.
  Both modes use the same word prefixes; `exact?` requires adjacent positions.
  A bounded recent window can fill a page without expanding a common prefix
  through the GIN index. Original text is read only for the returned hits.

  Options: `exact?`, `bot_filter`, `after` (cursor), `limit`, `compact?`.
  """
  @spec search_chat_list(String.t() | nil, any(), keyword()) ::
          {:ok, list_result()} | {:error, :timeout | :invalid_cursor}
  def search_chat_list(query, actor, opts \\ []) when is_list(opts) do
    SearchDeadline.run(fn ->
      ordered? = Keyword.get(opts, :exact?, false)
      bot_filter = Keyword.get(opts, :bot_filter)
      compact? = Keyword.get(opts, :compact?, false)
      limit = opts |> Keyword.get(:limit, @default_hit_limit) |> min(@max_hit_limit) |> max(1)
      search = MessageText.search(query, ordered?)
      scope = cursor_scope(search, actor, bot_filter)
      position = decode_cursor(Keyword.get(opts, :after), scope)

      case search do
        :empty ->
          empty_result()

        {_mode, terms} ->
          {messages, has_next?} =
            read_hits(%{q: query, exact?: ordered?}, actor, bot_filter, position, limit)

          next_cursor = if has_next?, do: encode_cursor(List.last(messages), scope)

          SearchDeadline.query(fn ->
            notes = if is_nil(position), do: note_ids(search, actor, bot_filter), else: []
            ids = Enum.uniq(notes ++ Enum.map(messages, & &1.chat_id))
            chats = load_chats(ids, actor, bot_filter, compact?)
            by_id = Map.new(chats, &{&1.id, &1})
            visible = Enum.filter(messages, &Map.has_key?(by_id, &1.chat_id))
            branches = Threads.active_branch_ids_for_chats(chats, actor)
            snippets = MessageText.load_snippets(visible, search, actor)

            hits =
              Enum.map(visible, fn m ->
                %{
                  message_id: m.id,
                  chat_id: m.chat_id,
                  role: role_to_string(m.role),
                  created_at: datetime_iso(m.created_at),
                  active?: MapSet.member?(Map.fetch!(branches, m.chat_id), m.id),
                  snippet: Map.get(snippets, m.id)
                }
              end)

            %{
              chats: for(id <- ids, chat = by_id[id], do: chat),
              notes: Enum.filter(notes, &Map.has_key?(by_id, &1)),
              hits: hits,
              message_counts:
                Map.new(branches, fn {id, members} -> {id, MapSet.size(members)} end),
              next_cursor: next_cursor,
              text_search?: true,
              terms: terms
            }
          end)
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

  # The optional probe is disposable. If it times out, retry the indexed read
  # at the original cursor, never at a partially examined position.
  defp read_hits(context, actor, bot_filter, position, limit) do
    window =
      Application.get_env(:intellectual_club, :chat_search_probe_window, @default_probe_window)

    wanted = limit + 1

    probe =
      SearchDeadline.probe(fn ->
        candidates = window_candidates(actor, bot_filter, position, window)
        ids = Enum.map(candidates, & &1.id)

        hits =
          if ids == [] do
            []
          else
            hits_query(context, actor, bot_filter, :recent)
            |> Ash.Query.filter(id in ^ids)
            |> Ash.Query.limit(wanted)
            |> Ash.read!(actor: actor, page: false)
          end

        {hits, List.last(candidates), length(ids) < window}
      end)

    {first, cutoff, exhausted?} =
      case probe do
        {:ok, {first, nil, exhausted?}} -> {first, position, exhausted?}
        {:ok, {first, last, exhausted?}} -> {first, {last.created_at, last.id}, exhausted?}
        {:error, :statement_timeout} -> {[], position, false}
      end

    rows =
      if length(first) == wanted or exhausted? do
        first
      else
        rest =
          SearchDeadline.query(fn ->
            hits_query(context, actor, bot_filter, :indexed)
            |> after_position(cutoff)
            |> Ash.Query.limit(wanted - length(first))
            |> Ash.read!(actor: actor, page: false)
          end)

        first ++ rest
      end

    {Enum.take(rows, limit), length(rows) > limit}
  end

  defp hits_query(%{q: query, exact?: exact?}, actor, bot_filter, strategy) do
    ChatMessage
    |> Ash.Query.for_read(:list_search, %{q: query, exact: exact?, strategy: strategy},
      actor: actor
    )
    |> chat_filters(actor, bot_filter)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.select([:id, :chat_id, :role, :created_at])
  end

  # The newest messages a probe may inspect, oldest last.
  defp window_candidates(actor, bot_filter, position, window) do
    ChatMessage
    |> Ash.Query.for_read(:list_search_window, %{}, actor: actor)
    |> chat_filters(actor, bot_filter)
    |> after_position(position)
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.select([:id, :created_at])
    |> Ash.Query.limit(window)
    |> Ash.read!(actor: actor, page: false)
  end

  defp after_position(query, nil), do: query

  defp after_position(query, {time, id}),
    do: Ash.Query.filter(query, created_at < ^time or (created_at == ^time and id < ^id))

  defp note_ids(search, actor, bot_filter) do
    predicate = MessageText.note_predicate(search)

    Chat
    |> Ash.Query.filter(owner_id == ^actor.id and subagent == false)
    |> Listing.apply_bot_filter(bot_filter)
    |> Ash.Query.filter(^predicate)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(@notes_limit)
    |> Ash.read!(actor: actor, page: false)
    |> Enum.map(& &1.id)
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

  defp chat_filters(query, actor, :none),
    do:
      Ash.Query.filter(
        query,
        exists(chat, owner_id == ^actor.id and subagent == false and is_nil(bot_id))
      )

  defp chat_filters(query, actor, bot_id) when is_integer(bot_id),
    do:
      Ash.Query.filter(
        query,
        exists(chat, owner_id == ^actor.id and subagent == false and bot_id == ^bot_id)
      )

  defp chat_filters(query, actor, _all),
    do: Ash.Query.filter(query, exists(chat, owner_id == ^actor.id and subagent == false))

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

  defp load_chats([], _actor, _bot_filter, _compact?), do: []

  defp load_chats(ids, actor, bot_filter, compact?) do
    query =
      Chat
      |> Ash.Query.filter(owner_id == ^actor.id and subagent == false and id in ^ids)
      |> Listing.apply_bot_filter(bot_filter)

    query =
      if compact? do
        query
        |> Ash.Query.select([
          :id,
          :owner_id,
          :last_message_id,
          :note,
          :bot_id,
          :created_at,
          :updated_at
        ])
        |> Ash.Query.load([:read_state, bot: [:name]], strict?: true)
      else
        Ash.Query.load(query, summary_loads())
      end

    Ash.read!(query, actor: actor, page: false)
  end
end
