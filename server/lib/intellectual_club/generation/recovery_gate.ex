defmodule IntellectualClub.Generation.RecoveryGate do
  @moduledoc """
  Durable admission control for generation recovery, not provider auto-retry.

  Only recovery admissions consume the budget. Failure registration is
  idempotent, and real durable progress resets the budget. Terminal intent is
  sticky until an explicit, transactionally committed manual retry.
  """

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageItem, ChatMessageStep}
  alias IntellectualClub.Generation.{Lease, PersistenceFailure, QueueCoordinator}
  alias IntellectualClub.Notifications.Dispatcher

  require Ash.Query
  require Logger

  @terminal_statuses [:done, :error, :canceled]
  @max_attempts 3
  @retry_delays_ms [250, 1_000, 5_000]
  @error_limit 1_000
  @exhausted_error "Generation recovery exhausted without durable progress"
  @message_fields [
    :id,
    :chat_id,
    :owner_id,
    :role,
    :status,
    :generation_recovery,
    :generation_fence_token
  ]

  @doc "Registers a persistence failure without consuming another recovery attempt."
  def record_failure(message_id, lease, actor, opts) do
    with {:ok, failure} <- failure_options(opts) do
      with_message(message_id, lease, actor, fn message ->
        if message.status in @terminal_statuses do
          {:ok, {:finished, message.status}}
        else
          recovery = recovery_state(message.generation_recovery)

          recovery =
            recovery ||
              %{
                "version" => 1,
                "progress" =>
                  if(is_nil(failure["terminal_status"]), do: progress_key(message.id, actor)),
                "attempts" => 0,
                "next_retry_at" => nil
              }

          # Keep the first terminal reason and intent, even if reconciliation
          # later fails differently or durable progress becomes visible.
          recovery =
            if terminal_intent(recovery) do
              recovery
            else
              Map.merge(recovery, failure)
            end

          if recovery != message.generation_recovery, do: put_recovery!(message, recovery, actor)
          {:ok, :recorded}
        end
      end)
    end
  end

  @doc """
  Admits one recovery before any context preparation or external work.

  `mode: :start` skips a fresh message without a guard. All existing guards
  obey the same budget and cooldown regardless of the entrypoint. The optional
  clock/policy arguments are validated and scoped to this call.
  """
  def admit(message_id, lease, actor, opts \\ []) do
    with {:ok, policy} <- policy(opts) do
      with_message(message_id, lease, actor, fn message ->
        cond do
          message.status in @terminal_statuses ->
            {:ok, {:finished, message.status}}

          is_nil(message.generation_recovery) and policy.mode == :start ->
            {:ok, :fresh}

          true ->
            admit_locked(message, actor, policy)
        end
      end)
    end
  end

  @doc "Finalizes terminal intent without reading or rewriting request/response payloads."
  def finish(message_id, lease, actor) do
    result =
      with_message(message_id, lease, actor, fn message ->
        cond do
          message.status in @terminal_statuses ->
            {:ok, message.status}

          status = terminal_intent(recovery_state(message.generation_recovery)) ->
            now = DateTime.utc_now()
            step = latest_step(message.id, actor, true)

            if step && step.status not in @terminal_statuses do
              step
              |> Ash.Changeset.for_update(:update, %{status: status, finished_at: now},
                actor: actor
              )
              |> Ash.update!(actor: actor)
            end

            message
            |> Ash.Changeset.for_update(
              :set_generation_state,
              %{
                status: status,
                error_detail: recovery_error(message.generation_recovery),
                finished_at: now,
                generation_fence_token: nil
              },
              actor: actor
            )
            |> Ash.update!(actor: actor)

            {:ok, status}

          true ->
            {:error, :recovery_terminal_intent_missing}
        end
      end)

    # Queue/notification bugs must never roll back the minimal terminal commit.
    # Each aftermath runs independently so one failure cannot suppress the rest.
    case result do
      {:ok, status} ->
        best_effort(message_id, :settle_queue, fn ->
          QueueCoordinator.settle_generation(message_id, status)
        end)

        best_effort(message_id, :cancel_background_tasks, fn ->
          BackgroundTasks.cancel_for_lifecycle_message_async(message_id)
        end)

        best_effort(message_id, :notify, fn ->
          Dispatcher.notify_generation_finished(message_id, status)
        end)

        result

      {:error, _reason} ->
        result
    end
  end

  @doc false
  def reset!(message_id, actor) do
    unless Ash.DataLayer.in_transaction?(ChatMessage) do
      raise ArgumentError, "Recovery reset requires the fenced manual retry transaction"
    end

    message = owned_message!(message_id, actor, true)
    if message.generation_recovery, do: put_recovery!(message, nil, actor)
    :ok
  end

  defp admit_locked(message, actor, policy) do
    recovery = recovery_state(message.generation_recovery)

    case terminal_intent(recovery) do
      status when status in [:error, :canceled] ->
        # Persist a fail-closed intent if an invalid guard was encountered.
        if recovery != message.generation_recovery, do: put_recovery!(message, recovery, actor)
        {:ok, {:finish, status}}

      nil ->
        progress = progress_key(message.id, actor)

        recovery =
          if recovery && recovery["progress"] == progress do
            recovery
          else
            %{"version" => 1, "progress" => progress, "attempts" => 0, "next_retry_at" => nil}
          end

        next_retry_at = retry_at(recovery)

        cond do
          next_retry_at && DateTime.compare(policy.now, next_retry_at) == :lt ->
            {:error, {:recovery_deferred, next_retry_at}}

          recovery["attempts"] >= policy.max_attempts ->
            put_recovery!(
              message,
              Map.merge(recovery, %{
                "terminal_status" => "error",
                "error" =>
                  String.slice(
                    @exhausted_error <> ": " <> recovery_error(recovery),
                    0,
                    @error_limit
                  )
              }),
              actor
            )

            {:ok, {:finish, :error}}

          true ->
            attempts = recovery["attempts"] + 1
            delay = Enum.at(policy.delays, min(attempts - 1, length(policy.delays) - 1))
            jitter = trunc(delay * policy.jitter_ratio)
            delay = delay + if(jitter > 0, do: :rand.uniform(jitter + 1) - 1, else: 0)
            next_retry_at = DateTime.add(policy.now, delay, :millisecond)

            put_recovery!(
              message,
              Map.merge(recovery, %{
                "attempts" => attempts,
                "next_retry_at" => DateTime.to_iso8601(next_retry_at)
              }),
              actor
            )

            {:ok, :admitted}
        end
    end
  end

  defp progress_key(message_id, actor) do
    progress =
      case latest_step(message_id, actor, false) do
        nil ->
          :no_steps

        step ->
          receipts =
            ChatMessageItem
            |> Ash.Query.filter(chat_message_step_id == ^step.id and type == :tool_result)
            |> Ash.Query.select([:sequence])
            |> Ash.Query.sort(sequence: :asc)
            |> Ash.read!(actor: actor)
            |> Enum.map(& &1.sequence)

          {step.sequence, step.status, step.response_final, length(receipts), receipts}
      end

    :crypto.hash(:sha256, :erlang.term_to_binary(progress)) |> Base.encode16(case: :lower)
  end

  defp latest_step(message_id, actor, lock?) do
    query =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^message_id)
      |> Ash.Query.select([:id, :sequence, :status, :response_final, :finished_at])
      |> Ash.Query.sort(sequence: :desc)
      |> Ash.Query.limit(1)

    query = if lock?, do: Ash.Query.lock(query, "FOR NO KEY UPDATE"), else: query
    Ash.read_one!(query, actor: actor)
  end

  # Authorize before leasing, then authorize again under chat -> message locks.
  # Read-only terminal returns do not need an active fence (completion clears it).
  defp with_message(message_id, lease, actor, fun) do
    PersistenceFailure.capture(
      fn ->
        do_with_message(message_id, lease, actor, fun)
      end,
      :recovery_gate
    )
  end

  defp do_with_message(message_id, lease, actor, fun) do
    with :ok <- matching_lease(message_id, lease),
         %ChatMessage{} = message <- owned_message!(message_id, actor, false) do
      cond do
        message.role != :assistant ->
          {:error, :invalid_role}

        message.status in @terminal_statuses ->
          fun.(message)

        is_nil(lease) ->
          PersistenceFailure.ash_transaction([Chat, ChatMessage, ChatMessageStep], fn ->
            Chat
            |> Ash.Query.filter(id == ^message.chat_id)
            |> Ash.Query.select([:id])
            |> Ash.Query.lock("FOR NO KEY UPDATE")
            |> Ash.read_one!(actor: actor)

            run_locked(message, actor, fun)
          end)
          |> unwrap_transaction()

        true ->
          Lease.with_chat_fence(lease, message.chat_id, fn ->
            run_locked(message, actor, fun)
          end)
          |> unwrap_transaction()
      end
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_locked(original, actor, fun) do
    message = owned_message!(original.id, actor, true)

    cond do
      message.chat_id != original.chat_id -> {:error, :message_chat_changed}
      message.role != :assistant -> {:error, :invalid_role}
      true -> fun.(message)
    end
  end

  defp owned_message!(message_id, %{id: owner_id} = actor, lock?)
       when is_integer(owner_id) and owner_id > 0 do
    query =
      ChatMessage
      |> Ash.Query.filter(id == ^message_id and owner_id == ^owner_id)
      |> Ash.Query.select(@message_fields)

    query = if lock?, do: Ash.Query.lock(query, "FOR NO KEY UPDATE"), else: query

    case Ash.read_one!(query, actor: actor) do
      %ChatMessage{} = message -> message
      nil -> raise Ash.Error.Query.NotFound, resource: ChatMessage, primary_key: message_id
    end
  end

  defp owned_message!(_message_id, _actor, _lock?) do
    raise Ash.Error.Forbidden, errors: []
  end

  defp matching_lease(_message_id, nil), do: :ok
  defp matching_lease(id, %Lease{message_id: id}), do: :ok
  defp matching_lease(_id, _lease), do: {:error, :invalid_generation_lease}

  defp put_recovery!(message, recovery, actor) do
    message
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_argument(:recovery, recovery)
    |> Ash.Changeset.for_update(:set_generation_recovery, %{}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp unwrap_transaction({:ok, result}), do: result
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp recovery_state(nil), do: nil

  # Terminal intent does not depend on readable progress/cooldown metadata.
  defp recovery_state(%{"terminal_status" => status} = recovery)
       when status in ["error", "canceled"],
       do: recovery

  defp recovery_state(%{"version" => 1, "attempts" => attempts} = recovery)
       when is_integer(attempts) and attempts >= 0 do
    valid_progress? = is_binary(recovery["progress"]) and byte_size(recovery["progress"]) == 64

    if recovery["terminal_status"] in [nil, "error", "canceled"] and
         valid_progress? and
         (is_nil(recovery["next_retry_at"]) or match?(%DateTime{}, retry_at(recovery))) do
      recovery
    else
      invalid_recovery()
    end
  end

  defp recovery_state(_other), do: invalid_recovery()

  defp invalid_recovery do
    %{
      "version" => 1,
      "attempts" => @max_attempts,
      "terminal_status" => "error",
      "error" => "Invalid durable generation recovery state"
    }
  end

  defp terminal_intent(%{"terminal_status" => "error"}), do: :error
  defp terminal_intent(%{"terminal_status" => "canceled"}), do: :canceled
  defp terminal_intent(_other), do: nil

  defp retry_at(%{"next_retry_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp retry_at(_other), do: nil

  defp recovery_error(recovery) do
    case recovery_state(recovery) do
      %{"error" => error} when is_binary(error) -> String.slice(error, 0, @error_limit)
      _other -> @exhausted_error
    end
  end

  defp failure_options(opts) when is_list(opts) do
    operation = Keyword.get(opts, :operation)
    error = Keyword.get(opts, :error)
    terminal_status = Keyword.get(opts, :terminal_status)

    if is_atom(operation) and not is_nil(operation) and is_binary(error) and
         String.valid?(error) and terminal_status in [nil, :error, :canceled] do
      {:ok,
       %{
         "operation" => operation |> Atom.to_string() |> String.slice(0, 100),
         "error" => String.slice(error, 0, @error_limit),
         "terminal_status" => if(terminal_status, do: Atom.to_string(terminal_status))
       }}
    else
      {:error, :invalid_recovery_failure}
    end
  end

  defp failure_options(_opts), do: {:error, :invalid_recovery_failure}

  defp policy(opts) when is_list(opts) do
    policy = %{
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      mode: Keyword.get(opts, :mode, :recovery),
      max_attempts: Keyword.get(opts, :max_attempts, @max_attempts),
      delays: Keyword.get(opts, :retry_delays_ms, @retry_delays_ms),
      jitter_ratio: Keyword.get(opts, :jitter_ratio, 0.2)
    }

    if match?(%DateTime{utc_offset: 0, std_offset: 0}, policy.now) and
         policy.mode in [:start, :recovery] and is_integer(policy.max_attempts) and
         policy.max_attempts in 1..10 and is_list(policy.delays) and policy.delays != [] and
         length(policy.delays) <= 10 and
         Enum.all?(policy.delays, &(is_integer(&1) and &1 in 1..60_000)) and
         is_number(policy.jitter_ratio) and policy.jitter_ratio >= 0 and policy.jitter_ratio <= 1 do
      {:ok, policy}
    else
      {:error, :invalid_recovery_policy}
    end
  end

  defp policy(_opts), do: {:error, :invalid_recovery_policy}

  defp best_effort(message_id, operation, fun) do
    case fun.() do
      {:error, reason} -> log_aftermath_failure(message_id, operation, reason)
      _other -> :ok
    end
  rescue
    exception -> log_aftermath_failure(message_id, operation, exception)
  catch
    kind, reason -> log_aftermath_failure(message_id, operation, {kind, reason})
  end

  defp log_aftermath_failure(message_id, operation, reason) do
    Logger.warning(
      "Recovery terminal aftermath failed message_id=#{message_id} " <>
        "operation=#{operation} reason=#{inspect(reason, limit: 5, printable_limit: 500)}"
    )
  end
end
