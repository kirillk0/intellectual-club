defmodule IntellectualClubWeb.LiveUserAuth do
  @moduledoc """
  LiveView on-mount hooks for authentication.
  """

  import Phoenix.Component
  use IntellectualClubWeb, :verified_routes

  def on_mount(:live_user_optional, _params, _session, socket) do
    socket =
      socket
      |> assign_new(:current_user, fn -> nil end)
      |> assign_current_scope()

    {:cont, socket}
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:cont, assign_current_scope(socket)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      socket =
        socket
        |> assign(:current_user, nil)
        |> assign(:current_scope, nil)

      {:cont, socket}
    end
  end

  def on_mount(:admin_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{is_admin: true} ->
        {:cont, socket}

      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}

      _user ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    end
  end

  defp assign_current_scope(socket) do
    case socket.assigns[:current_user] do
      nil -> assign(socket, :current_scope, nil)
      user -> assign(socket, :current_scope, %{user: user})
    end
  end
end
