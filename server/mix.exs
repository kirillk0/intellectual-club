defmodule IntellectualClub.MixProject do
  use Mix.Project

  def project do
    [
      app: :intellectual_club,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {IntellectualClub.Application, []},
      extra_applications: [:logger, :runtime_tools, :ssh]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:ash, "~> 3.16"},
      {:ash_sqlite, "~> 0.2.15"},
      {:ash_postgres, "~> 2.6"},
      {:postgrex, ">= 0.0.0"},
      {:ash_json_api, "~> 1.5"},
      {:open_api_spex, "~> 3.16"},
      {:ash_phoenix, "~> 2.3"},
      {:ash_authentication, "~> 4.13"},
      {:ash_authentication_phoenix, "~> 2.15"},
      {:ash_admin, "~> 0.13.24"},
      {:bcrypt_elixir, "~> 3.0"},
      {:picosat_elixir, "~> 0.2.3"},
      {:earmark, "~> 1.4"},
      {:html_sanitize_ex, "~> 1.4"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:req, "~> 0.4"},
      {:extractous_ex, "~> 0.2.1"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "deps.compile", "picosat.sync", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["deps.compile", "picosat.sync", "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "spa.setup": ["cmd --cd ../frontend npm install"],
      "spa.build": ["cmd --cd ../frontend npm run build"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "spa.setup"
      ],
      "assets.build": [
        "compile",
        "tailwind intellectual_club",
        "esbuild intellectual_club",
        "spa.build"
      ],
      "assets.deploy": [
        "tailwind intellectual_club --minify",
        "esbuild intellectual_club --minify",
        "spa.build",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
