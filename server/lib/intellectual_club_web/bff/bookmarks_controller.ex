defmodule IntellectualClubWeb.Bff.BookmarksController do
  @moduledoc """
  Bookmark-oriented BFF endpoints for the SPA.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.Bookmarking
  alias IntellectualClub.Chat.MessageBookmark
  alias IntellectualClub.Chat.Previews
  alias IntellectualClub.Chat.Threads
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Loads
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  @preview_length 220

  def index(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      bookmarks =
        MessageBookmark
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.Query.load(bookmark_load(), strict?: true)
        |> Ash.read!(actor: actor)

      chat_ids = bookmarked_chat_ids(bookmarks)
      active_ids_by_chat = Threads.active_branch_ids_by_chat(chat_ids, actor)
      message_count_by_chat = Threads.active_branch_counts_by_chat(chat_ids, actor)

      payload =
        bookmarks
        |> Enum.map(&bookmark_entry(&1, active_ids_by_chat, message_count_by_chat))
        |> Enum.reject(&is_nil/1)

      json(conn, %{bookmarks: payload})
    end
  end

  def toggle_message(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(id)

      case Bookmarking.toggle_message(message_id, actor) do
        {:ok, bookmarked} ->
          json(conn, %{message_id: message_id, bookmarked: bookmarked})

        {:error, %Ash.Error.Invalid{} = error} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: Exception.message(error)})

        {:error, %Ash.Error.Forbidden{} = error} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: Exception.message(error)})

        {:error, error} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to toggle bookmark: #{inspect(error)}"})
      end
    end
  end

  defp bookmark_load do
    [
      :id,
      :created_at,
      chat_message: [
        :id,
        :role,
        :created_at,
        :finished_at,
        :llm_configuration_id,
        steps: Loads.message_tree()[:steps],
        chat: [
          :id,
          :note,
          :bot_id,
          :llm_configuration_id,
          :parent_chat_id,
          :parent_message_id,
          :parent_relation_kind,
          :created_at,
          :updated_at,
          :can_edit,
          :shared_incoming,
          :shared_outgoing,
          bot: [:id, :name],
          last_message: [:id, :status, :created_at],
          llm_configuration: [:id, :model_name, :note]
        ]
      ]
    ]
  end

  defp bookmark_entry(bookmark, active_ids_by_chat, message_count_by_chat) do
    message = Map.get(bookmark, :chat_message)
    chat = if(is_map(message), do: Map.get(message, :chat), else: nil)

    if is_nil(message) or is_nil(chat) do
      nil
    else
      summary =
        chat
        |> Serializer.chat_summary(activity_at: chat_activity_at(chat))
        |> Map.put(:message_count, Map.get(message_count_by_chat, chat.id, 0))

      active_ids = Map.get(active_ids_by_chat, chat.id, MapSet.new())
      {preview, preview_role} = Previews.message_preview(message, @preview_length)

      %{
        bookmark_id: bookmark.id,
        bookmarked_at: Serializer.datetime_iso(Map.get(bookmark, :created_at)),
        inactive: not MapSet.member?(active_ids, message.id),
        message_id: message.id,
        message_role: preview_role,
        message_created_at: Serializer.datetime_iso(Map.get(message, :created_at)),
        preview: preview,
        chat: summary
      }
    end
  end

  defp chat_activity_at(chat) do
    case Map.get(chat, :last_message) do
      %{created_at: %DateTime{} = created_at} ->
        created_at

      %{created_at: %NaiveDateTime{} = created_at} ->
        created_at

      _ ->
        chat.updated_at || chat.created_at
    end
  end

  defp bookmarked_chat_ids(bookmarks) when is_list(bookmarks) do
    bookmarks
    |> Enum.map(fn bookmark ->
      bookmark
      |> Map.get(:chat_message)
      |> case do
        %{chat: %{id: chat_id}} when is_integer(chat_id) -> chat_id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
