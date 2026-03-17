defmodule IntellectualClubWeb.Bff.SessionController do
  @moduledoc """
  Session endpoints for SPA authentication.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Accounts.User
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  def show(conn, _params) do
    case Helpers.require_actor(conn) do
      {:ok, actor} ->
        json(conn, %{user: Serializer.user(actor)})

      {:error, conn} ->
        conn
    end
  end

  def create(conn, params) do
    username = normalize_credential(Map.get(params, "username"))
    password = normalize_credential(Map.get(params, "password"), trim?: false)
    strategy = AshAuthentication.Info.strategy!(User, :password)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{
           "username" => username,
           "password" => password
         }) do
      {:ok, user} ->
        conn
        |> AshAuthentication.Plug.Helpers.store_in_session(user)
        |> assign(:current_user, user)
        |> json(%{user: Serializer.user(user)})

      {:error, _reason} ->
        invalid_credentials(conn)
    end
  end

  def delete(conn, _params) do
    conn
    |> AshAuthentication.Phoenix.Controller.clear_session(:intellectual_club)
    |> json(%{detail: "ok"})
  end

  defp invalid_credentials(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{detail: "Incorrect username or password."})
  end

  defp normalize_credential(value, opts \\ [])

  defp normalize_credential(value, opts) when is_binary(value) do
    if Keyword.get(opts, :trim?, true) do
      String.trim(value)
    else
      value
    end
  end

  defp normalize_credential(nil, _opts), do: ""

  defp normalize_credential(value, opts) do
    value
    |> to_string()
    |> normalize_credential(opts)
  end
end
