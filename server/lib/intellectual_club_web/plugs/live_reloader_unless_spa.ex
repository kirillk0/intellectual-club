if Code.ensure_loaded?(Phoenix.LiveReloader) do
  defmodule IntellectualClubWeb.Plugs.LiveReloaderUnlessSpa do
    @moduledoc """
    Wraps `Phoenix.LiveReloader` to avoid injecting the live reload iframe into SPA pages.

    The SPA is built separately and is reloaded manually, so the live reload websocket adds
    noise (and occasionally latency) without much benefit.
    """

    @behaviour Plug

    @impl true
    def init(opts), do: Phoenix.LiveReloader.init(opts)

    @impl true
    def call(conn, opts) do
      if spa_path?(conn) do
        conn
      else
        Phoenix.LiveReloader.call(conn, opts)
      end
    end

    defp spa_path?(%Plug.Conn{path_info: ["phoenix", "live_reload" | _]}), do: false
    defp spa_path?(%Plug.Conn{path_info: []}), do: true
    defp spa_path?(%Plug.Conn{path_info: ["chats" | _]}), do: true
    defp spa_path?(%Plug.Conn{path_info: ["catalogs" | _]}), do: true
    defp spa_path?(_conn), do: false
  end
else
  defmodule IntellectualClubWeb.Plugs.LiveReloaderUnlessSpa do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts), do: conn
  end
end
