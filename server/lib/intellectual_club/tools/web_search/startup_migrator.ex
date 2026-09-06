defmodule IntellectualClub.Tools.WebSearch.StartupMigrator do
  @moduledoc "Idempotent, owner-authorized migration of legacy Brave tool instances."
  use GenServer
  require Ash.Query
  require Logger
  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Secrets.{Secret, ToolInstanceSecret}
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClub.Tools.WebSearch.MigrationActor

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    if Application.get_env(:intellectual_club, :migrate_web_search_on_startup, true), do: run()
    {:ok, %{}}
  end

  def run do
    migrate_batch(0, %{migrated: 0, failed: 0})
  rescue
    _ ->
      Logger.error("Web search migration failed unexpectedly; will retry on next startup.")
      {:error, :migration_failed}
  catch
    :exit, _ -> {:error, :migration_failed}
  end

  def migrate(%ToolInstance{} = tool) do
    actor = %User{id: tool.owner_id}

    Ash.transaction([ToolInstance, Secret, ToolInstanceSecret], fn ->
      with {:ok, %ToolInstance{} = locked} <-
             ToolInstance
             |> Ash.Query.filter(id == ^tool.id)
             |> Ash.Query.lock(:for_update)
             |> Ash.read_one(actor: actor),
           {:ok, updated} <-
             locked
             |> Ash.Changeset.for_update(:migrate_brave_search, %{}, actor: actor)
             |> Ash.update(actor: actor) do
        updated
      else
        {:ok, nil} -> IntellectualClub.Repo.rollback(:tool_not_found)
        {:error, error} -> IntellectualClub.Repo.rollback(error)
      end
    end)
  rescue
    _ -> {:error, :migration_failed}
  catch
    :exit, _ -> {:error, :migration_failed}
  end

  defp migrate_batch(after_id, stats) do
    query =
      ToolInstance
      |> Ash.Query.for_read(:read_legacy_web_search, %{}, actor: %MigrationActor{})
      |> Ash.Query.filter(id > ^after_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(100)

    case Ash.read(query, actor: %MigrationActor{}) do
      {:ok, []} ->
        {:ok, stats}

      {:ok, tools} ->
        stats =
          Enum.reduce(tools, stats, fn tool, stats ->
            case migrate(tool) do
              {:ok, _} ->
                %{stats | migrated: stats.migrated + 1}

              {:error, _} ->
                Logger.error(
                  "Web search migration failed for tool_instance_id=#{tool.id}; will retry on next startup."
                )

                %{stats | failed: stats.failed + 1}
            end
          end)

        migrate_batch(List.last(tools).id, stats)

      {:error, _} ->
        Logger.error(
          "Could not enumerate legacy web search instances; will retry on next startup."
        )

        {:error, :migration_read_failed}
    end
  end
end
