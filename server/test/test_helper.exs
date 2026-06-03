# SQLite and Ecto SQL Sandbox are not safe for concurrent database tests.
# Use `mix test --partitions` for CI parallelism; config/test.exs gives each
# partition a separate SQLite database file.
ExUnit.start(max_cases: String.to_integer(System.get_env("EXUNIT_MAX_CASES", "1")))
Ecto.Adapters.SQL.Sandbox.mode(IntellectualClub.Db.repo(), :manual)
