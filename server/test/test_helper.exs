# PostgreSQL is the test backend. EXUNIT_MAX_CASES bounds async concurrency;
# `bin/server-test` runs `mix test --partitions` with one database per partition.
#
# `:whitebox` tests assert implementation details (SQL round trips, call traces,
# lock order, scaling) rather than behavior. They are excluded by default and
# run in CI: `mix test --include whitebox` or `bin/server-test --all`.
max_cases = String.to_integer(System.get_env("EXUNIT_MAX_CASES", "#{System.schedulers_online()}"))

ExUnit.start(max_cases: max_cases, exclude: [:whitebox])
Ecto.Adapters.SQL.Sandbox.mode(IntellectualClub.Repo, :manual)

# The default file storage is a fresh temporary directory of this VM (see
# config/runtime.exs); remove it unless FILE_STORAGE_PATH was set explicitly.
if String.trim(System.get_env("FILE_STORAGE_PATH", "")) == "" do
  file_storage_path = Application.fetch_env!(:intellectual_club, :file_storage_path)
  ExUnit.after_suite(fn _result -> File.rm_rf(file_storage_path) end)
end
