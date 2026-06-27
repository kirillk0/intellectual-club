import Config

# Tests require PostgreSQL and never fall back to the legacy SQLite repo.
import_config "test_database.exs"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :intellectual_club, IntellectualClubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "6LK+UHC3ckuNy2R/3l+kGriwYBIXTJ51fVundP0DyxQiQTKhsxmn8iqOi3ITFLBP",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Keep password hashing representative but cheap in tests.
config :bcrypt_elixir, log_rounds: 1

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :intellectual_club,
  demo_chunk_delay_ms: 0,
  recover_orphaned_generations_on_startup: false,
  token_signing_secret: "test-token-signing-secret",
  openai_oauth_req_options: [
    plug: {Req.Test, IntellectualClub.Llm.Auth.OpenAIOAuth}
  ]
