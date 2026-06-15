defmodule IntellectualClubWeb.Bff.ChatPayloads do
  @moduledoc """
  SPA payload builders for chat BFF route groups.
  """

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.Metrics, as: ChatMetrics
  alias IntellectualClub.Chat.Relations
  alias IntellectualClub.Chat.Revisions
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Chat.ListingStats
  alias IntellectualClub.Generation.Context, as: GenerationContext
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Tools.BindingResolver
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClubWeb.Bff.ChatBranchPayload
  alias IntellectualClubWeb.Bff.Loads
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  def state(%Chat{} = chat, actor) do
    chat = Ash.load!(chat, [:last_message], actor: actor)
    {messages, branch_meta_by_id} = load_branch(chat, actor)

    %{
      chat: Serializer.chat_detail(chat),
      branch: serialize_branch(messages, branch_meta_by_id, actor),
      relations: serialize_relations(Relations.relations(chat, messages, actor)),
      active_generation_message_id: active_generation_message_id(messages),
      idle_revision: Revisions.chat_revision(chat)
    }
  end

  def settings(%Chat{} = chat, actor) do
    chat_blocks = load_chat_blocks(chat.id, actor)
    chat_tool_bindings = load_chat_tool_bindings(chat.id, actor)
    tool_resolution = BindingResolver.resolve_for_chat(chat, actor)
    history = Threads.active_branch(chat, actor)

    prompt_context =
      prompt_context(chat, actor,
        history: history,
        tool_resolution: tool_resolution
      )

    bots = load_bots(actor)
    llm_configurations = load_llm_configurations(actor)
    knowledge_blocks = load_knowledge_blocks(actor)
    tool_instances = load_editable_tool_instances(actor)

    %{
      chat_blocks: Enum.map(chat_blocks, &Serializer.chat_block_binding/1),
      chat_tool_bindings: Enum.map(chat_tool_bindings, &Serializer.chat_tool_binding/1),
      prompt_sources: prompt_context.prompt_sources,
      prompt_blocks: prompt_context.prompt_blocks,
      compiled_prompt_text: prompt_context.compiled_prompt_text,
      counters: prompt_context.counters,
      active_tool_instances:
        Enum.map(tool_resolution.active_tool_instances, &Serializer.tool_instance_option/1),
      active_tool_bindings:
        Enum.map(tool_resolution.effective_tool_bindings, &Serializer.active_tool_binding/1),
      artifact_tools_available: tool_resolution.artifact_tools_available,
      missing_required_per_user_tool_aliases: tool_resolution.missing_aliases,
      options: %{
        no_bot_last_activity_at:
          Serializer.datetime_iso(ListingStats.no_bot_last_activity_at(actor)),
        bots: Enum.map(bots, &Serializer.bot_option/1),
        llm_configurations: Enum.map(llm_configurations, &Serializer.configuration_option/1),
        knowledge_blocks: Enum.map(knowledge_blocks, &Serializer.knowledge_block_option/1),
        tool_instances: Enum.map(tool_instances, &Serializer.tool_instance_option/1)
      }
    }
  end

  def prompt_context(%Chat{} = chat, actor, opts \\ []) do
    history =
      Keyword.get_lazy(opts, :history, fn ->
        Threads.active_branch(chat, actor)
      end)

    snapshot =
      GenerationContext.prompt_snapshot!(chat,
        actor: actor,
        tool_resolution:
          Keyword.get_lazy(opts, :tool_resolution, fn ->
            BindingResolver.resolve_for_chat(chat, actor)
          end)
      )

    %{
      prompt_sources: serialize_prompt_sources(snapshot.prompt_sources),
      prompt_blocks: serialize_prompt_blocks(snapshot.prompt_blocks),
      compiled_prompt_text: snapshot.system_prompt,
      counters:
        ChatMetrics.counters_from_history(chat, history, actor,
          prompt_sources: snapshot.prompt_sources
        )
    }
  end

  def load_branch(chat_or_id, actor) do
    {messages, branch_meta} =
      Threads.active_branch_with_meta(chat_or_id, actor, strict?: true)

    branch_meta_by_id = Map.new(branch_meta, fn node -> {node.id, node} end)
    {messages, branch_meta_by_id}
  end

  def serialize_branch(messages, branch_meta_by_id, actor) do
    ChatBranchPayload.branch(messages, branch_meta_by_id, actor)
  end

  def branch_payload(chat_or_id, actor) do
    {messages, branch_meta_by_id} = load_branch(chat_or_id, actor)
    serialize_branch(messages, branch_meta_by_id, actor)
  end

  def active_generation_message_id(messages) when is_list(messages) do
    Enum.find_value(messages, fn message ->
      if message.status in [:generating, "generating"], do: message.id, else: nil
    end)
  end

  def serialize_relations(%{} = relations) do
    %{
      parent: serialize_relation_entry(Map.get(relations, :parent)),
      children_by_message_id:
        relations
        |> Map.get(:children_by_message_id, %{})
        |> Map.new(fn {message_id, entries} ->
          {message_id, Enum.map(entries, &serialize_relation_entry/1)}
        end),
      children_without_message:
        relations
        |> Map.get(:children_without_message, [])
        |> Enum.map(&serialize_relation_entry/1)
    }
  end

  defp serialize_relation_entry(%{chat: %Chat{} = chat} = entry) do
    Serializer.chat_relation_summary(chat,
      kind: Map.get(entry, :kind),
      message_id: Map.get(entry, :message_id)
    )
  end

  defp serialize_relation_entry(_entry), do: nil

  defp load_chat_blocks(chat_id, actor) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.select([:id, :chat_id, :knowledge_block_id, :enabled, :sequence])
    |> Ash.Query.load(Loads.prompt_source_binding(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_chat_tool_bindings(chat_id, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load([tool_instance: [:name, :alias, :type, :outlet_online, :can_edit]],
      strict?: true
    )
    |> Ash.read!(actor: actor)
  end

  defp serialize_prompt_sources(prompt_sources) when is_map(prompt_sources) do
    %{
      bot: Enum.map(Map.get(prompt_sources, :bot, []), &prompt_binding/1),
      chat: Enum.map(Map.get(prompt_sources, :chat, []), &prompt_binding/1),
      configuration: Enum.map(Map.get(prompt_sources, :configuration, []), &prompt_binding/1),
      user: Enum.map(Map.get(prompt_sources, :user, []), &prompt_binding/1)
    }
  end

  defp prompt_binding(binding) do
    block = Map.get(binding, :knowledge_block)

    %{
      id: binding.id,
      enabled: binding.enabled,
      selection: binding_selection(binding),
      sequence: binding.sequence,
      knowledge_block: if(is_map(block), do: Serializer.knowledge_block_option(block), else: nil)
    }
  end

  defp serialize_prompt_blocks(prompt_blocks) when is_list(prompt_blocks) do
    Enum.map(prompt_blocks, &prompt_block/1)
  end

  defp serialize_prompt_blocks(_prompt_blocks), do: []

  defp prompt_block(%{} = entry) do
    block = Map.get(entry, :knowledge_block)

    %{
      id: Map.get(entry, :id),
      source: prompt_block_source(Map.get(entry, :source)),
      selection: prompt_block_selection(Map.get(entry, :selection)),
      sequence: Map.get(entry, :sequence),
      prompt_order: Map.get(entry, :prompt_order),
      knowledge_block: if(is_map(block), do: Serializer.knowledge_block_option(block), else: nil)
    }
  end

  defp prompt_block_source(:bot), do: "bot"
  defp prompt_block_source(:chat), do: "chat"
  defp prompt_block_source(:config), do: "config"
  defp prompt_block_source(:user), do: "user"
  defp prompt_block_source(source) when is_binary(source), do: source
  defp prompt_block_source(_source), do: nil

  defp prompt_block_selection(:top), do: "top"
  defp prompt_block_selection(:bottom), do: "bottom"
  defp prompt_block_selection(value) when is_binary(value), do: value
  defp prompt_block_selection(_value), do: nil

  defp binding_selection(binding) when is_map(binding) do
    case Map.get(binding, :selection) do
      :top -> :top
      "top" -> :top
      _ -> :bottom
    end
  end

  defp load_llm_configurations(actor) do
    LlmConfiguration
    |> Ash.Query.sort(model_name: :asc, updated_at: :desc)
    |> Ash.Query.select(Loads.llm_configuration_option_select())
    |> Ash.Query.load(Loads.llm_configuration_option_load(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_bots(actor) do
    Bot
    |> Ash.Query.sort(name: :asc, updated_at: :desc)
    |> Ash.Query.select(Loads.bot_option_select())
    |> Ash.Query.load(Loads.bot_option_load(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_knowledge_blocks(actor) do
    KnowledgeBlock
    |> Ash.Query.sort(name: :asc, updated_at: :desc)
    |> Ash.Query.select(Loads.knowledge_block_option_select())
    |> Ash.Query.load(Loads.knowledge_block_option_load(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_editable_tool_instances(%{id: actor_id} = actor) when is_integer(actor_id) do
    ToolInstance
    |> Ash.Query.filter(owner_id == ^actor_id)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.Query.load([:outlet_online, :can_edit], strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_editable_tool_instances(_actor), do: []
end
