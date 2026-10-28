defmodule IntellectualClub.Chat.Search do
  @moduledoc """
  Search helpers for chats and chat messages.

  All queries go through Ash and therefore respect authorization policies.
  """

  alias Ash.CiString
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Listing
  alias IntellectualClub.Chat.MessageText
  alias IntellectualClub.Chat.Threads

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

  defp search_meta_chats(term, bot_filter, limit, actor) do
    term = contains_query_term(term)

    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(subagent == false)
    |> Listing.without_handoff_children(actor)
    |> Ash.Query.filter(contains(note, ^term) or exists(bot, contains(name, ^term)))
    |> apply_bot_filter(bot_filter)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load([
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

  defp search_message_candidates(search, bot_filter, meta_ids, limit, actor)
       when is_tuple(search) do
    read_message_candidates(search, bot_filter, meta_ids, limit * 2, actor)
  end

  defp read_message_candidates(search, bot_filter, meta_ids, limit, actor)
       when is_tuple(search) do
    meta_list = MapSet.to_list(meta_ids)
    handoff_relation_kind = Handoff.relation_kind()

    ChatMessage
    |> Ash.Query.sort(created_at: :desc, id: :desc)
    |> Ash.Query.for_read(:search, %{q: elem(search, 1)}, actor: actor)
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(
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
    |> Ash.Query.filter(subagent == false)
    |> Listing.without_handoff_children(actor)
    |> Ash.Query.filter(id in ^chat_ids)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load([
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

  defp contains_query_term(term) when is_binary(term) do
    CiString.new(term)
  end
end
