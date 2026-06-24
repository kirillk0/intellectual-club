defmodule IntellectualClubWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :intellectual_club

  @dev_static_assets Mix.env() != :prod
  @static_cache_control if(@dev_static_assets,
                          do: "no-cache, must-revalidate",
                          else: "public"
                        )
  @gzip_static_assets not @dev_static_assets

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_intellectual_club_key",
    signing_salt: "jWQ9cUFO",
    max_age: 30 * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # Keep LiveView processes alive for up to 20 minutes after the WebSocket
  # disconnects.  This covers mobile Safari aggressively suspending background
  # tabs — the user can return to the same view without a full remount, which
  # preserves scroll position and draft text.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      timeout: 1_200_000
    ],
    longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # In development the SPA assets are rebuilt by Vite while Phoenix code
  # reloading can stay disabled, so avoid browser/module cache sticking to
  # older chunks. Production keeps serving precompressed digest assets.
  plug Plug.Static,
    at: "/",
    from: :intellectual_club,
    gzip: @gzip_static_assets,
    cache_control_for_etags: @static_cache_control,
    only: IntellectualClubWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug IntellectualClubWeb.Plugs.LiveReloaderUnlessSpa
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :intellectual_club
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json, AshJsonApi.Plug.Parser],
    pass: ["*/*"],
    # Tool results can be large (e.g., base64 images). Keep this high enough to
    # avoid opaque connection resets on the runner side.
    length: IntellectualClubWeb.RequestLimits.max_body_length_bytes(),
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug IntellectualClubWeb.Router
end
