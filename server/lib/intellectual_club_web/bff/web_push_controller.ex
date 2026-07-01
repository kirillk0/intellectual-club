defmodule IntellectualClubWeb.Bff.WebPushController do
  @moduledoc """
  Current-user Web Push configuration and subscription endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Notifications
  alias IntellectualClubWeb.Bff.Helpers

  def config(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      json(conn, Notifications.client_config(actor))
    else
      {:error, %Plug.Conn{} = conn} -> conn
    end
  end

  def upsert_subscription(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, subscription} <-
           Notifications.upsert_subscription(actor, params, user_agent(conn)) do
      json(conn, %{
        status: "ok",
        subscription: %{
          id: subscription.id,
          endpoint: subscription.endpoint,
          key_revision: subscription.key_revision
        }
      })
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def delete_subscription(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         endpoint when is_binary(endpoint) <- Map.get(params, "endpoint"),
         :ok <- Notifications.delete_subscription(actor, endpoint) do
      json(conn, %{status: "ok"})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, reason} -> render_error(conn, reason)
      _other -> json(conn, %{status: "ok"})
    end
  end

  def client_state(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         :ok <- Notifications.record_client_state(actor, params) do
      json(conn, %{status: "ok"})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp user_agent(conn) do
    conn
    |> get_req_header("user-agent")
    |> List.first()
  end

  defp render_error(conn, :web_push_disabled) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{detail: "Web Push is disabled."})
  end

  defp render_error(conn, {:validation, message}) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{detail: message})
  end

  defp render_error(conn, :subscription_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Subscription not found"})
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
