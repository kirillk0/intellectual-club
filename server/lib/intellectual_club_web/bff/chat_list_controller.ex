defmodule IntellectualClubWeb.Bff.ChatListController do
  @moduledoc """
  Chat list BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatDraft
  alias IntellectualClub.Chat.Listing
  alias IntellectualClub.Chat.ListingStats
  alias IntellectualClub.Chat.Revisions
  alias IntellectualClub.Chat.ReadState
  alias IntellectualClub.Chat.Search, as: ChatSearch
  alias IntellectualClub.Chat.SearchDeadline
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  def index(conn, %{"sections" => _} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, view} <- ChatParams.archive_view(params),
         {:ok, bot_filter} <- ChatParams.bot_filter(params),
         {:ok, sections} <- list_sections(params) do
      result =
        Listing.read_sections(
          actor,
          bot_filter,
          section_paginations(params, sections),
          summary_loads(),
          view
        )

      marker = ReadState.list_marker(actor)
      drafts = ChatDraft.list_marker(actor)

      {payload, lifecycle_states} =
        list_entries_payload(result.results, actor, ChatParams.preview_len(params))

      json(conn, %{
        chats: payload,
        sections: result.sections,
        stats: Serializer.chat_list_stats(ListingStats.sidebar(actor, view)),
        next_read_state_expiry: marker.next_expiry,
        idle_revision:
          sections_revision(result, bot_filter, marker.rows, drafts, lifecycle_states, view)
      })
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, message} -> conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  def index(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, view} <- ChatParams.archive_view(conn.params),
         {:ok, bot_filter} <- ChatParams.bot_filter(conn.params) do
      preview_len = ChatParams.preview_len(conn.params)

      pagination =
        Map.merge(ChatParams.pagination(conn.params), %{
          section: conn.params["section"],
          view: view
        })

      page =
        Listing.read_page(actor, bot_filter, pagination, summary_loads())

      marker = ReadState.list_marker(actor)

      page =
        page
        |> Map.put(:read_state_marker, marker.rows)
        |> Map.put(:draft_marker, ChatDraft.list_marker(actor))

      chats = Map.get(page, :results, [])
      {payload, subchat_lifecycle_states} = list_entries_payload(chats, actor, preview_len)
      sidebar_stats = ListingStats.sidebar(actor, view)

      json(conn, %{
        chats: payload,
        next_read_state_expiry: marker.next_expiry,
        page: %{
          number: pagination.page,
          per_page: pagination.per_page,
          total: Map.get(page, :count, length(payload)),
          has_next: Map.get(page, :more?, false)
        },
        stats: Serializer.chat_list_stats(sidebar_stats),
        idle_revision:
          Revisions.chat_list_revision(
            pagination,
            bot_filter,
            page,
            chats,
            subchat_lifecycle_states
          )
      })
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error_message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message})
    end
  end

  def archive_other_preview(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, bot_filter} <- ChatParams.bot_filter(params) do
      snapshot = IntellectualClub.Chat.Archive.snapshot(actor, bot_filter)
      json(conn, Map.take(snapshot, [:count, :revision]))
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, message} -> conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  def archive_other(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, bot_filter} <- ChatParams.bot_filter(params),
         {:ok, result} <- ReadState.archive_other(actor, bot_filter, params["expected_revision"]) do
      case result do
        %{conflict: true} ->
          conn |> put_status(:conflict) |> json(%{error: "stale_archive_preview"})

        result ->
          json(conn, result)
      end
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, error} -> ChatAccess.render_error(conn, error)
    end
  end

  defp summary_loads do
    [
      :bot,
      :last_message,
      :last_activity_at,
      :blocks_count,
      :tools_count,
      :can_edit,
      :shared_incoming,
      :shared_outgoing,
      llm_configuration: [:model_name, :note, :provider]
    ]
  end

  defp list_entries_payload(chats, actor, preview_len) do
    drafts = ChatDraft.load_many(chats, actor)
    active_branch_summaries = Listing.active_branch_summaries(chats, actor)

    first_message_previews =
      Listing.active_root_message_previews(chats, active_branch_summaries, preview_len, actor)

    child_subchat_counts = Listing.child_subchat_counts(Enum.map(chats, & &1.id), actor)

    {subchats_by_parent, subchat_lifecycle_states} =
      direct_subchat_summaries(chats, actor, preview_len)

    payload =
      Enum.map(chats, fn chat ->
        activity_at = Listing.activity_at(chat)
        active_branch_summary = Map.get(active_branch_summaries, chat.id, %{})

        {first_message_preview, first_message_role} =
          Map.get(first_message_previews, chat.id, {nil, nil})

        Serializer.chat_summary(chat,
          activity_at: activity_at,
          child_subchat_count: Map.get(child_subchat_counts, chat.id, 0),
          subchats: Map.get(subchats_by_parent, chat.id, [])
        )
        |> Map.merge(Map.get(drafts, chat.id, %{has_draft: false, draft_updated_at: nil}))
        |> Map.put(:message_count, Map.get(active_branch_summary, :message_count, 0))
        |> Map.put(:first_message_preview, first_message_preview)
        |> Map.put(:first_message_role, first_message_role)
      end)

    {payload, subchat_lifecycle_states}
  end

  defp section_paginations(params, sections) do
    per_page = ChatParams.pagination(params).per_page

    Map.new(sections, fn section ->
      page = ChatParams.pagination(%{"page" => params["page_" <> section]}).page
      {section, %{section: section, page: page, per_page: per_page}}
    end)
  end

  defp sections_revision(result, bot_filter, read_marker, draft_marker, lifecycle_states, view) do
    Revisions.chat_list_sections_revision(
      bot_filter,
      result.sections,
      result.results,
      read_marker,
      draft_marker,
      lifecycle_states,
      view
    )
  end

  @list_sections ["drafts", "unread", "working", "other"]

  @doc """
  Searches the chat list.

  Returns chats whose note matches (`notes`, first page only) and message hits
  newest first (`hits`) with an opaque `next_cursor`; `chats` carries summaries
  for both. `exact=1` matches the whole query as one substring instead of every
  word. `limit` bounds hits per page.
  """
  def search(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, view} <- ChatParams.archive_view(params),
         {:ok, bot_filter} <- ChatParams.bot_filter(params) do
      term = params |> Map.get("q", "") |> to_string()

      render_search(conn, fn ->
        with {:ok, result} <-
               ChatSearch.search_chat_list(term, actor,
                 exact?: ChatParams.flag?(params, "exact"),
                 bot_filter: bot_filter,
                 view: view,
                 after: params["after"],
                 limit: ChatParams.search_limit(params)
               ) do
          SearchDeadline.query(fn ->
            %{
              chats: search_chats_payload(result, actor, params),
              notes: result.notes,
              hits: Enum.map(result.hits, &hit_payload/1),
              next_cursor: result.next_cursor,
              text_search: result.text_search?,
              terms: result.terms,
              next_read_state_expiry: ReadState.list_marker(actor).next_expiry
            }
          end)
        end
      end)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error_message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message})
    end
  end

  defp list_sections(%{"sections" => raw}) do
    sections =
      raw
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    if sections != [] and Enum.all?(sections, &(&1 in @list_sections)),
      do: {:ok, sections},
      else: {:error, "Invalid sections"}
  end

  defp render_search(conn, fun) do
    case SearchDeadline.run(fun) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :timeout} ->
        search_timeout(conn)

      {:error, :invalid_cursor} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid search cursor", code: "invalid_cursor"})
    end
  end

  defp search_timeout(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: gettext("Search took too long. Try a more specific query."),
      code: "search_timeout"
    })
  end

  defp hit_payload(hit) do
    %{
      message_id: hit.message_id,
      chat_id: hit.chat_id,
      role: hit.role,
      created_at: hit.created_at,
      active: hit.active?,
      snippet: hit.snippet
    }
  end

  defp search_chats_payload(result, actor, params) do
    chats = result.chats
    drafts = ChatDraft.load_many(chats, actor)

    {subchats_by_parent, _subchat_lifecycle_states} =
      direct_subchat_summaries(chats, actor, ChatParams.preview_len(params))

    child_subchat_counts = Listing.child_subchat_counts(Enum.map(chats, & &1.id), actor)

    Enum.map(chats, fn chat ->
      Serializer.chat_summary(chat,
        activity_at: Listing.activity_at(chat),
        child_subchat_count: Map.get(child_subchat_counts, chat.id, 0),
        subchats: Map.get(subchats_by_parent, chat.id, [])
      )
      |> Map.merge(Map.get(drafts, chat.id, %{has_draft: false, draft_updated_at: nil}))
      |> Map.put(:message_count, Map.get(result.message_counts, chat.id, 0))
    end)
  end

  def summary(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, chat} <- ChatAccess.fetch_readable_chat(chat_id, actor) do
      preview_len = ChatParams.preview_len(params)

      chat =
        Ash.load!(
          chat,
          [
            :read_state,
            :bot,
            :last_message,
            :last_activity_at,
            :blocks_count,
            :tools_count,
            :can_edit,
            :shared_incoming,
            :shared_outgoing,
            llm_configuration: [:model_name, :note, :provider]
          ],
          actor: actor
        )

      active_branch_summaries = Listing.active_branch_summaries([chat], actor)

      first_message_previews =
        Listing.active_root_message_previews([chat], active_branch_summaries, preview_len, actor)

      child_subchat_counts = Listing.child_subchat_counts([chat.id], actor)

      {subchats_by_parent, _subchat_lifecycle_states} =
        direct_subchat_summaries([chat], actor, preview_len)

      lifecycle_states = Subagent.lifecycle_states([chat], actor)

      activity_at = Listing.activity_at(chat)
      active_branch_summary = Map.get(active_branch_summaries, chat.id, %{})

      {first_message_preview, first_message_role} =
        Map.get(first_message_previews, chat.id, {nil, nil})

      drafts = ChatDraft.load_many([chat], actor)

      payload =
        chat
        |> Serializer.chat_summary(
          summary_opts(
            chat,
            lifecycle_states,
            activity_at: activity_at,
            child_subchat_count: Map.get(child_subchat_counts, chat.id, 0),
            subchats: Map.get(subchats_by_parent, chat.id, [])
          )
        )
        |> Map.merge(Map.get(drafts, chat.id, %{has_draft: false, draft_updated_at: nil}))
        |> Map.put(:message_count, Map.get(active_branch_summary, :message_count, 0))
        |> Map.put(:first_message_preview, first_message_preview)
        |> Map.put(:first_message_role, first_message_role)

      json(conn, %{chat: payload})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end

  def idle_state(conn, %{"sections" => _} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, view} <- ChatParams.archive_view(params),
         {:ok, bot_filter} <- ChatParams.bot_filter(params),
         {:ok, sections} <- list_sections(params) do
      result =
        Listing.read_sections(
          actor,
          bot_filter,
          section_paginations(params, sections),
          [
            :last_message,
            :blocks_count,
            :tools_count
          ],
          view
        )

      marker = ReadState.list_marker(actor)
      drafts = ChatDraft.list_marker(actor)
      lifecycle_states = direct_subchat_lifecycle_states(result.results, actor)

      revision =
        sections_revision(result, bot_filter, marker.rows, drafts, lifecycle_states, view)

      if is_nil(marker.next_expiry) and Revisions.client_revision_matches?(params, revision) do
        send_resp(conn, :no_content, "")
      else
        json(conn, %{
          revision: revision,
          next_read_state_expiry: marker.next_expiry,
          active_generation_message_id:
            Revisions.visible_active_generation_message_id(result.results, lifecycle_states)
        })
      end
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, message} -> conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  def idle_state(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, view} <- ChatParams.archive_view(params),
         {:ok, bot_filter} <- ChatParams.bot_filter(params) do
      pagination =
        Map.merge(ChatParams.pagination(params), %{section: params["section"], view: view})

      page =
        Listing.read_page(
          actor,
          bot_filter,
          pagination,
          [
            :last_message,
            :blocks_count,
            :tools_count
          ]
        )

      marker = ReadState.list_marker(actor)

      page =
        page
        |> Map.put(:read_state_marker, marker.rows)
        |> Map.put(:draft_marker, ChatDraft.list_marker(actor))

      chats = Map.get(page, :results, [])
      subchat_lifecycle_states = direct_subchat_lifecycle_states(chats, actor)

      revision =
        Revisions.chat_list_revision(
          pagination,
          bot_filter,
          page,
          chats,
          subchat_lifecycle_states
        )

      if is_nil(marker.next_expiry) and Revisions.client_revision_matches?(params, revision) do
        send_resp(conn, :no_content, "")
      else
        json(conn, %{
          revision: revision,
          next_read_state_expiry: marker.next_expiry,
          active_generation_message_id:
            Revisions.visible_active_generation_message_id(chats, subchat_lifecycle_states)
        })
      end
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error_message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message})
    end
  end

  def generation_state(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_ids = ChatParams.resource_ids(params, "chat_ids")
      message_ids = ChatParams.resource_ids(params, "message_ids")
      candidates = GenerationSupervisor.active_generation_candidates(chat_ids, message_ids)
      foreign_chat_ids = foreign_generation_chat_ids(candidates, actor.id)
      readable_foreign_chat_ids = readable_chat_ids(foreign_chat_ids, actor)

      chat_generations =
        candidates.chat_generations
        |> Enum.filter(&generation_readable?(&1, actor.id, readable_foreign_chat_ids))
        |> Enum.map(&Map.take(&1, [:chat_id, :message_id]))

      # Include persisted subchat lifecycle state when no worker is registered.
      inactive_chat_ids = chat_ids -- Enum.map(chat_generations, & &1.chat_id)
      chat_generations = chat_generations ++ subchat_generations(inactive_chat_ids, actor)

      active_message_ids =
        candidates.message_generations
        |> Enum.filter(&generation_readable?(&1, actor.id, readable_foreign_chat_ids))
        |> Enum.map(& &1.message_id)

      json(conn, %{
        chat_generations: chat_generations,
        active_message_ids: active_message_ids
      })
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  defp subchat_generations([], _actor), do: []

  defp subchat_generations(chat_ids, actor) do
    chats =
      Chat
      |> Ash.Query.filter(id in ^chat_ids and subagent == true)
      |> Ash.Query.load(:last_message, strict?: true)
      |> Ash.read!(actor: actor)

    chats
    |> Subagent.lifecycle_states(actor)
    |> Enum.sort_by(fn {chat_id, _state} -> chat_id end)
    |> Enum.flat_map(fn
      {chat_id, %{active_generation_message_id: message_id}} when is_integer(message_id) ->
        [%{chat_id: chat_id, message_id: message_id}]

      _other ->
        []
    end)
  end

  defp foreign_generation_chat_ids(candidates, owner_id) do
    candidates
    |> Map.values()
    |> List.flatten()
    |> Enum.reject(&(&1.owner_id == owner_id))
    |> Enum.map(& &1.chat_id)
    |> Enum.uniq()
  end

  defp readable_chat_ids([], _actor), do: MapSet.new()

  defp readable_chat_ids(chat_ids, actor) do
    Chat
    |> Ash.Query.filter(id in ^chat_ids)
    |> Ash.Query.select([:id])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, chats} -> MapSet.new(chats, & &1.id)
      {:error, _error} -> MapSet.new()
    end
  end

  defp generation_readable?(generation, owner_id, readable_foreign_chat_ids) do
    generation.owner_id == owner_id or
      MapSet.member?(readable_foreign_chat_ids, generation.chat_id)
  end

  defp direct_subchat_summaries(chats, actor, preview_len) when is_list(chats) do
    parent_ids = Enum.map(chats, & &1.id)

    subchats_by_parent =
      Listing.direct_subchats(parent_ids, actor, [
        :bot,
        :last_message,
        :last_activity_at,
        :blocks_count,
        :tools_count,
        :can_edit,
        :shared_incoming,
        :shared_outgoing,
        llm_configuration: [:model_name, :note, :provider]
      ])

    subchats =
      subchats_by_parent
      |> Map.values()
      |> List.flatten()

    lifecycle_states =
      Subagent.lifecycle_states(subchats, actor)
      |> with_read_states(subchats)

    active_branch_summaries = Listing.active_branch_summaries(subchats, actor)

    first_message_previews =
      Listing.active_root_message_previews(subchats, active_branch_summaries, preview_len, actor)

    child_subchat_counts = Listing.child_subchat_counts(Enum.map(subchats, & &1.id), actor)

    Map.new(subchats_by_parent, fn {parent_id, children} ->
      payloads =
        Enum.map(children, fn chat ->
          activity_at = Listing.activity_at(chat)
          active_branch_summary = Map.get(active_branch_summaries, chat.id, %{})

          {first_message_preview, first_message_role} =
            Map.get(first_message_previews, chat.id, {nil, nil})

          chat
          |> Serializer.chat_summary(
            summary_opts(
              chat,
              lifecycle_states,
              activity_at: activity_at,
              child_subchat_count: Map.get(child_subchat_counts, chat.id, 0),
              subchats: []
            )
          )
          |> Map.put(:message_count, Map.get(active_branch_summary, :message_count, 0))
          |> Map.put(:first_message_preview, first_message_preview)
          |> Map.put(:first_message_role, first_message_role)
        end)

      {parent_id, payloads}
    end)
    |> then(&{&1, lifecycle_states})
  end

  defp direct_subchat_summaries(_chats, _actor, _preview_len), do: {%{}, %{}}

  defp direct_subchat_lifecycle_states(chats, actor) when is_list(chats) do
    subchats =
      chats
      |> Enum.map(& &1.id)
      |> Listing.direct_subchats(actor, [:last_message])
      |> Map.values()
      |> List.flatten()

    Subagent.lifecycle_states(subchats, actor) |> with_read_states(subchats)
  end

  defp with_read_states(states, chats) do
    Enum.reduce(chats, states, fn chat, acc ->
      Map.update(
        acc,
        chat.id,
        %{read_state: chat.read_state},
        &Map.put(&1, :read_state, chat.read_state)
      )
    end)
  end

  defp summary_opts(chat, lifecycle_states, opts) do
    case Map.get(lifecycle_states, chat.id) do
      %{active_generation_message_id: message_id} ->
        opts
        |> Keyword.put(:active_generation_message_id, message_id)
        |> Keyword.put(
          :last_message_status,
          lifecycle_states[chat.id].last_message_status |> to_string()
        )

      _other ->
        opts
    end
  end
end
