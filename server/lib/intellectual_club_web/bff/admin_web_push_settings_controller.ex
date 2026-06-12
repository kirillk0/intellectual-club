defmodule IntellectualClubWeb.Bff.AdminWebPushSettingsController do
  @moduledoc """
  Administrative Web Push settings endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Notifications
  alias IntellectualClubWeb.Bff.Helpers

  def show(conn, _params) do
    with {:ok, actor} <- Helpers.require_admin(conn) do
      json(conn, %{settings: Notifications.admin_settings(actor)})
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  def update(conn, params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         {:ok, settings} <- Notifications.update_admin_settings(params, actor) do
      json(conn, %{settings: settings})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def regenerate_keys(conn, _params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         {:ok, settings} <- Notifications.regenerate_vapid_keys(actor) do
      json(conn, %{settings: settings})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp render_error(conn, {:validation, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{detail: message})
  end

  defp render_error(conn, %Ash.Error.Forbidden{}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden"})
  end

  defp render_error(conn, %Ash.Error.Invalid{} = error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{detail: "Validation failed", error: Exception.message(error)})
  end

  defp render_error(conn, error) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: inspect(error)})
  end
end
