defmodule IntellectualClub.Generation.Lease do
  @moduledoc false

  use GenServer

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Repo

  require Ash.Query
  require Logger

  @generation_lock_offset -9_000_000_000_000_000_000
  @recovery_delays_ms [100, 1_000, 5_000]
  @default_recovery_interval_ms 30_000
  @default_validation_interval_ms 1_000
  @default_query_timeout_ms 5_000
  @owner_stop_grace_ms 1_000
  @validation_failure_limit 3

  defstruct [:manager, :message_id, :ref, :fence_token]

  defmodule State do
    @moduledoc false
    defstruct [:connection, leases: %{}, validation_failures: 0]
  end

  @type t :: %__MODULE__{
          manager: pid(),
          message_id: pos_integer(),
          ref: reference(),
          fence_token: Ecto.UUID.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec acquire(pos_integer(), pid()) :: {:ok, t()} | {:error, term()}
  def acquire(message_id, owner \\ self())

  def acquire(message_id, owner)
      when is_integer(message_id) and message_id > 0 and is_pid(owner) do
    case reserve(message_id, owner) do
      {:ok, %__MODULE__{} = lease} ->
        case fence(lease) do
          {:ok, fenced} -> {:ok, fenced}
          {:error, reason} -> release_after_fence_error(lease, reason)
        end

      {:error, _reason} = error ->
        error
    end
  catch
    :exit, reason -> {:error, {:generation_lease_unavailable, reason}}
  end

  def acquire(_message_id, _owner), do: {:error, :invalid_generation_lease}

  @doc false
  @spec reserve(pos_integer(), pid()) :: {:ok, t()} | {:error, term()}
  def reserve(message_id, owner \\ self())

  def reserve(message_id, owner)
      when is_integer(message_id) and message_id > 0 and is_pid(owner) do
    GenServer.call(__MODULE__, {:acquire, message_id, owner}, :infinity)
  catch
    :exit, reason -> {:error, {:generation_lease_unavailable, reason}}
  end

  def reserve(_message_id, _owner), do: {:error, :invalid_generation_lease}

  @doc false
  @spec fence(t()) :: {:ok, t()} | {:error, term()}
  def fence(%__MODULE__{fence_token: nil} = lease) do
    case claim_and_run(lease, [:generating], fn -> :ok end) do
      {:ok, {fenced, :ok}} -> {:ok, fenced}
      {:error, _reason} = error -> error
    end
  end

  def fence(%__MODULE__{} = lease), do: {:ok, lease}

  @doc false
  @spec claim_and_run(t(), [atom()], (-> result)) ::
          {:ok, {t(), result}} | {:error, term()}
        when result: term()
  def claim_and_run(
        %__MODULE__{fence_token: nil} = lease,
        allowed_statuses,
        fun
      )
      when is_list(allowed_statuses) and allowed_statuses != [] and is_function(fun, 0) do
    if active?(lease) do
      token = Ecto.UUID.generate()

      case lease_transaction(fn ->
             with {:ok, current} <- lock_message(lease.message_id) do
               if current.role == :assistant and current.status in allowed_statuses do
                 current
                 |> Ash.Changeset.for_update(
                   :set_generation_fence,
                   %{generation_fence_token: token},
                   authorize?: false
                 )
                 |> Ash.update!(authorize?: false)

                 {:ok, {%{lease | fence_token: token}, fun.()}}
               else
                 {:error, :invalid_status}
               end
             end
           end) do
        {:ok, {%__MODULE__{} = fenced, result}} ->
          case register_fence(fenced) do
            :ok -> {:ok, {fenced, result}}
            {:error, _reason} = error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :lease_lost}
    end
  end

  @doc false
  @spec claim_and_run_with_chat(t(), pos_integer(), [atom()], (-> result)) ::
          {:ok, {t(), result}} | {:error, term()}
        when result: term()
  def claim_and_run_with_chat(
        %__MODULE__{fence_token: nil} = lease,
        chat_id,
        allowed_statuses,
        fun
      )
      when is_integer(chat_id) and chat_id > 0 and is_list(allowed_statuses) and
             allowed_statuses != [] and is_function(fun, 0) do
    if active?(lease) do
      token = Ecto.UUID.generate()

      case lease_transaction(
             [Chat, ChatMessage],
             fn ->
               with {:ok, _chat} <- lock_chat(chat_id),
                    {:ok, current} <- lock_message(lease.message_id) do
                 active_generation = lock_other_generating_message(chat_id, lease.message_id)

                 cond do
                   current.chat_id != chat_id ->
                     {:error, :chat_mismatch}

                   current.role != :assistant or current.status not in allowed_statuses ->
                     {:error, :invalid_status}

                   match?(%ChatMessage{}, active_generation) ->
                     {:error, :generation_active}

                   true ->
                     current
                     |> Ash.Changeset.for_update(
                       :set_generation_fence,
                       %{generation_fence_token: token},
                       authorize?: false
                     )
                     |> Ash.update!(authorize?: false)

                     {:ok, {%{lease | fence_token: token}, fun.()}}
                 end
               end
             end,
             []
           ) do
        {:ok, {%__MODULE__{} = fenced, result}} ->
          case register_fence(fenced) do
            :ok -> {:ok, {fenced, result}}
            {:error, _reason} = error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :lease_lost}
    end
  end

  def claim_and_run_with_chat(_lease, _chat_id, _allowed_statuses, _fun),
    do: {:error, :invalid_generation_lease}

  @spec transfer(t(), pid()) :: :ok | {:error, term()}
  def transfer(%__MODULE__{} = lease, new_owner) when is_pid(new_owner) do
    GenServer.call(lease.manager, {:transfer, lease, self(), new_owner}, :infinity)
  catch
    :exit, reason -> {:error, {:generation_lease_unavailable, reason}}
  end

  @doc false
  @spec adopt(t(), pid()) :: :ok | {:error, term()}
  def adopt(%__MODULE__{} = lease, previous_owner) when is_pid(previous_owner) do
    GenServer.call(lease.manager, {:transfer, lease, previous_owner, self()}, :infinity)
  catch
    :exit, reason -> {:error, {:generation_lease_unavailable, reason}}
  end

  @spec release(t()) :: :ok | {:error, term()}
  def release(%__MODULE__{} = lease) do
    GenServer.call(lease.manager, {:release, lease, self()}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @spec with_fence(t(), (-> result), keyword()) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_fence(lease, fun, opts \\ [])

  def with_fence(%__MODULE__{fence_token: nil}, _fun, _opts) do
    {:error, :lease_not_fenced}
  end

  def with_fence(%__MODULE__{} = lease, fun, opts)
      when is_function(fun, 0) and is_list(opts) do
    if active?(lease) do
      case lease_transaction(fn ->
             with {:ok, current} <- lock_message(lease.message_id) do
               cond do
                 current.generation_fence_token != lease.fence_token ->
                   {:error, :lease_lost}

                 Keyword.get(opts, :require_generating?, false) and
                     current.status != :generating ->
                   {:error, :invalid_status}

                 true ->
                   {:ok, fun.()}
               end
             end
           end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :lease_lost}
    end
  end

  @doc false
  @spec with_chat_fence(t(), pos_integer(), (-> result), keyword()) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_chat_fence(lease, chat_id, fun, opts \\ [])

  def with_chat_fence(%__MODULE__{fence_token: nil}, _chat_id, _fun, _opts) do
    {:error, :lease_not_fenced}
  end

  def with_chat_fence(%__MODULE__{} = lease, chat_id, fun, opts)
      when is_integer(chat_id) and chat_id > 0 and is_function(fun, 0) and is_list(opts) do
    allowed_statuses = Keyword.get(opts, :allowed_statuses)
    required_role = Keyword.get(opts, :required_role)

    if active?(lease) do
      case lease_transaction(
             [Chat, ChatMessage],
             fn ->
               with {:ok, _chat} <- lock_chat(chat_id),
                    {:ok, current} <- lock_message(lease.message_id) do
                 cond do
                   current.chat_id != chat_id ->
                     {:error, :chat_mismatch}

                   current.generation_fence_token != lease.fence_token ->
                     {:error, :lease_lost}

                   is_list(allowed_statuses) and current.status not in allowed_statuses ->
                     {:error, :invalid_status}

                   not is_nil(required_role) and current.role != required_role ->
                     {:error, :invalid_role}

                   true ->
                     {:ok, fun.()}
                 end
               end
             end,
             []
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :lease_lost}
    end
  end

  def with_chat_fence(_lease, _chat_id, _fun, _opts),
    do: {:error, :invalid_generation_fence}

  @doc false
  @spec with_token_fence(pos_integer(), Ecto.UUID.t(), (-> result), keyword()) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_token_fence(message_id, fence_token, fun, opts \\ [])

  def with_token_fence(message_id, fence_token, fun, opts)
      when is_integer(message_id) and message_id > 0 and is_binary(fence_token) and
             is_function(fun, 0) and is_list(opts) do
    allowed_statuses = Keyword.get(opts, :allowed_statuses)
    required_role = Keyword.get(opts, :required_role)

    case lease_transaction(fn ->
           with {:ok, current} <- lock_message(message_id) do
             cond do
               current.generation_fence_token != fence_token ->
                 {:error, :lease_lost}

               is_list(allowed_statuses) and current.status not in allowed_statuses ->
                 {:error, :invalid_status}

               not is_nil(required_role) and current.role != required_role ->
                 {:error, :invalid_role}

               true ->
                 {:ok, fun.()}
             end
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def with_token_fence(_message_id, _fence_token, _fun, _opts),
    do: {:error, :invalid_generation_fence}

  @doc false
  @spec with_token_chat_fence(
          pos_integer(),
          pos_integer(),
          Ecto.UUID.t(),
          (-> result),
          keyword()
        ) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_token_chat_fence(message_id, chat_id, fence_token, fun, opts \\ [])

  def with_token_chat_fence(message_id, chat_id, fence_token, fun, opts)
      when is_integer(message_id) and message_id > 0 and is_integer(chat_id) and chat_id > 0 and
             is_binary(fence_token) and is_function(fun, 0) and is_list(opts) do
    allowed_statuses = Keyword.get(opts, :allowed_statuses)
    required_role = Keyword.get(opts, :required_role)

    case lease_transaction(
           [Chat, ChatMessage],
           fn ->
             with {:ok, _chat} <- lock_chat(chat_id),
                  {:ok, current} <- lock_message(message_id) do
               cond do
                 current.chat_id != chat_id ->
                   {:error, :chat_mismatch}

                 current.generation_fence_token != fence_token ->
                   {:error, :lease_lost}

                 is_list(allowed_statuses) and current.status not in allowed_statuses ->
                   {:error, :invalid_status}

                 not is_nil(required_role) and current.role != required_role ->
                   {:error, :invalid_role}

                 true ->
                   {:ok, fun.()}
               end
             end
           end,
           []
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def with_token_chat_fence(_message_id, _chat_id, _fence_token, _fun, _opts),
    do: {:error, :invalid_generation_fence}

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = lease) do
    match?(
      {:ok, :ok},
      with_fence(lease, fn -> :ok end, require_generating?: true)
    )
  end

  @doc false
  @spec lock_key(pos_integer()) :: integer()
  def lock_key(message_id) when is_integer(message_id) and message_id > 0 do
    @generation_lock_offset + message_id
  end

  @doc false
  def connection_pid do
    GenServer.call(__MODULE__, :connection_pid)
  end

  @doc false
  def trigger_validation do
    send(__MODULE__, :validate_generation_leases_now)
    :ok
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case Postgrex.start_link(connection_options()) do
      {:ok, connection} ->
        schedule_restart_recovery()
        schedule_periodic_recovery()
        schedule_lease_validation()
        {:ok, %State{connection: connection}}

      {:error, reason} ->
        {:stop, {:generation_lease_connection_failed, reason}}
    end
  end

  @impl true
  def handle_call(
        {:acquire, message_id, owner},
        _from,
        %State{connection: connection, leases: leases} = state
      ) do
    if Map.has_key?(leases, message_id) do
      {:reply, {:error, :already_running}, state}
    else
      case Postgrex.query(
             connection,
             "SELECT pg_try_advisory_lock($1)",
             [lock_key(message_id)],
             timeout: query_timeout_ms()
           ) do
        {:ok, %{rows: [[true]]}} ->
          ref = make_ref()
          Process.link(owner)

          lease = %__MODULE__{manager: self(), message_id: message_id, ref: ref}
          entry = %{ref: ref, owner: owner, fence_token: nil}

          {:reply, {:ok, lease}, %{state | leases: Map.put(leases, message_id, entry)}}

        {:ok, %{rows: [[false]]}} ->
          {:reply, {:error, :already_running}, state}

        {:error, reason} ->
          {:stop, {:generation_lease_query_failed, reason}, {:error, reason}, state}
      end
    end
  end

  def handle_call(:connection_pid, _from, %State{connection: connection} = state) do
    {:reply, connection, state}
  end

  def handle_call(
        {:transfer, %__MODULE__{} = lease, current_owner, new_owner},
        _from,
        %State{leases: leases} = state
      ) do
    case Map.get(leases, lease.message_id) do
      %{ref: ref, owner: ^current_owner} when ref == lease.ref ->
        Process.link(new_owner)

        leases =
          Map.put(leases, lease.message_id, %{
            ref: lease.ref,
            owner: new_owner,
            fence_token: lease.fence_token
          })

        maybe_unlink_owner(current_owner, leases)

        {:reply, :ok, %{state | leases: leases}}

      _other ->
        {:reply, {:error, :generation_lease_not_owned}, state}
    end
  end

  def handle_call(
        {:register_fence, %__MODULE__{} = lease, owner},
        _from,
        %State{leases: leases} = state
      ) do
    case Map.get(leases, lease.message_id) do
      %{ref: ref, owner: ^owner} = entry when ref == lease.ref ->
        leases =
          Map.put(leases, lease.message_id, %{entry | fence_token: lease.fence_token})

        {:reply, :ok, %{state | leases: leases}}

      _other ->
        {:reply, {:error, :generation_lease_not_owned}, state}
    end
  end

  def handle_call(
        {:release, %__MODULE__{} = lease, owner},
        _from,
        %State{} = state
      ) do
    case Map.get(state.leases, lease.message_id) do
      %{ref: ref, owner: ^owner} when ref == lease.ref ->
        case unlock(state, lease.message_id, owner) do
          {:ok, state} ->
            {:reply, :ok, state}

          {:error, reason} ->
            {:stop, {:generation_lease_unlock_failed, reason}, {:error, reason}, state}
        end

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call(
        {:active?, %__MODULE__{} = lease},
        _from,
        %State{leases: leases} = state
      ) do
    active? =
      match?(%{ref: ref} when ref == lease.ref, Map.get(leases, lease.message_id))

    {:reply, active?, state}
  end

  @impl true
  def handle_info({:EXIT, connection, reason}, %State{connection: connection} = state) do
    {:stop, {:generation_lease_connection_down, reason}, state}
  end

  def handle_info({:EXIT, owner, _reason}, %State{} = state) when is_pid(owner) do
    case release_owner_leases(state, owner) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, {:generation_lease_unlock_failed, reason}, state}
    end
  end

  def handle_info(:recover_orphaned_generations, %State{} = state) do
    run_orphaned_generation_recovery()

    {:noreply, state}
  end

  def handle_info(:recover_orphaned_generations_periodic, %State{} = state) do
    run_orphaned_generation_recovery()
    schedule_periodic_recovery()

    {:noreply, state}
  end

  def handle_info(:validate_generation_leases, %State{} = state) do
    case validate_generation_leases(state) do
      {:ok, state} ->
        schedule_lease_validation()
        {:noreply, state}

      {:stop, reason, state} ->
        {:stop, reason, state}
    end
  end

  def handle_info(:validate_generation_leases_now, %State{} = state) do
    case validate_generation_leases(state) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_info(
        {:force_stop_generation_owner, message_id, ref, owner},
        %State{leases: leases} = state
      ) do
    case Map.get(leases, message_id) do
      %{ref: ^ref, owner: ^owner} -> Process.exit(owner, :kill)
      _other -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{connection: connection}) when is_pid(connection) do
    if Process.alive?(connection), do: Process.exit(connection, :kill)
    :ok
  end

  defp release_owner_leases(%State{} = state, owner) do
    state.leases
    |> Enum.filter(fn {_message_id, entry} -> entry.owner == owner end)
    |> Enum.reduce_while({:ok, state}, fn {message_id, _entry}, {:ok, acc} ->
      case unlock(acc, message_id, owner) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp unlock(%State{connection: connection, leases: leases} = state, message_id, owner) do
    fence_token =
      case Map.get(leases, message_id) do
        %{fence_token: token} -> token
        _other -> nil
      end

    with :ok <- clear_generation_fence(message_id, fence_token),
         {:ok, %{rows: [[true]]}} <-
           Postgrex.query(
             connection,
             "SELECT pg_advisory_unlock($1)",
             [lock_key(message_id)],
             timeout: query_timeout_ms()
           ) do
      leases = Map.delete(leases, message_id)
      maybe_unlink_owner(owner, leases)
      {:ok, %{state | leases: leases}}
    else
      failure -> {:error, failure}
    end
  end

  defp clear_generation_fence(_message_id, nil), do: :ok

  defp clear_generation_fence(message_id, fence_token) when is_binary(fence_token) do
    case lease_transaction(
           fn ->
             with {:ok, current} <- lock_message(message_id) do
               if current.generation_fence_token == fence_token do
                 current
                 |> Ash.Changeset.for_update(
                   :set_generation_fence,
                   %{generation_fence_token: nil},
                   authorize?: false
                 )
                 |> Ash.update!(authorize?: false)
               end

               {:ok, :ok}
             end
           end,
           timeout: query_timeout_ms()
         ) do
      {:ok, :ok} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:generation_fence_clear_failed, reason}}
    end
  end

  defp connection_options do
    Repo.config()
    |> Keyword.drop([:name, :log, :pool, :pool_size])
    |> Keyword.put(:sync_connect, true)
    |> Keyword.put(:backoff_type, :stop)
    |> Keyword.put(:max_restarts, 0)
  end

  defp lock_message(message_id) do
    message =
      ChatMessage
      |> Ash.Query.filter(id == ^message_id)
      |> Ash.Query.select([:id, :chat_id, :role, :status, :generation_fence_token])
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(authorize?: false)

    case message do
      %ChatMessage{} = message -> {:ok, message}
      nil -> {:error, :not_found}
    end
  end

  defp lock_other_generating_message(chat_id, excluded_message_id) do
    ChatMessage
    |> Ash.Query.filter(
      chat_id == ^chat_id and id != ^excluded_message_id and status == :generating
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp lock_chat(chat_id) do
    chat =
      Chat
      |> Ash.Query.filter(id == ^chat_id)
      |> Ash.Query.select([:id])
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(authorize?: false)

    case chat do
      %Chat{} = chat -> {:ok, chat}
      nil -> {:error, :not_found}
    end
  end

  defp lease_transaction(fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    lease_transaction(ChatMessage, fun, opts)
  end

  defp lease_transaction(resources, fun, opts)
       when is_function(fun, 0) and is_list(opts) do
    case Ash.transaction(resources, fun, opts) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_unlink_owner(owner, leases) do
    unless Enum.any?(leases, fn {_message_id, entry} -> entry.owner == owner end) do
      Process.unlink(owner)
    end
  end

  defp active?(%__MODULE__{} = lease) do
    GenServer.call(lease.manager, {:active?, lease}, :infinity)
  catch
    :exit, _reason -> false
  end

  defp schedule_restart_recovery do
    if Process.whereis(IntellectualClub.Generation.Supervisor) do
      Enum.each(@recovery_delays_ms, fn delay_ms ->
        Process.send_after(self(), :recover_orphaned_generations, delay_ms)
      end)
    end
  end

  defp schedule_periodic_recovery do
    if orphaned_generation_recovery_enabled?() do
      interval_ms =
        case Application.get_env(
               :intellectual_club,
               :generation_orphan_recovery_interval_ms
             ) do
          value when is_integer(value) and value > 0 -> value
          _other -> @default_recovery_interval_ms
        end

      Process.send_after(self(), :recover_orphaned_generations_periodic, interval_ms)
    end
  end

  defp run_orphaned_generation_recovery do
    if orphaned_generation_recovery_enabled?() and
         Process.whereis(IntellectualClub.Generation.Supervisor) do
      _ = IntellectualClub.Generation.Supervisor.recover_orphaned_generations_async()
    end
  end

  defp orphaned_generation_recovery_enabled? do
    Application.get_env(
      :intellectual_club,
      :recover_orphaned_generations_on_startup,
      true
    )
  end

  defp schedule_lease_validation do
    interval_ms =
      case Application.get_env(:intellectual_club, :generation_lease_validation_interval_ms) do
        value when is_integer(value) and value > 0 -> value
        _other -> @default_validation_interval_ms
      end

    Process.send_after(self(), :validate_generation_leases, interval_ms)
  end

  defp query_timeout_ms do
    case Application.get_env(:intellectual_club, :generation_lease_query_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_query_timeout_ms
    end
  end

  defp validate_generation_leases(%State{} = state) do
    fenced_entries =
      Enum.filter(state.leases, fn {_message_id, entry} ->
        is_binary(Map.get(entry, :fence_token))
      end)

    if fenced_entries == [] do
      {:ok, %{state | validation_failures: 0}}
    else
      messages_by_id =
        fenced_entries
        |> Enum.map(fn {message_id, _entry} -> message_id end)
        |> load_fenced_messages()

      fenced_entries
      |> Enum.filter(fn {message_id, entry} ->
        case Map.get(messages_by_id, message_id) do
          %ChatMessage{role: role, status: status, generation_fence_token: token} ->
            role != :assistant or status not in [:generating, :done, :error] or
              token != entry.fence_token

          nil ->
            true
        end
      end)
      |> stop_lease_owners()

      {:ok, %{state | validation_failures: 0}}
    end
  rescue
    exception ->
      handle_validation_failure(state, Exception.message(exception))
  catch
    kind, reason ->
      handle_validation_failure(state, inspect({kind, reason}))
  end

  defp load_fenced_messages(message_ids) when is_list(message_ids) do
    ChatMessage
    |> Ash.Query.filter(id in ^message_ids)
    |> Ash.Query.select([:id, :role, :status, :generation_fence_token])
    |> Ash.read!(authorize?: false, timeout: query_timeout_ms())
    |> Map.new(&{&1.id, &1})
  end

  defp handle_validation_failure(%State{} = state, reason) do
    failures = state.validation_failures + 1

    Logger.warning(
      "Generation lease validation failed attempt=#{failures}/#{@validation_failure_limit} " <>
        "reason=#{reason}"
    )

    if failures >= @validation_failure_limit do
      reason = {:generation_lease_validation_failed, reason}
      {:stop, reason, %{state | validation_failures: failures}}
    else
      {:ok, %{state | validation_failures: failures}}
    end
  end

  defp stop_lease_owners(entries) when is_list(entries) do
    Enum.each(entries, fn
      {message_id, %{owner: owner, ref: ref}} when is_pid(owner) ->
        GenServer.cast(owner, :generation_fence_lost)

        Process.send_after(
          self(),
          {:force_stop_generation_owner, message_id, ref, owner},
          @owner_stop_grace_ms
        )

      _other ->
        :ok
    end)
  end

  defp release_after_fence_error(lease, reason) do
    _ = release(lease)
    {:error, reason}
  end

  defp register_fence(%__MODULE__{} = lease) do
    GenServer.call(lease.manager, {:register_fence, lease, self()}, :infinity)
  catch
    :exit, reason -> {:error, {:generation_lease_unavailable, reason}}
  end
end
