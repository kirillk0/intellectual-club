# PostgreSQL is the test backend. EXUNIT_MAX_CASES controls local concurrency;
# use `mix test --partitions` when CI needs separate test databases.
ExUnit.start(max_cases: String.to_integer(System.get_env("EXUNIT_MAX_CASES", "1")))
Ecto.Adapters.SQL.Sandbox.mode(IntellectualClub.Db.repo(), :manual)
