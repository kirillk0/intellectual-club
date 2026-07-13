defmodule IntellectualClubWeb.Bff.Serializer do
  @moduledoc """
  JSON serializers for the BFF API.

  Keep payloads small and stable for the SPA client.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Accounts.UserGroup
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.StepMetrics
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Tools.{DriverMetadata, ToolInstance}

  @tool_result_preview_char_limit 600
  @tool_result_preview_line_limit 5

  def datetime_iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def datetime_iso(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  def datetime_iso(nil), do: nil
  def datetime_iso(_value), do: nil

  def user(%User{} = user) do
    %{
      id: user.id,
      username: user.username,
      is_admin: user.is_admin,
      preferred_locale: user.preferred_locale,
      preferred_theme: user.preferred_theme || "system"
    }
  end

  def user_group_summary(%UserGroup{} = group) do
    %{
      id: group.id,
      name: group.name
    }
  end

  def bot_option(%Bot{} = bot) do
    %{
      id: bot.id,
      name: bot.name,
      image: loaded_value(Map.get(bot, :image)),
      default_llm_configuration_id: bot.default_llm_configuration_id,
      compatible_configuration_tag_ids: loaded_ids(Map.get(bot, :compatible_configuration_tags)),
      compatible_configuration_tag_names:
        loaded_names(Map.get(bot, :compatible_configuration_tags)),
      context_soft_limit_percent: bot.context_soft_limit_percent,
      max_file_size_bytes: bot.max_file_size_bytes,
      can_edit: loaded_value(Map.get(bot, :can_edit)),
      shared_incoming: loaded_value(Map.get(bot, :shared_incoming)),
      shared_outgoing: loaded_value(Map.get(bot, :shared_outgoing)),
      created_at: datetime_iso(bot.created_at),
      updated_at: datetime_iso(bot.updated_at),
      sort_activity_at: datetime_iso(Map.get(bot, :sort_activity_at))
    }
  end

  def configuration_option(%LlmConfiguration{} = configuration) do
    %{
      id: configuration.id,
      label: configuration_display_label(configuration),
      enabled: configuration.enabled,
      tag_ids: loaded_ids(Map.get(configuration, :tags)),
      tag_names: loaded_names(Map.get(configuration, :tags)),
      context_length: configuration.context_length,
      supports_image_input: configuration.supports_image_input,
      supports_steering: configuration.supports_steering,
      can_edit: loaded_value(Map.get(configuration, :can_edit)),
      shared_incoming: loaded_value(Map.get(configuration, :shared_incoming)),
      shared_outgoing: loaded_value(Map.get(configuration, :shared_outgoing))
    }
  end

  def knowledge_block_option(%KnowledgeBlock{} = block) do
    %{
      id: block.id,
      name: block.name,
      image: loaded_value(Map.get(block, :image)),
      version: block.version,
      token_count: block.token_count,
      can_edit: loaded_value(Map.get(block, :can_edit)),
      shared_incoming: loaded_value(Map.get(block, :shared_incoming)),
      shared_outgoing: loaded_value(Map.get(block, :shared_outgoing))
    }
  end

  def chat_summary(%Chat{} = chat, opts \\ []) do
    %{
      id: chat.id,
      note: chat.note,
      bot_id: chat.bot_id,
      bot_name: chat_bot_name(chat),
      llm_configuration_id: chat.llm_configuration_id,
      llm_configuration_label: chat_llm_configuration_label(chat),
      active_generation_message_id: active_generation_message_id(chat),
      parent_chat_id: chat.parent_chat_id,
      parent_message_id: chat.parent_message_id,
      parent_relation_kind: relation_kind_string(chat.parent_relation_kind),
      subagent: chat.subagent == true,
      child_handoff_count: Keyword.get(opts, :child_handoff_count, 0),
      child_subchat_count: Keyword.get(opts, :child_subchat_count, 0),
      subchats: Keyword.get(opts, :subchats, []),
      blocks_count: loaded_count(Map.get(chat, :blocks_count)),
      tools_count: loaded_count(Map.get(chat, :tools_count)),
      can_edit: loaded_value(Map.get(chat, :can_edit)),
      shared_incoming: loaded_value(Map.get(chat, :shared_incoming)),
      shared_outgoing: loaded_value(Map.get(chat, :shared_outgoing)),
      created_at: datetime_iso(chat.created_at),
      updated_at: datetime_iso(chat.updated_at),
      last_activity_at: datetime_iso(Keyword.get(opts, :activity_at))
    }
  end

  def chat_list_stats(%{
        total_chat_count: total,
        no_bot_chat_count: no_bot_count,
        no_bot_last_activity_at: no_bot_last_activity_at,
        bot_stats: stats
      }) do
    %{
      total_chats: total,
      no_bot_chat_count: no_bot_count,
      no_bot_last_activity_at: datetime_iso(no_bot_last_activity_at),
      bots: Enum.map(stats || [], &chat_list_bot_stat/1)
    }
  end

  def chat_list_bot_stat(%{bot_id: bot_id, bot_name: bot_name, count: count}) do
    %{
      bot_id: bot_id,
      bot_name: bot_name,
      chat_count: count
    }
  end

  defp loaded_count(%Ash.NotLoaded{}), do: 0
  defp loaded_count(value) when is_integer(value) and value >= 0, do: value
  defp loaded_count(_value), do: 0

  def chat_detail(%Chat{} = chat) do
    %{
      id: chat.id,
      note: chat.note,
      bot_id: chat.bot_id,
      llm_configuration_id: chat.llm_configuration_id,
      parent_chat_id: chat.parent_chat_id,
      parent_message_id: chat.parent_message_id,
      parent_relation_kind: relation_kind_string(chat.parent_relation_kind),
      subagent: chat.subagent == true,
      can_edit: loaded_value(Map.get(chat, :can_edit)),
      shared_incoming: loaded_value(Map.get(chat, :shared_incoming)),
      shared_outgoing: loaded_value(Map.get(chat, :shared_outgoing)),
      created_at: datetime_iso(chat.created_at),
      updated_at: datetime_iso(chat.updated_at)
    }
  end

  def chat_relation_summary(%Chat{} = chat, opts \\ []) do
    %{
      chat_id: chat.id,
      message_id: Keyword.get(opts, :message_id, chat.parent_message_id),
      parent_chat_id: Keyword.get(opts, :parent_chat_id, chat.parent_chat_id),
      parent_message_id: Keyword.get(opts, :parent_message_id, chat.parent_message_id),
      parent_tool_call_item_id: Keyword.get(opts, :parent_tool_call_item_id),
      parent_step_id: Keyword.get(opts, :parent_step_id),
      parent_step_sequence: Keyword.get(opts, :parent_step_sequence),
      parent_item_sequence: Keyword.get(opts, :parent_item_sequence),
      anchor_message_id: Keyword.get(opts, :anchor_message_id),
      anchor_tool_call_item_id: Keyword.get(opts, :anchor_tool_call_item_id),
      anchor_step_id: Keyword.get(opts, :anchor_step_id),
      anchor_step_sequence: Keyword.get(opts, :anchor_step_sequence),
      anchor_item_sequence: Keyword.get(opts, :anchor_item_sequence),
      kind: relation_kind_string(Keyword.get(opts, :kind, chat.parent_relation_kind)),
      note: chat.note,
      bot_id: chat.bot_id,
      bot_name: chat_bot_name(chat),
      subagent: chat.subagent == true,
      active_generation_message_id: active_generation_message_id(chat),
      last_message_status: last_message_status(chat),
      created_at: datetime_iso(chat.created_at),
      updated_at: datetime_iso(chat.updated_at)
    }
  end

  def chat_continuation_nav_item(%{chat: %Chat{} = chat} = entry) do
    chat
    |> chat_relation_summary(
      kind: Map.get(entry, :kind, chat.parent_relation_kind),
      message_id: Map.get(entry, :message_id, chat.parent_message_id),
      parent_chat_id: chat.parent_chat_id,
      parent_message_id: chat.parent_message_id
    )
    |> Map.put(:label, to_string(Map.get(entry, :label, "")))
  end

  def chat_block_binding(%ChatKnowledgeBlock{} = binding) do
    block = Map.get(binding, :knowledge_block)

    %{
      id: binding.id,
      chat_id: binding.chat_id,
      knowledge_block_id: binding.knowledge_block_id,
      enabled: binding.enabled,
      sequence: binding.sequence,
      knowledge_block: if(is_map(block), do: knowledge_block_option(block), else: nil)
    }
  end

  def tool_instance_option(%ToolInstance{} = tool) do
    %{
      id: tool.id,
      name: tool.name,
      description: loaded_string(Map.get(tool, :description)),
      alias: tool.alias,
      type: tool.type,
      type_title: tool_type_title(tool.type),
      outlet_online: loaded_value(Map.get(tool, :outlet_online)),
      can_edit: loaded_value(Map.get(tool, :can_edit))
    }
  end

  defp tool_type_title(type) when is_binary(type) do
    case DriverMetadata.for_type(type) do
      %{"title" => title} when is_binary(title) and title != "" -> title
      _other -> type
    end
  rescue
    _exception -> type
  end

  defp tool_type_title(type), do: type

  def active_tool_binding(%{} = binding) do
    tool_instance = Map.get(binding, :tool_instance)

    %{
      id: Map.get(binding, :id),
      source: binding |> Map.get(:source) |> optional_atom_to_string(),
      alias: Map.get(binding, :alias) || "",
      sequence: Map.get(binding, :sequence) || 0,
      tool_instance_id: Map.get(binding, :tool_instance_id),
      tool_instance: if(is_map(tool_instance), do: tool_instance_option(tool_instance), else: nil)
    }
  end

  def chat_tool_binding(%ChatToolBinding{} = binding) do
    tool_instance = Map.get(binding, :tool_instance)

    %{
      id: binding.id,
      chat_id: binding.chat_id,
      tool_instance_id: binding.tool_instance_id,
      alias: tool_instance_alias(binding),
      enabled: binding.enabled,
      sequence: binding.sequence,
      tool_instance: if(is_map(tool_instance), do: tool_instance_option(tool_instance), else: nil)
    }
  end

  defp tool_instance_alias(%{tool_instance: %{alias: alias_value}}) when is_binary(alias_value),
    do: alias_value

  defp tool_instance_alias(%{alias: alias_value}) when is_binary(alias_value), do: alias_value
  defp tool_instance_alias(_binding), do: ""

  def branch_message(
        %ChatMessage{} = message,
        branch_meta_by_id \\ %{},
        bookmarked_message_ids \\ MapSet.new()
      ) do
    meta = Map.get(branch_meta_by_id, message.id, %{})
    steps = ordered_by_sequence(message.steps)

    %{
      id: message.id,
      parent_id: message.parent_id,
      role: Atom.to_string(message.role),
      status: Atom.to_string(message.status),
      error_detail: message.error_detail,
      token_count: message.token_count,
      created_at: datetime_iso(message.created_at),
      finished_at: datetime_iso(Map.get(message, :finished_at)),
      llm_configuration_id: message.llm_configuration_id,
      bookmarked: MapSet.member?(bookmarked_message_ids, message.id),
      steps: Enum.map(steps, &step/1),
      prev_sibling_id: Map.get(meta, :prev_sibling),
      next_sibling_id: Map.get(meta, :next_sibling),
      siblings:
        Enum.map(Map.get(meta, :siblings, []), fn sibling ->
          %{
            id: Map.get(sibling, :id),
            size: Map.get(sibling, :size),
            active: Map.get(sibling, :active)
          }
        end)
    }
  end

  def branch_message_light(
        %ChatMessage{} = message,
        branch_meta_by_id \\ %{},
        bookmarked_message_ids \\ MapSet.new(),
        extras \\ %{}
      ) do
    meta = Map.get(branch_meta_by_id, message.id, %{})

    %{
      id: message.id,
      parent_id: message.parent_id,
      role: Atom.to_string(message.role),
      status: Atom.to_string(message.status),
      error_detail: message.error_detail,
      token_count: message.token_count,
      created_at: datetime_iso(message.created_at),
      finished_at: datetime_iso(Map.get(message, :finished_at)),
      llm_configuration_id: message.llm_configuration_id,
      bookmarked: MapSet.member?(bookmarked_message_ids, message.id),
      content: Map.get(extras, :content, %{items: [], parts: [], media: []}),
      usage: Map.get(extras, :usage, usage_summary([])),
      working: Map.get(extras, :working, working_summary([])),
      prev_sibling_id: Map.get(meta, :prev_sibling),
      next_sibling_id: Map.get(meta, :next_sibling),
      siblings:
        Enum.map(Map.get(meta, :siblings, []), fn sibling ->
          %{
            id: Map.get(sibling, :id),
            size: Map.get(sibling, :size),
            active: Map.get(sibling, :active)
          }
        end)
    }
  end

  def message_content_snapshot(
        %ChatMessageContent{} = content,
        %ChatMessageItem{} = item,
        %ChatMessageStep{} = step
      ) do
    item_type = Atom.to_string(item.type)
    serialized = content(content, item_type)

    %{
      step_id: step.id,
      step_sequence: step.sequence,
      item_id: item.id,
      item_sequence: item.sequence,
      item_type: item_type,
      content_id: content.id,
      sequence: content.sequence,
      text: Map.get(serialized, :content_text),
      content_text_truncated: Map.get(serialized, :content_text_truncated),
      created_at: datetime_iso(item.created_at || step.created_at)
    }
  end

  def display_item_snapshot(%ChatMessageItem{} = item, %ChatMessageStep{} = step) do
    %{
      step_id: step.id,
      step_sequence: step.sequence,
      item_id: item.id,
      item_sequence: item.sequence,
      item_type: Atom.to_string(item.type)
    }
  end

  def media_content_snapshot(
        %ChatMessageContent{} = content,
        %ChatMessageItem{} = item,
        %ChatMessageStep{} = step
      ) do
    item_type = Atom.to_string(item.type)

    content(content, item_type)
    |> Map.merge(%{
      step_id: step.id,
      step_sequence: step.sequence,
      item_id: item.id,
      item_sequence: item.sequence,
      item_type: item_type
    })
  end

  def working_summary(steps, retry_errors \\ []) when is_list(steps) and is_list(retry_errors) do
    summaries = Enum.map(steps, &working_step_summary/1)
    latest = latest_step_summary(summaries)
    latest_successful = latest_successful_step_summary(summaries)
    retry_error_summary = retry_error_summary(retry_errors)

    Map.merge(
      %{
        step_count: length(summaries),
        latest_step_id: if(latest, do: Map.get(latest, :id), else: nil),
        latest_step_sequence: if(latest, do: Map.get(latest, :sequence), else: nil),
        latest_step_status: if(latest, do: Map.get(latest, :status), else: nil),
        latest_successful_step_sequence:
          if(latest_successful, do: Map.get(latest_successful, :sequence), else: nil),
        completed_step_duration_ms: completed_step_duration_ms(summaries),
        active_step_started_at:
          summaries
          |> latest_active_step_summary()
          |> active_step_started_at()
      },
      retry_error_summary
    )
  end

  def working_step_summary(%ChatMessageStep{} = step) do
    %{
      id: step.id,
      sequence: step.sequence,
      created_at: datetime_iso(step.created_at),
      time_to_first_token_ms:
        StepMetrics.time_to_first_token_ms(step.created_at, Map.get(step, :first_token_at)),
      tokens_per_second:
        StepMetrics.tokens_per_second(
          step.output_tokens,
          Map.get(step, :first_token_at),
          Map.get(step, :finished_at)
        ),
      finished_at: datetime_iso(Map.get(step, :finished_at)),
      status: Atom.to_string(step.status),
      response_final: step.response_final,
      input_tokens: step.input_tokens,
      output_tokens: step.output_tokens,
      cached_input_tokens: step.cached_input_tokens,
      reasoning_tokens: step.reasoning_tokens,
      cost: step.cost
    }
  end

  def working_step_summary(%{status: status} = step) when is_binary(status) do
    %{
      id: Map.get(step, :id),
      sequence: Map.get(step, :sequence),
      created_at: normalize_datetime_value(Map.get(step, :created_at)),
      time_to_first_token_ms: Map.get(step, :time_to_first_token_ms),
      tokens_per_second: Map.get(step, :tokens_per_second),
      finished_at: normalize_datetime_value(Map.get(step, :finished_at)),
      status: status,
      response_final: Map.get(step, :response_final),
      input_tokens: Map.get(step, :input_tokens),
      output_tokens: Map.get(step, :output_tokens),
      cached_input_tokens: Map.get(step, :cached_input_tokens),
      reasoning_tokens: Map.get(step, :reasoning_tokens),
      cost: Map.get(step, :cost)
    }
  end

  def usage_summary(steps) when is_list(steps) do
    summaries = Enum.map(steps, &working_step_summary/1)

    %{
      latest_step: latest_step_with_usage_summary(summaries),
      total: total_step_usage_summary(summaries),
      total_cost: total_step_cost(summaries)
    }
  end

  def step(%ChatMessageStep{} = step) do
    items = ordered_by_sequence(step.items)

    %{
      id: step.id,
      sequence: step.sequence,
      created_at: datetime_iso(step.created_at),
      time_to_first_token_ms:
        StepMetrics.time_to_first_token_ms(step.created_at, Map.get(step, :first_token_at)),
      tokens_per_second:
        StepMetrics.tokens_per_second(
          step.output_tokens,
          Map.get(step, :first_token_at),
          Map.get(step, :finished_at)
        ),
      finished_at: datetime_iso(Map.get(step, :finished_at)),
      status: Atom.to_string(step.status),
      response_final: step.response_final,
      input_tokens: step.input_tokens,
      output_tokens: step.output_tokens,
      cached_input_tokens: step.cached_input_tokens,
      reasoning_tokens: step.reasoning_tokens,
      cost: step.cost,
      items: Enum.map(items, &item/1)
    }
  end

  def item(%ChatMessageItem{} = item) do
    type = Atom.to_string(item.type)
    contents = ordered_by_sequence(item.contents)

    %{
      id: item.id,
      sequence: item.sequence,
      created_at: datetime_iso(item.created_at),
      type: type,
      tool_call_item_id: item.tool_call_item_id,
      contents:
        contents
        |> Enum.filter(&content_visible_in_bff?(&1, type))
        |> Enum.map(&content(&1, type))
    }
  end

  def content(%ChatMessageContent{} = content, item_type \\ nil) do
    kind = Atom.to_string(content.kind)
    text = to_string(content.content_text || "")
    {preview_text, truncated?} = maybe_truncate_content_text(item_type, kind, text)
    content_json = sanitize_content_json(item_type, kind, content.content_json)

    %{
      id: content.id,
      external_id: content.external_id,
      sequence: content.sequence,
      kind: kind,
      content_text: preview_text,
      content_text_truncated: truncated?,
      content_json: content_json,
      media: Media.media_descriptor(content)
    }
  end

  def normalize_runtime_step_for_client(%{items: items} = step) when is_list(items) do
    items =
      items
      |> ordered_by_sequence()

    normalized_items = Enum.map(items, &normalize_runtime_item/1)
    Map.put(step, :items, normalized_items)
  end

  def normalize_runtime_step_for_client(step), do: step

  defp configuration_display_label(%LlmConfiguration{} = configuration) do
    note = configuration |> Map.get(:note) |> loaded_string() |> String.trim()
    model_name = configuration |> Map.get(:model_name) |> loaded_string() |> String.trim()

    cond do
      model_name != "" and note != "" -> "#{model_name} (#{note})"
      model_name != "" -> model_name
      note != "" -> note
      true -> "No config"
    end
  end

  defp loaded_value(%Ash.NotLoaded{}), do: nil
  defp loaded_value(value), do: value

  defp loaded_string(%Ash.NotLoaded{}), do: ""
  defp loaded_string(value) when is_binary(value), do: value
  defp loaded_string(nil), do: ""
  defp loaded_string(value), do: to_string(value)

  defp loaded_ids(%Ash.NotLoaded{}), do: []

  defp loaded_ids(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{id: id} when is_integer(id) -> id
      id when is_integer(id) -> id
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp loaded_ids(_other), do: []

  defp loaded_names(%Ash.NotLoaded{}), do: []

  defp loaded_names(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{name: name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp loaded_names(_other), do: []

  defp active_generation_message_id(%Chat{} = chat) do
    case Map.get(chat, :last_message) do
      %ChatMessage{id: id, status: :generating} when is_integer(id) -> id
      _ -> nil
    end
  end

  defp last_message_status(%Chat{} = chat) do
    case Map.get(chat, :last_message) do
      %ChatMessage{status: status} when is_atom(status) -> Atom.to_string(status)
      _ -> nil
    end
  end

  defp chat_bot_name(%Chat{} = chat) do
    case Map.get(chat, :bot) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "No bot"
    end
  end

  defp chat_llm_configuration_label(%Chat{} = chat) do
    case Map.get(chat, :llm_configuration) do
      %LlmConfiguration{} = configuration -> configuration_display_label(configuration)
      _ -> nil
    end
  end

  defp relation_kind_string(value) when is_atom(value), do: Atom.to_string(value)
  defp relation_kind_string(_value), do: nil

  defp latest_step_summary([]), do: nil

  defp latest_step_summary(summaries) when is_list(summaries) do
    Enum.max_by(summaries, &{Map.get(&1, :sequence) || 0, Map.get(&1, :id) || 0}, fn -> nil end)
  end

  defp latest_active_step_summary(summaries) when is_list(summaries) do
    summaries
    |> Enum.filter(&active_step_summary?/1)
    |> latest_step_summary()
  end

  defp latest_successful_step_summary(summaries) when is_list(summaries) do
    summaries
    |> Enum.filter(&successful_step_summary?/1)
    |> latest_step_summary()
  end

  defp successful_step_summary?(summary) when is_map(summary) do
    Map.get(summary, :status) in ["done", "waiting_tools"]
  end

  defp successful_step_summary?(_summary), do: false

  defp retry_error_summary(retry_errors) when is_list(retry_errors) do
    errors =
      retry_errors
      |> Enum.filter(&retry_error_entry?/1)
      |> Enum.sort_by(&retry_error_sort_key/1)

    latest = List.last(errors)

    %{
      retry_error_count: length(errors),
      latest_retry_error_text: if(latest, do: Map.get(latest, :text), else: nil),
      latest_retry_error_at:
        if(latest, do: normalize_datetime_value(Map.get(latest, :created_at)), else: nil),
      latest_retry_error_step_sequence: if(latest, do: Map.get(latest, :step_sequence), else: nil)
    }
  end

  defp retry_error_entry?(entry) when is_map(entry) do
    entry
    |> Map.get(:text)
    |> case do
      value when is_binary(value) -> String.trim(value) != ""
      _other -> false
    end
  end

  defp retry_error_entry?(_entry), do: false

  defp retry_error_sort_key(entry) when is_map(entry) do
    {
      Map.get(entry, :step_sequence) || 0,
      Map.get(entry, :item_sequence) || 0,
      Map.get(entry, :item_id) || 0
    }
  end

  defp active_step_summary?(summary) when is_map(summary) do
    is_nil(Map.get(summary, :finished_at)) and active_step_status?(Map.get(summary, :status))
  end

  defp active_step_summary?(_summary), do: false

  defp active_step_status?(status) when status in ["waiting_provider", "waiting_tools"], do: true
  defp active_step_status?(_status), do: false

  defp active_step_started_at(nil), do: nil
  defp active_step_started_at(summary), do: Map.get(summary, :created_at)

  defp completed_step_duration_ms(summaries) when is_list(summaries) do
    Enum.reduce(summaries, 0, fn summary, total -> total + step_duration_ms(summary) end)
  end

  defp step_duration_ms(summary) when is_map(summary) do
    with %DateTime{} = started_at <- summary_datetime(Map.get(summary, :created_at)),
         %DateTime{} = finished_at <- summary_datetime(Map.get(summary, :finished_at)) do
      finished_at
      |> DateTime.diff(started_at, :millisecond)
      |> max(0)
    else
      _other -> 0
    end
  end

  defp step_duration_ms(_summary), do: 0

  defp summary_datetime(%DateTime{} = value), do: value

  defp summary_datetime(%NaiveDateTime{} = value) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp summary_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp summary_datetime(_value), do: nil

  defp latest_step_with_usage_summary(summaries) when is_list(summaries) do
    summaries_with_usage = Enum.filter(summaries, &step_has_token_usage?/1)

    case latest_step_summary(summaries_with_usage) do
      nil -> latest_step_summary(summaries)
      latest -> latest
    end
  end

  defp step_has_token_usage?(summary) when is_map(summary) do
    not is_nil(Map.get(summary, :input_tokens)) or not is_nil(Map.get(summary, :output_tokens))
  end

  defp step_has_token_usage?(_summary), do: false

  defp total_step_usage_summary(summaries) when is_list(summaries) do
    total_cost = total_step_cost(summaries)

    %{
      input_tokens: total_integer_metric(summaries, :input_tokens),
      output_tokens: total_integer_metric(summaries, :output_tokens),
      cached_input_tokens: total_integer_metric(summaries, :cached_input_tokens),
      reasoning_tokens: total_integer_metric(summaries, :reasoning_tokens),
      time_to_first_token_ms: total_integer_metric(summaries, :time_to_first_token_ms),
      tokens_per_second: total_tokens_per_second(summaries),
      cost: total_cost
    }
  end

  defp total_integer_metric(summaries, key) when is_list(summaries) do
    {total, count} =
      Enum.reduce(summaries, {0, 0}, fn summary, {total, count} ->
        case integer_value(Map.get(summary, key)) do
          nil -> {total, count}
          value -> {total + value, count + 1}
        end
      end)

    if count == 0, do: nil, else: total
  end

  defp total_tokens_per_second(summaries) when is_list(summaries) do
    {output_tokens, output_seconds} =
      Enum.reduce(summaries, {0, 0.0}, fn summary, {total_tokens, total_seconds} ->
        with tokens when is_integer(tokens) and tokens > 0 <-
               integer_value(Map.get(summary, :output_tokens)),
             speed when is_number(speed) and speed > 0 <-
               numeric_value(Map.get(summary, :tokens_per_second)) do
          {total_tokens + tokens, total_seconds + tokens / speed}
        else
          _other -> {total_tokens, total_seconds}
        end
      end)

    if output_tokens > 0 and output_seconds > 0 do
      output_tokens / output_seconds
    else
      nil
    end
  end

  defp total_step_cost(summaries) when is_list(summaries) do
    {total, count} =
      Enum.reduce(summaries, {0.0, 0}, fn summary, {total, count} ->
        case numeric_value(Map.get(summary, :cost)) do
          nil -> {total, count}
          cost -> {total + cost, count + 1}
        end
      end)

    if count == 0, do: nil, else: total
  end

  defp numeric_value(value) when is_integer(value), do: value * 1.0
  defp numeric_value(value) when is_float(value), do: value

  defp numeric_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp numeric_value(_value), do: nil

  defp integer_value(value) when is_integer(value) and value >= 0, do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp normalize_datetime_value(%DateTime{} = value), do: datetime_iso(value)
  defp normalize_datetime_value(%NaiveDateTime{} = value), do: datetime_iso(value)
  defp normalize_datetime_value(value) when is_binary(value), do: value
  defp normalize_datetime_value(_value), do: nil

  defp normalize_runtime_item(%{type: type, contents: contents} = item)
       when is_binary(type) and is_list(contents) do
    contents =
      contents
      |> ordered_by_sequence()
      |> Enum.filter(&content_visible_in_bff?(&1, type))
      |> Enum.map(&normalize_runtime_content(&1, type))

    item
    |> Map.put(:created_at, normalize_datetime_value(Map.get(item, :created_at)))
    |> Map.put(:contents, contents)
  end

  defp normalize_runtime_item(item), do: item

  defp normalize_runtime_content(%{kind: kind} = content, item_type) when is_binary(kind) do
    text = Map.get(content, :content_text, "") |> to_string()
    {preview_text, truncated?} = maybe_truncate_content_text(item_type, kind, text)
    content_json = Map.get(content, :content_json)
    sanitized_content_json = sanitize_content_json(item_type, kind, content_json)
    media = runtime_media_descriptor(content)

    content
    |> Map.put(:content_text, preview_text)
    |> Map.put(:content_text_truncated, truncated?)
    |> Map.put(:content_json, sanitized_content_json)
    |> Map.put(:media, media)
  end

  defp normalize_runtime_content(content, _item_type), do: content

  defp runtime_media_descriptor(%{kind: "media"} = content) do
    file = runtime_media_file(Map.get(content, :file))

    Media.media_descriptor(%{
      kind: :media,
      external_id: Map.get(content, :external_id),
      file_id: Map.get(content, :file_id),
      filename: Map.get(content, :filename),
      mime_type: Map.get(content, :mime_type),
      size_bytes: Map.get(content, :size_bytes),
      sha256: Map.get(content, :sha256),
      file: file
    })
  end

  defp runtime_media_descriptor(_content), do: nil

  defp runtime_media_file(%Ash.NotLoaded{}), do: %{}

  defp runtime_media_file(file) when is_map(file) do
    %{
      id: Map.get(file, :id),
      external_id: Map.get(file, :external_id),
      filename: Map.get(file, :filename),
      mime_type: Map.get(file, :mime_type),
      size_bytes: Map.get(file, :size_bytes),
      sha256: Map.get(file, :sha256)
    }
  end

  defp runtime_media_file(_file), do: %{}

  defp maybe_truncate_content_text(item_type, kind, text) do
    if item_type == "tool_result" and kind == "text" do
      truncate_tool_result_preview(text)
    else
      {text, false}
    end
  end

  defp truncate_tool_result_preview(text) when is_binary(text) do
    lines = String.split(text, "\n", trim: false)

    {line_limited, line_truncated?} =
      if length(lines) > @tool_result_preview_line_limit do
        {lines |> Enum.take(@tool_result_preview_line_limit) |> Enum.join("\n"), true}
      else
        {text, false}
      end

    {char_limited, char_truncated?} =
      if String.length(line_limited) > @tool_result_preview_char_limit do
        {String.slice(line_limited, 0, @tool_result_preview_char_limit), true}
      else
        {line_limited, false}
      end

    truncated? = line_truncated? or char_truncated?

    if truncated? do
      suffix = if String.contains?(char_limited, "\n"), do: "\n...", else: "..."
      {String.trim_trailing(char_limited) <> suffix, true}
    else
      {char_limited, false}
    end
  end

  defp sanitize_content_json(item_type, kind, content_json) do
    if item_type == "tool_result" and kind == "opaque" do
      sanitize_tool_result_content_json(content_json)
    else
      content_json
    end
  end

  defp sanitize_tool_result_content_json(%{} = content_json) do
    content_json = Map.new(content_json)

    compact =
      %{}
      |> maybe_put_compact("tool_call_id", Map.get(content_json, "tool_call_id"))
      |> maybe_put_compact("call_id", Map.get(content_json, "call_id"))
      |> maybe_put_compact("name", Map.get(content_json, "name"))

    case sanitize_responses_item_preview(Map.get(content_json, "responses_item")) do
      nil when map_size(compact) == 0 -> nil
      nil -> compact
      responses_item -> Map.put(compact, "responses_item", responses_item)
    end
  end

  defp sanitize_tool_result_content_json(_other), do: nil

  defp sanitize_responses_item_preview(%{} = responses_item) do
    responses_item = Map.new(responses_item)

    compact =
      %{}
      |> maybe_put_compact("type", Map.get(responses_item, "type"))
      |> maybe_put_compact("id", Map.get(responses_item, "id"))
      |> maybe_put_compact("call_id", Map.get(responses_item, "call_id"))
      |> maybe_put_compact("tool_call_id", Map.get(responses_item, "tool_call_id"))
      |> maybe_put_compact("name", Map.get(responses_item, "name"))

    if map_size(compact) == 0, do: nil, else: compact
  end

  defp sanitize_responses_item_preview(_other), do: nil

  defp content_visible_in_bff?(%ChatMessageContent{kind: kind}, item_type) do
    kind = Atom.to_string(kind)
    not (kind == "opaque" and item_type in ["reasoning", "answer", "handoff_summary"])
  end

  defp content_visible_in_bff?(%{kind: kind}, item_type) when is_binary(kind) do
    not (kind == "opaque" and item_type in ["reasoning", "answer", "handoff_summary"])
  end

  defp content_visible_in_bff?(_content, _item_type), do: false

  defp maybe_put_compact(map, _key, nil) when is_map(map), do: map
  defp maybe_put_compact(map, _key, ""), do: map

  defp maybe_put_compact(map, key, value) when is_map(map) and is_binary(key) do
    Map.put(map, key, value)
  end

  defp ordered_by_sequence(values) when is_list(values) do
    Enum.sort_by(values, &sort_seq/1)
  end

  defp ordered_by_sequence(_other), do: []

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp optional_atom_to_string(nil), do: nil
  defp optional_atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
end
