defmodule IntellectualClubWeb.HealthController do
  @moduledoc """
  Exposes a dependency-free liveness probe for client recovery.
  """

  use IntellectualClubWeb, :controller

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(:no_content, "")
  end
end
