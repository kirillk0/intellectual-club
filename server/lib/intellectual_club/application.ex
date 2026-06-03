defmodule IntellectualClub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    active_repo = Application.fetch_env!(:intellectual_club, :active_repo)

    children = [
      IntellectualClubWeb.Telemetry,
      active_repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:intellectual_club, :ecto_repos), skip: skip_migrations?()},
      {AshAuthentication.Supervisor, otp_app: :intellectual_club},
      {DNSCluster, query: Application.get_env(:intellectual_club, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IntellectualClub.PubSub},
      {IntellectualClub.Outlets.Runtime, []},
      {IntellectualClub.Tools.RateLimiter, []},
      {Registry, keys: :duplicate, name: IntellectualClub.Generation.Registry},
      {IntellectualClub.Generation.Supervisor, []},
      # Start a worker by calling: IntellectualClub.Worker.start_link(arg)
      # {IntellectualClub.Worker, arg},
      # Start to serve requests, typically the last entry
      IntellectualClubWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: IntellectualClub.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        if Application.get_env(:intellectual_club, :recover_orphaned_generations_on_startup, true) do
          _ = IntellectualClub.Generation.Supervisor.recover_orphaned_generations_async()
        end

        {:ok, pid}

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IntellectualClubWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, migrations are run when using a release.
    System.get_env("RELEASE_NAME") == nil
  end
end
