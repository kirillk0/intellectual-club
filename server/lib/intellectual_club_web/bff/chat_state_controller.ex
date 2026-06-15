defmodule IntellectualClubWeb.Bff.ChatStateController do
  @moduledoc """
  Chat state BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Revisions
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.ChatPayloads
  alias IntellectualClubWeb.Bff.Helpers

  def state(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, %Chat{} = chat} <- ChatAccess.fetch_readable_chat(chat_id, actor) do
      json(conn, ChatPayloads.state(chat, actor))
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:ok, nil} ->
        ChatAccess.render_error(conn, :not_found)

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end

  def settings(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, %Chat{} = chat} <- ChatAccess.fetch_readable_chat(chat_id, actor) do
      json(conn, ChatPayloads.settings(chat, actor))
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:ok, nil} ->
        ChatAccess.render_error(conn, :not_found)

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end

  def prompt_context(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      chat = Ash.get!(Chat, chat_id, actor: actor)
      json(conn, ChatPayloads.prompt_context(chat, actor))
    end
  end

  def idle_state(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, %Chat{} = chat} <- ChatAccess.fetch_readable_chat_for_idle(chat_id, actor) do
      revision = Revisions.chat_revision(chat)

      if Revisions.client_revision_matches?(params, revision) do
        send_resp(conn, :no_content, "")
      else
        json(conn, %{
          revision: revision,
          active_generation_message_id: Revisions.active_generation_message_id(chat)
        })
      end
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:ok, nil} ->
        ChatAccess.render_error(conn, :not_found)

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end
end
