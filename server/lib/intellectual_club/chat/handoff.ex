defmodule IntellectualClub.Chat.Handoff do
  @moduledoc """
  Creates explicit continuation chats from existing chat work.
  """

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Db
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Tools.ChatToolBinding

  require Ash.Query

  @relation_kind :handoff

  @summary_request """
  You are preparing a handoff summary so work can continue in a new chat.

  Summarize only the useful current state. Include:
  - the user's goal and current task,
  - completed work and decisions,
  - important constraints and assumptions,
  - files, commands, tools, APIs, or data that matter,
  - current status, blockers, and exact next steps.

  Write the summary as a clear continuation prompt for the next assistant.
  Do not answer the original user request directly. Do not mention that you are compacting context.

  Create the handoff summary now.
  """

  @spec manual_handoff(integer(), map()) :: {:ok, map()} | {:error, term()}
  def manual_handoff(source_chat_id, actor) when is_integer(source_chat_id) do
    with {:ok, %Chat{} = source} <- fetch_owned_chat(source_chat_id, actor),
         {:ok, handoff_prompt} <- handoff_prompt(source, actor),
         {:ok, prompt_message} <-
           Threads.add_message(source, :user, handoff_prompt,
             actor: actor,
             parent_id: source.last_message_id,
             status: :done
           ) do
      GenerationSupervisor.start_generation(source.id,
        actor: actor,
        parent_id: prompt_message.id,
        tools_payload_override: [],
        completion_effect: :manual_handoff
      )
    end
  end

  def manual_handoff(_source_chat_id, _actor), do: {:error, :invalid_chat_id}

  @spec create_handoff_chat(Chat.t() | integer(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_handoff_chat(source_chat_or_id, actor, summary, opts \\ [])

  def create_handoff_chat(source_chat_or_id, actor, summary, opts)
      when is_binary(summary) and is_list(opts) do
    with {:ok, %Chat{} = source} <- fetch_owned_chat(source_chat_or_id, actor),
         {:ok, summary} <- normalize_summary(summary) do
      start_generation? = Keyword.get(opts, :start_generation?, false) == true

      source_message_id =
        normalize_source_message_id(Keyword.get(opts, :source_message_id), source)

      case create_target_with_summary(source, actor, summary, source_message_id) do
        {:ok, %{chat: chat} = result} when start_generation? ->
          case GenerationSupervisor.start_generation(chat.id, actor: actor) do
            {:ok, context} ->
              {:ok, Map.put(result, :generation, context)}

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, result} ->
          {:ok, Map.put_new(result, :generation, nil)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def create_handoff_chat(_source_chat_or_id, _actor, _summary, _opts),
    do: {:error, :invalid_summary}

  @spec complete_manual_generation(integer(), map()) :: {:ok, map()} | {:error, term()}
  def complete_manual_generation(message_id, actor) when is_integer(message_id) do
    with {:ok, %ChatMessage{} = message} <- fetch_handoff_summary_message(message_id, actor),
         {:ok, summary} <- summary_from_message(message),
         %Chat{id: source_chat_id} when is_integer(source_chat_id) <- Map.get(message, :chat) do
      create_handoff_chat(source_chat_id, actor, summary,
        source_message_id: message.id,
        start_generation?: false
      )
    else
      nil -> {:error, :chat_not_loaded}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :chat_not_loaded}
    end
  end

  def complete_manual_generation(_message_id, _actor), do: {:error, :invalid_message_id}

  def relation_kind, do: @relation_kind
  def summary_request, do: @summary_request

  defp create_target_with_summary(source, actor, summary, source_message_id) do
    Db.repo().transaction(fn ->
      target = create_target_chat!(source, actor, source_message_id)
      copy_knowledge_block_bindings!(source.id, target.id, actor)
      copy_tool_bindings!(source.id, target.id, actor)

      {:ok, message} =
        Threads.add_message(target, :user, summary,
          actor: actor,
          parent_id: nil,
          status: :done
        )

      chat = Ash.get!(Chat, target.id, actor: actor, load: [:last_message])
      %{chat: chat, message: message}
    end)
    |> unwrap_transaction()
  end

  defp create_target_chat!(%Chat{} = source, actor, source_message_id) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        title: source.title,
        note: source.note,
        bot_id: source.bot_id,
        llm_configuration_id: source.llm_configuration_id,
        parent_chat_id: source.id,
        parent_message_id: source_message_id,
        parent_relation_kind: @relation_kind
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp copy_knowledge_block_bindings!(source_chat_id, target_chat_id, actor) do
    source_chat_id
    |> copy_knowledge_block_bindings(actor)
    |> Enum.each(fn attrs ->
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :chat_id, target_chat_id), actor: actor)
      |> Ash.create!(actor: actor)
    end)
  end

  defp copy_tool_bindings!(source_chat_id, target_chat_id, actor) do
    source_chat_id
    |> copy_tool_bindings(actor)
    |> Enum.each(fn attrs ->
      ChatToolBinding
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :chat_id, target_chat_id), actor: actor)
      |> Ash.create!(actor: actor)
    end)
  end

  defp copy_knowledge_block_bindings(chat_id, actor) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn binding ->
      %{
        knowledge_block_id: binding.knowledge_block_id,
        enabled: binding.enabled,
        sequence: binding.sequence
      }
    end)
  end

  defp copy_tool_bindings(chat_id, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn binding ->
      %{
        tool_instance_id: binding.tool_instance_id,
        enabled: binding.enabled,
        sequence: binding.sequence
      }
    end)
  end

  defp handoff_prompt(%Chat{} = source, actor) do
    case Ash.load(source, [bot: [:handoff_message_block]], actor: actor) do
      {:ok, %Chat{bot: %Bot{handoff_message_block: %KnowledgeBlock{content: content}}}} ->
        {:ok, to_string(content || "")}

      {:ok, %Chat{}} ->
        {:ok, @summary_request}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, :forbidden}

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_owned_chat(%Chat{owner_id: owner_id} = chat, %{id: actor_id})
       when is_integer(actor_id) and owner_id == actor_id do
    {:ok, chat}
  end

  defp fetch_owned_chat(%Chat{} = _chat, _actor), do: {:error, :forbidden}

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
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_owned_chat(_chat_id, _actor), do: {:error, :invalid_chat_id}

  defp fetch_handoff_summary_message(message_id, actor) when is_integer(message_id) do
    ChatMessage
    |> Ash.Query.filter(id == ^message_id and role == :assistant)
    |> Ash.Query.limit(1)
    |> Ash.Query.load([:chat, steps: [items: [:contents]]])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%ChatMessage{} = message]} -> {:ok, message}
      {:ok, []} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_summary(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> {:error, :empty_summary}
      text -> {:ok, text}
    end
  end

  defp normalize_source_message_id(message_id, _source) when is_integer(message_id),
    do: message_id

  defp normalize_source_message_id(_message_id, %Chat{last_message_id: id}), do: id
  defp normalize_source_message_id(_message_id, _source), do: nil

  defp summary_from_message(%ChatMessage{} = message) do
    message
    |> History.project_text_for_item_type(:answer)
    |> normalize_summary()
  end

  defp unwrap_transaction({:ok, %{chat: %Chat{}} = result}), do: {:ok, result}
  defp unwrap_transaction({:error, error}), do: {:error, error}
end
