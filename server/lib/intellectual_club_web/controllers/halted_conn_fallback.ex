defmodule IntellectualClubWeb.HaltedConnFallback do
  @moduledoc """
  Action fallback for helpers that respond themselves and return
  `{:error, conn}` with the halted connection, such as
  `IntellectualClubWeb.Bff.Helpers.require_actor/1`.

  Actions can then pass such results through `with` without an `else` clause.
  Any other non-`Plug.Conn` return value still fails the request.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(_conn, {:error, %Plug.Conn{halted: true} = conn}), do: conn
end
