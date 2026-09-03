defmodule IntellectualClub.Secrets.StartupMigrator do
  @moduledoc """
  Runs idempotent managed-secret maintenance after database migrations.

  It moves legacy tool-driver secret maps into managed secret bindings and
  re-encrypts managed secrets with the current key. Individual row failures are
  logged and retained for a later startup instead of preventing the instance
  from booting.
  """

  use GenServer

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Repo
  alias IntellectualClub.Secrets.{Crypto, DriverSecrets, Secret}
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query
  require Logger

  @batch_size 200

  @type stats :: %{
          backfill_failed: non_neg_integer(),
          backfilled: non_neg_integer(),
          rekey_failed: non_neg_integer(),
          rekeyed: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run() :: {:ok, stats()} | {:error, term()}
  def run do
    with {:ok, backfill_stats} <- backfill_driver_secrets(),
         {:ok, rekey_stats} <- rekey_managed_secrets() do
      {:ok, Map.merge(backfill_stats, rekey_stats)}
    end
  end

  @impl true
  def init(_opts) do
    stats =
      if Application.get_env(
           :intellectual_club,
           :migrate_managed_secrets_on_startup,
           true
         ) do
        :ok = Crypto.validate_keyring!()
        run_safely()
      else
        %{backfilled: 0, backfill_failed: 0, rekeyed: 0, rekey_failed: 0}
      end

    {:ok, stats}
  end

  defp run_safely do
    case run() do
      {:ok, stats} ->
        if Enum.any?(stats, fn {_key, count} -> count > 0 end) do
          Logger.info(
            "Managed secret startup maintenance completed: " <>
              "backfilled=#{stats.backfilled} " <>
              "backfill_failed=#{stats.backfill_failed} " <>
              "rekeyed=#{stats.rekeyed} rekey_failed=#{stats.rekey_failed}"
          )
        end

        stats

      {:error, error} ->
        Logger.error("Managed secret startup maintenance failed: #{format_error(error)}")
        %{backfilled: 0, backfill_failed: 1, rekeyed: 0, rekey_failed: 1}
    end
  rescue
    exception ->
      Logger.error(
        "Managed secret startup maintenance crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      %{backfilled: 0, backfill_failed: 1, rekeyed: 0, rekey_failed: 1}
  catch
    kind, reason ->
      Logger.error(
        "Managed secret startup maintenance exited: #{Exception.format(kind, reason, __STACKTRACE__)}"
      )

      %{backfilled: 0, backfill_failed: 1, rekeyed: 0, rekey_failed: 1}
  end

  defp backfill_driver_secrets do
    backfill_driver_secret_batch(0, %{backfilled: 0, backfill_failed: 0})
  end

  defp backfill_driver_secret_batch(after_id, stats) do
    result =
      ToolInstance
      |> Ash.Query.filter(id > ^after_id and secrets != ^%{})
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(@batch_size)
      |> Ash.read(authorize?: false)

    case result do
      {:ok, []} ->
        {:ok, stats}

      {:ok, tools} ->
        next_stats = Enum.reduce(tools, stats, &backfill_tool/2)
        backfill_driver_secret_batch(List.last(tools).id, next_stats)

      {:error, error} ->
        {:error, error}
    end
  end

  defp backfill_tool(tool, stats) do
    actor = %User{id: tool.owner_id}

    case DriverSecrets.migrate_legacy(tool, actor) do
      {:ok, _tool} ->
        %{stats | backfilled: stats.backfilled + 1}

      {:error, error} ->
        Logger.error(
          "Legacy driver secret backfill failed for tool_instance_id=#{tool.id}: " <>
            format_error(error)
        )

        %{stats | backfill_failed: stats.backfill_failed + 1}
    end
  end

  defp rekey_managed_secrets do
    rekey_managed_secret_batch(0, %{rekeyed: 0, rekey_failed: 0})
  end

  defp rekey_managed_secret_batch(after_id, stats) do
    result =
      Secret
      |> Ash.Query.filter(id > ^after_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(@batch_size)
      |> Ash.read(authorize?: false)

    case result do
      {:ok, []} ->
        {:ok, stats}

      {:ok, secrets} ->
        next_stats = Enum.reduce(secrets, stats, &rekey_secret_for_stats/2)
        rekey_managed_secret_batch(List.last(secrets).id, next_stats)

      {:error, error} ->
        {:error, error}
    end
  end

  defp rekey_secret_for_stats(secret, stats) do
    if Crypto.current_ciphertext?(secret.encrypted_value) do
      stats
    else
      do_rekey_secret_for_stats(secret, stats)
    end
  end

  defp do_rekey_secret_for_stats(secret, stats) do
    case rekey_secret(secret.id) do
      {:ok, :unchanged} ->
        stats

      {:ok, :rekeyed} ->
        %{stats | rekeyed: stats.rekeyed + 1}

      {:error, :invalid_ciphertext} ->
        Logger.error(
          "Managed secret rekey failed for secret_id=#{secret.id}: ciphertext is invalid " <>
            "or its encryption key is unavailable"
        )

        %{stats | rekey_failed: stats.rekey_failed + 1}

      {:error, error} ->
        Logger.error(
          "Managed secret rekey failed for secret_id=#{secret.id}: " <>
            format_error(error)
        )

        %{stats | rekey_failed: stats.rekey_failed + 1}
    end
  end

  defp rekey_secret(secret_id) do
    case Ash.transaction(Secret, fn ->
           Secret
           |> Ash.Query.filter(id == ^secret_id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(authorize?: false)
           |> case do
             {:ok, nil} ->
               :unchanged

             {:ok, %Secret{} = locked} ->
               rekey_locked_secret(locked)

             {:error, error} ->
               Repo.rollback(error)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :invalid_ciphertext} -> {:error, :invalid_ciphertext}
      {:error, error} -> {:error, error}
    end
  end

  defp rekey_locked_secret(%Secret{} = secret) do
    case Crypto.reencrypt_if_needed(secret.encrypted_value) do
      {:ok, _ciphertext, false} ->
        :unchanged

      {:ok, ciphertext, true} ->
        actor = %User{id: secret.owner_id}

        secret
        |> Ash.Changeset.for_update(
          :replace_encrypted,
          %{encrypted_value: ciphertext},
          actor: actor
        )
        |> Ash.update(actor: actor)
        |> case do
          {:ok, _secret} -> :rekeyed
          {:error, error} -> Repo.rollback(error)
        end

      {:error, :invalid_ciphertext} ->
        Repo.rollback(:invalid_ciphertext)
    end
  end

  defp format_error(error) do
    Exception.message(error)
  rescue
    _exception -> inspect(error)
  end
end
