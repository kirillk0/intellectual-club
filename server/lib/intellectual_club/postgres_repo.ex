defmodule IntellectualClub.PostgresRepo do
  use AshPostgres.Repo,
    otp_app: :intellectual_club,
    warn_on_missing_ash_functions?: false

  def installed_extensions, do: ["ash-functions", "pg_trgm"]

  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
