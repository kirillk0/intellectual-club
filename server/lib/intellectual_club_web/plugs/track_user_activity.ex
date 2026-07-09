defmodule IntellectualClubWeb.Plugs.TrackUserActivity do
  @moduledoc """
  Records authenticated API activity without affecting the request outcome.
  """

  @behaviour Plug

  alias IntellectualClub.Accounts

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> actor()
    |> Accounts.touch_user_activity()

    conn
  end

  defp actor(conn) do
    Ash.PlugHelpers.get_actor(conn) || conn.assigns[:current_user]
  end
end
