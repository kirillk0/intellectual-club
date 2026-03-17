defmodule IntellectualClubWeb.AuthController do
  @moduledoc """
  Session-based authentication controller used by AshAuthenticationPhoenix.
  """

  use IntellectualClubWeb, :controller
  use AshAuthentication.Phoenix.Controller

  @impl true
  def success(conn, _activity, user, _token) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> redirect(to: return_to)
  end

  @impl true
  def failure(conn, _activity, _reason) do
    conn
    |> put_flash(:error, "Incorrect username or password")
    |> redirect(to: ~p"/login")
  end

  @impl true
  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:intellectual_club)
    |> redirect(to: return_to)
  end
end
