defmodule IntellectualClubWeb.Bff.ChatSearchController do
  @moduledoc """
  Chat search BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.Search, as: ChatSearch
  alias IntellectualClubWeb.Bff.Helpers

  def messages(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      term = params |> Map.get("q", "") |> to_string()

      json(conn, ChatSearch.search_messages_in_chat(chat_id, term, actor))
    end
  end
end
