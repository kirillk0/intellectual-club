defmodule IntellectualClubWeb.SpaController do
  @moduledoc """
  Serves the SPA shell.

  Authentication is session-based via AshAuthentication (cookie + CSRF meta tag).
  """

  use IntellectualClubWeb, :controller

  def index(conn, _params) do
    case conn.assigns[:current_user] do
      nil ->
        if login_path?(conn) do
          conn
          |> assign(:spa, true)
          |> render(:index, current_user: nil)
        else
          conn
          |> put_session(:return_to, current_path(conn))
          |> redirect(to: ~p"/login?next=#{current_path(conn)}")
          |> halt()
        end

      user ->
        conn
        |> assign(:spa, true)
        |> render(:index, current_user: user)
    end
  end

  defp login_path?(conn), do: conn.request_path == "/login"
end
