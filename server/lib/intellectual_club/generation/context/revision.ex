defmodule IntellectualClub.Generation.Context.Revision do
  @moduledoc """
  Authorized, payload-free revision reads for ordinary generation preparations.

  Membership is part of the revision: inserts/deletes matter as much as updates.
  Every mutable input includes its update timestamp. History reads never select
  raw requests, responses, content text or opaque JSON. File identities are read
  only after their IDs have been obtained from authorized content/bindings.

  Linked/related chats and drivers with external prompt dependencies deliberately
  use Context's protected fallback, not an incomplete optimistic revision.
  """

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.{Bot, BotKnowledgeBlock}

  alias IntellectualClub.Chat.{
    Chat,
    ChatKnowledgeBlock,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep
  }

  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Knowledge.{KnowledgeBlock, KnowledgeBlockFile}
  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationKnowledgeBlock, LlmProvider}
  alias IntellectualClub.Secrets.{KnowledgeBlockSecret, Secret, ToolInstanceSecret}

  alias IntellectualClub.Tools.{
    BotToolBinding,
    BotUserToolBinding,
    ChatToolBinding,
    ToolFunction,
    ToolInstance
  }

  require Ash.Query

  @static_tool_types ~w(mcp-http mcp_http native-agent-management native-artifact-reader
    native-brave-search native-web-search native-game-tools native-web-reader ssh)

  @doc "Returns an opaque revision or an explicit unsupported-snapshot reason."
  def capture(chat_id, %{id: actor_id} = actor, opts) when is_integer(actor_id) do
    chat = Ash.get!(Chat, chat_id, actor: actor, authorize?: true)

    cond do
      Map.get(actor, :id) != chat.owner_id ->
        {:error, :forbidden}

      not is_nil(chat.parent_chat_id) or not is_nil(chat.fork_source_step_id) or
          not is_nil(chat.fork_task) ->
        {:fallback, :related_chat}

      true ->
        capture_owned(chat, actor, opts)
    end
  end

  def capture(_chat_id, _actor, _opts), do: {:error, :forbidden}

  defp capture_owned(chat, actor, opts) do
    parent_id = parent_id(chat, opts)
    messages = related(ChatMessage, :chat_id, [chat.id], actor, [:parent_id])
    branch = branch!(messages, parent_id)
    steps = related(ChatMessageStep, :chat_message_id, ids(branch), actor)
    items = related(ChatMessageItem, :chat_message_step_id, ids(steps), actor)
    contents = related(ChatMessageContent, :chat_message_item_id, ids(items), actor, [:file_id])

    configurations = records(LlmConfiguration, [chat.llm_configuration_id], actor, [:provider_id])
    providers = records(LlmProvider, values(configurations, :provider_id), actor)
    bots = records(Bot, [chat.bot_id], actor)

    prompt_bindings = %{
      bot: related(BotKnowledgeBlock, :bot_id, [chat.bot_id], actor, [:knowledge_block_id]),
      chat: related(ChatKnowledgeBlock, :chat_id, [chat.id], actor, [:knowledge_block_id]),
      configuration:
        related(
          LlmConfigurationKnowledgeBlock,
          :llm_configuration_id,
          [chat.llm_configuration_id],
          actor,
          [:knowledge_block_id]
        ),
      user: related(UserKnowledgeBlock, :owner_id, [actor.id], actor, [:knowledge_block_id])
    }

    block_ids = prompt_bindings |> Map.values() |> List.flatten() |> values(:knowledge_block_id)
    blocks = records(KnowledgeBlock, block_ids, actor)
    block_files = related(KnowledgeBlockFile, :knowledge_block_id, block_ids, actor, [:file_id])

    block_secrets =
      related(KnowledgeBlockSecret, :knowledge_block_id, block_ids, actor, [:secret_id])

    tool_bindings = %{
      bot: related(BotToolBinding, :bot_id, [chat.bot_id], actor, [:tool_instance_id]),
      user: related(BotUserToolBinding, :bot_id, [chat.bot_id], actor, [:tool_instance_id]),
      chat: related(ChatToolBinding, :chat_id, [chat.id], actor, [:tool_instance_id])
    }

    tool_ids = tool_bindings |> Map.values() |> List.flatten() |> values(:tool_instance_id)
    tools = records(ToolInstance, tool_ids, actor, [:type])

    if Enum.all?(tools, &(&1.type in @static_tool_types)) do
      functions = related(ToolFunction, :tool_instance_id, tool_ids, actor)
      tool_secrets = related(ToolInstanceSecret, :tool_instance_id, tool_ids, actor, [:secret_id])
      secret_ids = values(block_secrets ++ tool_secrets, :secret_id)
      secrets = records(Secret, secret_ids, actor)
      file_ids = values(contents ++ block_files, :file_id)

      files =
        if file_ids == [] do
          []
        else
          StoredFile
          |> Ash.Query.filter(id in ^file_ids)
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.select([:id, :external_id, :sha256, :mime_type, :size_bytes, :filename])
          |> Ash.read!(actor: actor, authorize?: true)
          |> Enum.map(
            &Map.take(&1, [:id, :external_id, :sha256, :mime_type, :size_bytes, :filename])
          )
        end

      inputs = %{
        chat:
          Map.take(chat, [
            :id,
            :owner_id,
            :bot_id,
            :llm_configuration_id,
            :last_message_id,
            :parent_chat_id,
            :fork_source_step_id,
            :fork_task,
            :updated_at
          ]),
        parent_id: parent_id,
        intent:
          Keyword.take(opts, [
            :pending_user_contents,
            :tools_payload_override,
            :completion_effect,
            :chunk_delay_ms
          ]),
        branch: branch,
        steps: steps,
        items: items,
        contents: contents,
        configurations: configurations,
        providers: providers,
        bots: bots,
        prompt_bindings: prompt_bindings,
        blocks: blocks,
        block_files: block_files,
        block_secrets: block_secrets,
        tool_bindings: tool_bindings,
        tools: tools,
        functions: functions,
        tool_secrets: tool_secrets,
        secrets: secrets,
        files: files
      }

      {:ok,
       %{parent_id: parent_id, digest: :crypto.hash(:sha256, :erlang.term_to_binary(inputs))}}
    else
      {:fallback, :dynamic_tool_context}
    end
  end

  defp parent_id(chat, opts) do
    case Keyword.fetch(opts, :parent_id) do
      {:ok, id} when is_integer(id) or is_nil(id) -> id
      _other -> chat.last_message_id
    end
  end

  defp records(resource, ids, actor, extra \\ []),
    do: related(resource, :id, ids, actor, extra)

  defp related(resource, key, ids, actor, extra \\ []) do
    ids = ids |> Enum.filter(&is_integer/1) |> Enum.uniq()
    fields = Enum.uniq([:id, :updated_at | extra])
    filter = [{key, [in: ids]}]

    if ids == [] do
      []
    else
      resource
      |> Ash.Query.filter(^filter)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.select(fields)
      |> Ash.read!(actor: actor, authorize?: true)
      |> Enum.map(&Map.take(&1, fields))
    end
  end

  defp branch!(messages, parent_id) do
    by_id = Map.new(messages, &{&1.id, &1})
    walk_branch!(by_id, parent_id, MapSet.new(), [])
  end

  defp walk_branch!(_by_id, nil, _visited, branch), do: branch

  defp walk_branch!(by_id, id, visited, branch) do
    if MapSet.member?(visited, id), do: raise(ArgumentError, "Cyclic chat history")

    case Map.get(by_id, id) do
      nil ->
        raise ArgumentError, "Parent message not found in chat"

      message ->
        walk_branch!(by_id, message.parent_id, MapSet.put(visited, id), [message | branch])
    end
  end

  defp ids(records), do: values(records, :id)

  defp values(records, key),
    do: records |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
end
