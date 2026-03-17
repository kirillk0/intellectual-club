import Config

data_dir = Path.expand("../../data", __DIR__)
File.mkdir_p!(data_dir)

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :intellectual_club, IntellectualClub.Repo,
  database: Path.join(data_dir, "intellectual_club_test.db"),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :intellectual_club, IntellectualClubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "6LK+UHC3ckuNy2R/3l+kGriwYBIXTJ51fVundP0DyxQiQTKhsxmn8iqOi3ITFLBP",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :intellectual_club,
  token_signing_secret: "test-token-signing-secret",
  openai_oauth_req_options: [
    plug: {Req.Test, IntellectualClub.Llm.Auth.OpenAIOAuth}
  ]
