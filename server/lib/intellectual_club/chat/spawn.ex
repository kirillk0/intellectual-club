defmodule IntellectualClub.Chat.Spawn do
  @moduledoc """
  Creates empty-context subagent chats from persisted tool calls.

  Preparation is committed before provider work starts so both synchronous and
  background invocations can recover the same chat and generation after a crash.
  """

  @behaviour IntellectualClub.BackgroundTasks.Adapter

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatSettingsCopy
  alias IntellectualClub.Chat.Subagent
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context, as: GenerationContext
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Repo
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @relation_kind :spawn
  @parent_tool_call_unique_constraint "chats_unique_parent_tool_call_item_id_index"

  def relation_kind, do: @relation_kind

  @spec create_and_run(
          ToolInstance.t(),
          String.t(),
          String.t(),
          ExecutionContext.t(),
          User.t()
        ) :: {:ok, ExecutionResult.t()} | {:error, term()}
  def create_and_run(
        %ToolInstance{} = tool_instance,
        brief,
        prompt,
        %ExecutionContext{} = context,
        %User{} = actor
      )
      when is_binary(brief) and is_binary(prompt) do
    with {:ok, reference} <- start_or_resume(tool_instance, brief, prompt, context, actor),
         {:ok, snapshot} <- Subagent.await_snapshot(reference, actor),
         result = Subagent.sync_execution_result_from_snapshot(snapshot, actor),
         :ok <- Subagent.persist_parent_tool_result(context, result) do
      {:ok, result}
    end
  end

  def create_and_run(_tool_instance, _brief, _prompt, _context, _actor),
    do: {:error, :invalid_spawn_context}

  @spec start_or_resume(
          ToolInstance.t(),
          String.t(),
          String.t(),
          ExecutionContext.t(),
          User.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def start_or_resume(tool_instance, brief, prompt, context, actor, opts \\ [])

  def start_or_resume(
        %ToolInstance{} = tool_instance,
        brief,
        prompt,
        %ExecutionContext{} = context,
        %User{} = actor,
        opts
      )
      when is_binary(brief) and is_binary(prompt) and is_list(opts) do
    brief = String.trim(brief)
    prompt = String.trim(prompt)

    with :ok <- validate_text(brief, "brief"),
         :ok <- validate_text(prompt, "prompt"),
         :ok <- validate_context(context),
         {:ok, source} <- fetch_owned_chat(context.chat_id, actor),
         {:ok, prepared} <-
           find_or_prepare(tool_instance, source, brief, prompt, context, actor, opts),
         {:ok, reference} <- start_prepared(prepared, context, actor, opts) do
      {:ok, reference}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def start_or_resume(_tool_instance, _brief, _prompt, _context, _actor, _opts),
    do: {:error, :invalid_spawn_context}

  @doc false
  @impl true
  def execute_background(
        task_record,
        %ToolInstance{} = tool_instance,
        "spawn",
        args,
        %ExecutionContext{} = context
      )
      when is_map(args) do
    brief = args |> Map.get("brief", "") |> to_string() |> String.trim()
    prompt = args |> Map.get("prompt", "") |> to_string() |> String.trim()

    with :ok <- validate_text(brief, "brief"),
         :ok <- validate_text(prompt, "prompt"),
         task_id when is_binary(task_id) <- task_record_value(task_record, :id),
         %User{} = actor <- actor_from_context(context),
         {:ok, reference} <-
           start_or_resume(tool_instance, brief, prompt, context, actor,
             background_task_authority: task_record,
             on_reference: &set_background_reference(task_record, &1)
           ) do
      Subagent.await_background_snapshot(reference, actor)
    else
      nil -> {:error, "Background task context is invalid."}
      {:error, _reason} = error -> error
      _other -> {:error, "Background task context is invalid."}
    end
  end

  def execute_background(_task_record, _tool_instance, _function_name, _args, _context) do
    {:error, "Invalid background spawn execution context."}
  end

  @doc false
  @impl true
  def snapshot_background(task_record, cursor) do
    case background_reference(task_record) do
      {:ok, reference, actor} ->
        if background_execution_owns_recovery?(task_record, reference) do
          :default
        else
          Subagent.snapshot(reference, actor, cursor)
        end

      {:error, :target_not_ready} ->
        :default

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @impl true
  def recover_background(_task_record), do: :restart

  @doc false
  @impl true
  def cancel_background(task_record) do
    case background_reference(task_record) do
      {:ok, reference, actor} ->
        cancel_reference_generation(reference, actor)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp find_or_prepare(tool_instance, source, brief, prompt, context, actor, opts) do
    case fetch_spawn_chat_by_tool_call_item_id(context.tool_call_item_id, actor) do
      %Chat{} = chat ->
        load_existing_prepared(chat, actor)

      nil ->
        prepare_new(tool_instance, source, brief, prompt, context, actor, opts)
    end
  end

  defp prepare_new(
         %ToolInstance{} = tool_instance,
         %Chat{} = source,
         brief,
         prompt,
         context,
         actor,
         opts
       ) do
    transaction_result =
      Subagent.with_invocation_authority(context, opts, fn ->
        Repo.transaction(fn ->
          case Subagent.ensure_creation_allowed(tool_instance, source, actor) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          attrs = %{
            note: brief,
            bot_id: source.bot_id,
            llm_configuration_id: source.llm_configuration_id,
            parent_chat_id: source.id,
            parent_message_id: context.assistant_message_id || context.message_id,
            parent_tool_call_item_id: context.tool_call_item_id,
            parent_relation_kind: @relation_kind,
            subagent: true
          }

          chat =
            case Chat
                 |> Ash.Changeset.for_create(:create, attrs, actor: actor)
                 |> Ash.create(actor: actor) do
              {:ok, %Chat{} = chat} -> chat
              {:error, error} -> Repo.rollback(error)
            end

          :ok = ChatSettingsCopy.copy_bindings!(source.id, chat.id, actor)

          {:ok, prompt_message} =
            Threads.add_message_to_end(chat, :user, prompt,
              actor: actor,
              llm_configuration_id: source.llm_configuration_id
            )

          generation_context =
            GenerationContext.build!(chat.id,
              actor: actor,
              parent_id: prompt_message.id
            )

          %{
            state: :new,
            chat: Ash.get!(Chat, chat.id, actor: actor, load: [:last_message]),
            prompt_message_id: prompt_message.id,
            generation_message_id: generation_context.message_id,
            generation_context: generation_context
          }
        end)
      end)

    case transaction_result do
      {:ok, prepared} ->
        {:ok, prepared}

      {:error, error} ->
        if parent_tool_call_unique_constraint_error?(error) do
          case fetch_spawn_chat_by_tool_call_item_id(context.tool_call_item_id, actor) do
            %Chat{} = chat -> load_existing_prepared(chat, actor)
            nil -> {:error, error}
          end
        else
          {:error, error}
        end
    end
  end

  defp load_existing_prepared(%Chat{} = chat, actor) do
    with %ChatMessage{} = generation_message <- first_generation_message(chat.id, actor),
         {:ok, %ChatMessage{role: :user} = prompt_message} <-
           Ash.get(ChatMessage, generation_message.parent_id, actor: actor) do
      {:ok,
       %{
         state: :existing,
         chat: chat,
         prompt_message_id: prompt_message.id,
         generation_message_id: generation_message.id
       }}
    else
      nil -> {:error, "Existing spawn subagent has no prepared generation."}
    end
  end

  defp start_prepared(prepared, parent_context, actor, opts) do
    reference = reference(prepared)

    Subagent.start_invocation(
      parent_context,
      reference,
      opts,
      &cancel_reference_generation(&1, actor),
      fn ->
        case start_or_resume_generation(prepared, actor) do
          :ok -> {:ok, reference}
          {:error, _reason} = error -> error
        end
      end
    )
  end

  defp start_or_resume_generation(%{state: :new, generation_context: context}, actor) do
    case GenerationSupervisor.start_prepared_generation(
           context.chat_id,
           context.message_id,
           context.step_id,
           context.request_payload || %{},
           actor: actor,
           available_file_external_ids: context.available_file_external_ids || []
         ) do
      {:ok, _context} -> :ok
      {:error, :already_running} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp start_or_resume_generation(%{generation_message_id: message_id}, actor) do
    Subagent.resume_generation_if_needed(message_id, actor)
  end

  defp reference(prepared) do
    %{
      primitive: :spawn,
      chat_id: prepared.chat.id,
      prompt_message_id: prepared.prompt_message_id,
      message_id: prepared.generation_message_id,
      generation_message_id: prepared.generation_message_id,
      url: "/chats/#{prepared.chat.id}"
    }
  end

  defp fetch_spawn_chat_by_tool_call_item_id(tool_call_item_id, actor)
       when is_integer(tool_call_item_id) do
    Chat
    |> Ash.Query.filter(
      parent_tool_call_item_id == ^tool_call_item_id and parent_relation_kind == ^@relation_kind
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.load([:last_message])
    |> Ash.read!(actor: actor)
    |> List.first()
  end

  defp fetch_spawn_chat_by_tool_call_item_id(_tool_call_item_id, _actor), do: nil

  defp first_generation_message(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id and role == :assistant and not is_nil(parent_id))
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.find(fn message ->
      case Ash.get(ChatMessage, message.parent_id, actor: actor) do
        {:ok, %ChatMessage{role: :user}} -> true
        _other -> false
      end
    end)
  end

  defp validate_context(%ExecutionContext{} = context) do
    cond do
      not is_integer(context.chat_id) ->
        {:error, "chat_id is required"}

      not is_integer(context.assistant_message_id || context.message_id) ->
        {:error, "assistant_message_id is required"}

      not is_integer(context.step_id) ->
        {:error, "step_id is required"}

      not is_integer(context.tool_call_item_id) ->
        {:error, "tool_call_item_id is required"}

      true ->
        :ok
    end
  end

  defp validate_text(value, field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "#{field} is required"}, else: :ok
  end

  defp fetch_owned_chat(chat_id, %{id: actor_id} = actor)
       when is_integer(chat_id) and is_integer(actor_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id and owner_id == ^actor_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load([:last_message])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> {:ok, chat}
      {:ok, []} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_owned_chat(_chat_id, _actor), do: {:error, :invalid_chat_id}

  defp parent_tool_call_unique_constraint_error?(%{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &parent_tool_call_unique_constraint_error?/1)
  end

  defp parent_tool_call_unique_constraint_error?(%{private_vars: vars}) when is_list(vars) do
    Keyword.get(vars, :constraint) == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(%{private_vars: vars}) when is_map(vars) do
    Map.get(vars, :constraint) == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(%{postgres: %{constraint: constraint}}) do
    constraint == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(%{constraint: constraint}) do
    constraint == @parent_tool_call_unique_constraint
  end

  defp parent_tool_call_unique_constraint_error?(%{error: error}) do
    parent_tool_call_unique_constraint_error?(error)
  end

  defp parent_tool_call_unique_constraint_error?(%{reason: reason}) do
    parent_tool_call_unique_constraint_error?(reason)
  end

  defp parent_tool_call_unique_constraint_error?(%RuntimeError{message: message})
       when is_binary(message) do
    String.contains?(message, @parent_tool_call_unique_constraint)
  end

  defp parent_tool_call_unique_constraint_error?(_error), do: false

  defp set_background_reference(task_record, reference) when is_map(reference) do
    case IntellectualClub.BackgroundTasks.set_subagent_reference(task_record, reference) do
      :ok -> :ok
      {:ok, _task} -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_background_reference_result, other}}
    end
  end

  defp background_reference(task_record) do
    owner_id = task_record_value(task_record, :owner_id)
    chat_id = task_record_value(task_record, :target_chat_id)
    runner_ref = task_record_value(task_record, :runner_ref) || %{}

    cond do
      not is_integer(owner_id) or owner_id <= 0 ->
        {:error, :invalid_owner}

      true ->
        actor = %User{id: owner_id}

        case stored_background_reference(chat_id, runner_ref, actor) do
          {:ok, reference} ->
            {:ok, reference, actor}

          {:error, _reason} ->
            fallback_background_reference(task_record, actor)
        end
    end
  end

  defp stored_background_reference(chat_id, runner_ref, actor)
       when is_integer(chat_id) and chat_id > 0 and is_map(runner_ref) do
    prompt_message_id = Map.get(runner_ref, "spawn_prompt_message_id")

    message_id =
      Map.get(runner_ref, "spawn_message_id") ||
        Map.get(runner_ref, "spawn_generation_message_id")

    generation_message_id =
      Map.get(runner_ref, "spawn_generation_message_id") || message_id

    with {:ok, %Chat{} = chat} <- fetch_owned_chat(chat_id, actor),
         true <- is_integer(prompt_message_id) and prompt_message_id > 0,
         true <- is_integer(message_id) and message_id > 0,
         true <- is_integer(generation_message_id) and generation_message_id > 0 do
      {:ok,
       %{
         primitive: :spawn,
         chat_id: chat.id,
         prompt_message_id: prompt_message_id,
         message_id: message_id,
         generation_message_id: generation_message_id,
         url: Map.get(runner_ref, "spawn_url") || "/chats/#{chat.id}"
       }}
    else
      false -> {:error, :target_not_ready}
      {:error, _reason} = error -> error
    end
  end

  defp stored_background_reference(_chat_id, _runner_ref, _actor),
    do: {:error, :target_not_ready}

  defp fallback_background_reference(task_record, actor) do
    source_tool_call_item_id = task_record_value(task_record, :source_tool_call_item_id)

    with tool_call_item_id when is_integer(tool_call_item_id) and tool_call_item_id > 0 <-
           source_tool_call_item_id,
         %Chat{} = chat <- fetch_spawn_chat_by_tool_call_item_id(tool_call_item_id, actor),
         {:ok, prepared} <- load_existing_prepared(chat, actor) do
      {:ok, reference(prepared), actor}
    else
      _other -> {:error, :target_not_ready}
    end
  end

  defp background_execution_owns_recovery?(task_record, reference) do
    task_id = task_record_value(task_record, :id)
    generation_message_id = Map.get(reference, :generation_message_id)

    is_binary(task_id) and IntellectualClub.BackgroundTasks.worker_active?(task_id) and
      is_integer(generation_message_id) and
      GenerationSupervisor.get_generation_state(generation_message_id) == :not_found
  end

  defp cancel_reference_generation(reference, actor) when is_map(reference) do
    Subagent.cancel_reference_generation(reference, actor)
  end

  defp task_record_value(%BackgroundTask{} = task_record, key) when is_atom(key) do
    case Map.get(task_record, key) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end

  defp task_record_value(_task_record, _key), do: nil

  defp actor_from_context(%ExecutionContext{owner_id: owner_id})
       when is_integer(owner_id) and owner_id > 0 do
    %User{id: owner_id}
  end

  defp actor_from_context(_context), do: nil
end
