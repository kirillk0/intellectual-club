import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/intellectual_club start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :intellectual_club, IntellectualClubWeb.Endpoint, server: true
end

endpoint_http_port = String.to_integer(System.get_env("PORT", "4000"))

config :intellectual_club, IntellectualClubWeb.Endpoint, http: [port: endpoint_http_port]

if demo_chunk_delay_ms = System.get_env("DEMO_CHUNK_DELAY_MS") do
  config :intellectual_club, :demo_chunk_delay_ms, String.to_integer(demo_chunk_delay_ms)
end

database_url =
  System.get_env("DATABASE_URL")
  |> to_string()
  |> String.trim()
  |> case do
    "" -> nil
    url -> url
  end

use_postgres? =
  case database_url do
    nil ->
      false

    url ->
      String.starts_with?(url, ["postgres://", "postgresql://", "ecto://"])
  end

if use_postgres? do
  config :intellectual_club,
    active_repo: IntellectualClub.PostgresRepo,
    active_data_layer: AshPostgres.DataLayer,
    ecto_repos: [IntellectualClub.PostgresRepo]

  config :intellectual_club, IntellectualClub.PostgresRepo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    priv: "priv/repo"

  if config_env() == :test do
    config :intellectual_club, IntellectualClub.PostgresRepo, pool: Ecto.Adapters.SQL.Sandbox
  end
else
  config :intellectual_club,
    active_repo: IntellectualClub.Repo,
    active_data_layer: AshSqlite.DataLayer,
    ecto_repos: [IntellectualClub.Repo]
end

phx_host =
  case System.get_env("PHX_HOST") do
    nil ->
      nil

    value ->
      value = String.trim(value)
      if value == "", do: nil, else: value
  end

if config_env() != :prod && phx_host do
  phx_scheme = System.get_env("PHX_SCHEME") || "http"
  phx_port = System.get_env("PHX_PORT") || Integer.to_string(endpoint_http_port)

  config :intellectual_club, IntellectualClubWeb.Endpoint,
    url: [host: phx_host, port: String.to_integer(phx_port), scheme: phx_scheme]
end

if config_env() == :prod do
  token_signing_secret =
    System.get_env("TOKEN_SIGNING_SECRET") ||
      raise """
      environment variable TOKEN_SIGNING_SECRET is missing.
      """

  config :intellectual_club,
    token_signing_secret: token_signing_secret

  if !use_postgres? do
    data_dir = System.get_env("DATA_DIR") || Path.expand("../../data", __DIR__)
    File.mkdir_p!(data_dir)

    database_path =
      System.get_env("DATABASE_PATH") || Path.join(data_dir, "intellectual_club.sqlite3")

    config :intellectual_club, IntellectualClub.Repo,
      database: database_path,
      pool_size: 1
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = phx_host || "example.com"
  scheme = System.get_env("PHX_SCHEME") || "https"

  port =
    System.get_env("PHX_PORT") || if(scheme == "https", do: "443", else: "#{endpoint_http_port}")

  config :intellectual_club, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :intellectual_club, IntellectualClubWeb.Endpoint,
    url: [host: host, port: String.to_integer(port), scheme: scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :intellectual_club, IntellectualClubWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :intellectual_club, IntellectualClubWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
