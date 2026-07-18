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
          |> render_shell(nil)
        else
          conn
          |> put_session(:return_to, current_path(conn))
          |> redirect(to: ~p"/login?next=#{current_path(conn)}")
          |> halt()
        end

      user ->
        conn
        |> render_shell(user)
    end
  end

  def app_shell(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> assign(:spa, true)
    |> assign(:session_bootstrap_required, true)
    |> render(:index, current_user: nil)
  end

  defp render_shell(conn, current_user) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> assign(:spa, true)
    |> assign(:session_bootstrap_required, false)
    |> render(:index, current_user: current_user)
  end

  defp login_path?(conn), do: conn.request_path == "/login"
end
