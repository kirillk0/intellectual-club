# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :intellectual_club,
  ecto_repos: [IntellectualClub.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    IntellectualClub.Accounts,
    IntellectualClub.Bots,
    IntellectualClub.Chat,
    IntellectualClub.Files,
    IntellectualClub.Knowledge,
    IntellectualClub.Llm,
    IntellectualClub.Notifications,
    IntellectualClub.Tools,
    IntellectualClub.Outlets
  ]

# Configure the endpoint
config :intellectual_club, IntellectualClubWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: IntellectualClubWeb.ErrorHTML, json: IntellectualClubWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: IntellectualClub.PubSub,
  live_view: [signing_salt: "iDOQOi8D"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  intellectual_club: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  intellectual_club: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# JSON:API content type support for AshJsonApi.
config :mime, :types, %{
  "application/vnd.api+json" => ["jsonapi"]
}

config :intellectual_club, :openai_oauth,
  client_id: "app_EMoamEEZ73f0CkXaXp7hrann",
  token_url: "https://auth.openai.com/oauth/token",
  refresh_early_seconds: 300,
  connect_timeout_ms: 10_000,
  request_timeout_ms: 30_000,
  lock_timeout_ms: 15_000,
  lock_stale_after_ms: 60_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
