defmodule ImageCheck.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :image_check,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [],
      aliases: [precommit: ["compile --warnings-as-errors", "format --check-formatted", "test"]],
      start_permanent: Mix.env() == :prod
    ]

  def cli, do: [preferred_envs: [precommit: :test]]

  def application, do: [extra_applications: []]
end
