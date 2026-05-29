defmodule IntellectualClub.Generation.Supervisor do
  @moduledoc """
  Starts and manages per-message generation workers.
  """

  use DynamicSupervisor

  require Logger

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Worker

  @manual_retry_statuses [:error, :canceled]
  @retry_from_step_statuses [:done, :error, :canceled]
  @resume_retry_statuses [:generating]

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_generation(chat_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    :ok = Context.authorize_chat!(chat_id, actor)
    :ok = cancel_for_chat(chat_id)
    :ok = Persistence.cancel_orphaned_generating_messages!(chat_id)

    context = Context.build!(chat_id, opts)

    step_id = Persistence.ensure_step_started!(context.message_id, context.request_payload || %{})
    context = %{context | step_id: step_id}

    start_worker(context)
  end

  def retry_last_step(message_id, opts \\ []) when is_integer(message_id) and is_list(opts) do
    retry_opts = Keyword.put_new(opts, :allowed_statuses, @manual_retry_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, retry_opts),
         :ok <- cancel_for_chat(context.chat_id),
         :ok <- Persistence.cancel_orphaned_generating_messages!(context.chat_id),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence),
         :ok <- Persistence.rollback_steps_for_retry!(context.message_id, step_sequence) do
      step_id =
        Persistence.ensure_step_started!(
          context.message_id,
          step_sequence,
          context.request_payload || %{},
          []
        )

      context = %{context | step_id: step_id}
      start_worker(context)
    else
      nil ->
        {:error, :no_steps_to_retry}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :retry_failed}
    end
  end

  def retry_from_step(message_id, step_id, opts \\ [])
      when is_integer(message_id) and is_integer(step_id) and is_list(opts) do
    retry_opts =
      opts
      |> Keyword.put(:step_id, step_id)
      |> Keyword.put_new(:allowed_statuses, @retry_from_step_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, retry_opts),
         :ok <- cancel_for_chat(context.chat_id),
         :ok <- Persistence.cancel_orphaned_generating_messages!(context.chat_id),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence),
         :ok <- Persistence.rollback_steps_for_retry!(context.message_id, step_sequence) do
      step_id =
        Persistence.ensure_step_started!(
          context.message_id,
          step_sequence,
          context.request_payload || %{},
          []
        )

      context = %{context | step_id: step_id}
      start_worker(context)
    else
      nil ->
        {:error, :no_steps_to_retry}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :retry_failed}
    end
  end

  def resume_orphaned_message(message_id, opts \\ [])
      when is_integer(message_id) and is_list(opts) do
    resume_opts = Keyword.put_new(opts, :allowed_statuses, @resume_retry_statuses)

    with {:ok, context} <- Context.prepare_retry(message_id, resume_opts),
         step_sequence when is_integer(step_sequence) and step_sequence > 0 <-
           Map.get(context, :initial_step_sequence) do
      if waiting_tools_status?(context.initial_step_status) and is_integer(context.step_id) do
        start_worker(context)
      else
        :ok = Persistence.rollback_steps_for_retry!(context.message_id, step_sequence)

        step_id =
          Persistence.ensure_step_started!(
            context.message_id,
            step_sequence,
            context.request_payload || %{},
            []
          )

        context = %{context | step_id: step_id}
        start_worker(context)
      end
    else
      nil ->
        {:error, :no_steps_to_retry}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :retry_failed}
    end
  end

  defp waiting_tools_status?(status), do: status in [:waiting_tools, "waiting_tools"]

  def recover_orphaned_generations_async do
    Task.start(fn ->
      try do
        recover_orphaned_generations()
      rescue
        exception ->
          Logger.warning(
            "Failed to run orphaned generation recovery on startup: #{Exception.message(exception)}"
          )
      catch
        :exit, reason ->
          Logger.warning("Orphaned generation recovery exited on startup: #{inspect(reason)}")
      end
    end)

    :ok
  end

  def recover_orphaned_generations do
    Persistence.list_generating_messages_for_resume!()
    |> Enum.sort_by(&Map.get(&1, :id, 0))
    |> Enum.each(fn row ->
      message_id = Map.get(row, :id)
      owner_id = Map.get(row, :owner_id)

      if is_integer(message_id) and is_integer(owner_id) and owner_id > 0 do
        actor = %User{id: owner_id}

        case resume_orphaned_message(message_id, actor: actor) do
          {:ok, _context} ->
            Logger.info("Recovered orphaned generation message_id=#{message_id}")

          {:error, :already_running} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to recover orphaned generation message_id=#{message_id}: #{inspect(reason)}"
            )
        end
      end
    end)

    :ok
  end

  def cancel_generation(message_id) do
    case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
      [{pid, _}] -> Worker.cancel(pid)
      [] -> :not_found
    end
  end

  def cancel_for_chat(chat_id) do
    IntellectualClub.Generation.Registry
    |> Registry.lookup({:chat, chat_id})
    |> Enum.each(fn {pid, _} -> Worker.cancel(pid) end)

    :ok
  end

  def get_generation_state(message_id) do
    case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
      [{pid, _}] ->
        try do
          {:ok, Worker.get_current_state(pid)}
        catch
          :exit, _reason -> :not_found
        end

      [] ->
        :not_found
    end
  end

  def poll_generation(message_id, cursor \\ %{}, opts \\ []) when is_integer(message_id) do
    case Registry.lookup(IntellectualClub.Generation.Registry, {:message, message_id}) do
      [{pid, _}] ->
        try do
          {:ok, Worker.poll(pid, cursor, opts)}
        catch
          :exit, _reason -> :not_found
        end

      [] ->
        :not_found
    end
  end

  defp start_worker(context) when is_map(context) do
    spec = %{
      id: {Worker, context.message_id},
      start: {Worker, :start_link, [%{context: context}]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} ->
        {:ok, context}

      {:error, {:already_started, _pid}} ->
        {:error, :already_running}

      other ->
        other
    end
  end
end
