defmodule IntellectualClub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = load_application_modules()
    :ok = IntellectualClub.Generation.PersistenceFailure.attach_telemetry()

    children = [
      IntellectualClubWeb.Telemetry,
      IntellectualClub.Repo,
      {Ecto.Migrator, repos: [IntellectualClub.Repo], skip: skip_migrations?()},
      {IntellectualClub.Secrets.StartupMigrator, []},
      {IntellectualClub.Tools.WebSearch.StartupMigrator, []},
      {IntellectualClub.Llm.Providers.Responses.HttpPool, []},
      IntellectualClub.Llm.Auth.OpenAIOAuthCache,
      {IntellectualClub.Files.GarbageCollector, []},
      {Task.Supervisor, name: IntellectualClub.Generation.LeaseCleanupSupervisor},
      {IntellectualClub.Generation.Lease, []},
      {IntellectualClub.Chat.SubchatCostCache, []},
      {AshAuthentication.Supervisor, otp_app: :intellectual_club},
      {DNSCluster, query: Application.get_env(:intellectual_club, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IntellectualClub.PubSub},
      {Task.Supervisor, name: IntellectualClub.Outlets.BackgroundTaskSupervisor},
      {IntellectualClub.Outlets.Runtime, []},
      {IntellectualClub.Tools.RateLimiter, []},
      {Task.Supervisor, name: IntellectualClub.Tools.WebSearchTaskSupervisor},
      {IntellectualClub.Notifications.ActiveWebPushClients, []},
      {IntellectualClub.Notifications.Dispatcher, []},
      {Registry, keys: :unique, name: IntellectualClub.BackgroundTasks.ProcessRegistry},
      {Task.Supervisor, name: IntellectualClub.BackgroundTasks.ExecutionSupervisor},
      {IntellectualClub.BackgroundTasks.Supervisor, []},
      {IntellectualClub.BackgroundTasks.Reaper, []},
      {Registry, keys: :unique, name: IntellectualClub.Generation.Registry},
      {Task.Supervisor, name: IntellectualClub.Generation.PersistenceTasks},
      {IntellectualClubWeb.Bff.PollCache, []},
      {IntellectualClub.Generation.Supervisor, []},
      {IntellectualClub.Generation.Recovery, []},
      {IntellectualClub.Generation.QueueDispatcher, []},
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
        if Application.get_env(:intellectual_club, :recover_background_tasks_on_startup, true) do
          _ = IntellectualClub.BackgroundTasks.recover_async()
        end

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

  # Releases boot in interactive mode (rel/env.sh.eex) and load dependency code on
  # first use. Application modules are loaded up front instead, so runtime checks
  # such as function_exported?/3 and String.to_existing_atom/1 never depend on
  # whether a module happened to be called already. Loading is sequential on
  # purpose: the parallel loader leaves far more freed but unreturned native
  # memory behind.
  defp load_application_modules do
    {:ok, modules} = :application.get_key(:intellectual_club, :modules)
    Enum.each(modules, &Code.ensure_loaded!/1)
  end

  defp skip_migrations?() do
    # By default, migrations are run when using a release.
    System.get_env("RELEASE_NAME") == nil
  end
end
