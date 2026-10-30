defmodule IntellectualClubWeb.Bff.ChatDraftsController do
  @moduledoc "Private, versioned chat composer text."
  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.ChatDraft
  alias IntellectualClubWeb.Bff.{ChatAccess, ChatParams, Helpers}

  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, draft} <- ChatDraft.get(chat_id, actor) do
      conn |> put_resp_header("cache-control", "no-store") |> json(%{draft: draft})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, error} -> ChatAccess.render_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, result} <- ChatDraft.save(chat_id, params, actor) do
      conn = put_resp_header(conn, "cache-control", "no-store")

      case result do
        %{error: :not_found} ->
          ChatAccess.render_error(conn, :not_found)

        %{error: error} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: error})

        %{draft: draft, conflict: conflict} ->
          conn |> put_status(if(conflict, do: :conflict, else: :ok)) |> json(%{draft: draft})
      end
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, error} -> ChatAccess.render_error(conn, error)
    end
  end
end
