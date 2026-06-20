defmodule IntellectualClubWeb.Bff.ChatListController do
  @moduledoc """
  Chat list BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.Listing
  alias IntellectualClub.Chat.ListingStats
  alias IntellectualClub.Chat.Revisions
  alias IntellectualClub.Chat.Search, as: ChatSearch
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  def index(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, bot_filter} <- ChatParams.bot_filter(conn.params) do
      preview_len = ChatParams.preview_len(conn.params)
      pagination = ChatParams.pagination(conn.params)

      page =
        Listing.read_page(actor, bot_filter, pagination, [
          :bot,
          :last_message,
          :last_activity_at,
          :can_edit,
          :shared_incoming,
          :shared_outgoing,
          llm_configuration: [:model_name, :note, :provider]
        ])

      chats = Map.get(page, :results, [])
      active_branch_summaries = Listing.active_branch_summaries(chats, actor)

      first_message_previews =
        Listing.active_root_message_previews(chats, active_branch_summaries, preview_len, actor)

      sidebar_stats = ListingStats.sidebar(actor)
      child_handoff_counts = Listing.child_handoff_counts(Enum.map(chats, & &1.id), actor)

      payload =
        Enum.map(chats, fn chat ->
          activity_at = Listing.activity_at(chat)
          active_branch_summary = Map.get(active_branch_summaries, chat.id, %{})

          {first_message_preview, first_message_role} =
            Map.get(first_message_previews, chat.id, {nil, nil})

          Serializer.chat_summary(chat,
            activity_at: activity_at,
            child_handoff_count: Map.get(child_handoff_counts, chat.id, 0)
          )
          |> Map.put(:message_count, Map.get(active_branch_summary, :message_count, 0))
          |> Map.put(:first_message_preview, first_message_preview)
          |> Map.put(:first_message_role, first_message_role)
        end)

      json(conn, %{
        chats: payload,
        page: %{
          number: pagination.page,
          per_page: pagination.per_page,
          total: Map.get(page, :count, length(payload)),
          has_next: Map.get(page, :more?, false)
        },
        stats: Serializer.chat_list_stats(sidebar_stats),
        idle_revision: Revisions.chat_list_revision(pagination, bot_filter, page, chats)
      })
    else
      {:error, error_message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message})
    end
  end

  def search(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      term = params |> Map.get("q", "") |> to_string()
      pagination = ChatParams.pagination(params)

      with {:ok, bot_filter} <- ChatParams.bot_filter(params) do
        payload =
          term
          |> ChatSearch.search_chats(actor,
            bot_filter: bot_filter,
            limit: pagination.per_page
          )
          |> Enum.map(fn entry ->
            chat = entry.chat
            activity_at = Listing.activity_at(chat)

            Serializer.chat_summary(chat, activity_at: activity_at)
            |> Map.put(:message_count, entry.message_count)
            |> Map.put(:match_type, ChatParams.match_type(entry.match_type))
            |> Map.put(:snippet, entry.snippet)
            |> Map.put(:message_id, entry.message_id)
            |> Map.put(:message_role, entry.message_role)
          end)

        json(conn, %{chats: payload})
      else
        {:error, error_message} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: error_message})
      end
    end
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
            :bot,
            :last_message,
            :last_activity_at,
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

      child_handoff_counts = Listing.child_handoff_counts([chat.id], actor)

      activity_at = Listing.activity_at(chat)
      active_branch_summary = Map.get(active_branch_summaries, chat.id, %{})

      {first_message_preview, first_message_role} =
        Map.get(first_message_previews, chat.id, {nil, nil})

      payload =
        Serializer.chat_summary(chat,
          activity_at: activity_at,
          child_handoff_count: Map.get(child_handoff_counts, chat.id, 0)
        )
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

  def idle_state(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, bot_filter} <- ChatParams.bot_filter(params) do
      pagination = ChatParams.pagination(params)
      page = Listing.read_page(actor, bot_filter, pagination, [:last_message])
      chats = Map.get(page, :results, [])
      revision = Revisions.chat_list_revision(pagination, bot_filter, page, chats)

      if Revisions.client_revision_matches?(params, revision) do
        send_resp(conn, :no_content, "")
      else
        json(conn, %{
          revision: revision,
          active_generation_message_id: Revisions.visible_active_generation_message_id(chats)
        })
      end
    else
      {:error, error_message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message})
    end
  end
end
