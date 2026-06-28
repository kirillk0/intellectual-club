import Config

trim_env = fn name ->
  System.get_env(name)
  |> to_string()
  |> String.trim()
  |> case do
    "" -> nil
    value -> value
  end
end

postgres_url? = fn
  nil -> false
  url -> String.starts_with?(url, ["postgres://", "postgresql://", "ecto://"])
end

launcher_database_url = fn ->
  repo_root = Path.expand("../..", __DIR__)
  launcher_path = Path.join([repo_root, "build", "dev", "bin", "intellectual-club-launcher"])

  with launcher_path when is_binary(launcher_path) <- System.find_executable(launcher_path),
       {output, 0} <- System.cmd(launcher_path, ["status", "--json"], stderr_to_stdout: true),
       true <- Regex.match?(~r/"running"\s*:\s*true/, output),
       [_, url] <- Regex.run(~r/"database_url"\s*:\s*"([^"]+)"/, output) do
    String.trim(url)
  else
    _ -> nil
  end
end

replace_database_name = fn url, database_name ->
  uri = URI.parse(url)
  URI.to_string(%{uri | path: "/" <> database_name})
end

base_database_url =
  trim_env.("IC_TEST_DATABASE_URL") ||
    trim_env.("DATABASE_URL") ||
    launcher_database_url.()

unless postgres_url?.(base_database_url) do
  raise """
  PostgreSQL is required for MIX_ENV=test.

  Set IC_TEST_DATABASE_URL or DATABASE_URL to a PostgreSQL URL, or start the dev launcher:

      ./bin/build-dev-artifacts
      build/dev/bin/intellectual-club-launcher start
      cd server && mix test

  You can also use the wrapper, which starts the launcher when needed:

      ./bin/server-test
  """
end

test_partition = System.get_env("MIX_TEST_PARTITION") || ""

test_database_name =
  (trim_env.("IC_TEST_DATABASE_NAME") || "intellectual_club_test") <> test_partition

database_url = replace_database_name.(base_database_url, test_database_name)

config :intellectual_club,
  ecto_repos: [IntellectualClub.Repo]

config :intellectual_club, IntellectualClub.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  priv: "priv/repo",
  pool: Ecto.Adapters.SQL.Sandbox,
  show_sensitive_data_on_connection_error: true
