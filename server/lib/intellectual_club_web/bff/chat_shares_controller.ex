defmodule IntellectualClubWeb.Bff.ChatSharesController do
  @moduledoc """
  Chat sharing BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Sharing
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.Helpers

  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, state} <- Sharing.get_chat_share_state(chat_id, actor) do
      json(conn, state)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, group_ids} <- ChatParams.group_ids(params),
         {:ok, state} <- Sharing.replace_chat_share_state(chat_id, group_ids, actor) do
      json(conn, state)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end
end
