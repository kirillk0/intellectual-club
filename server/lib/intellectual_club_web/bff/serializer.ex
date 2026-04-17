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
  alias IntellectualClub.Tools.ToolInstance

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

  def variable_entries_from_map(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> %{key: to_string(key), value: to_string(value)} end)
    |> Enum.sort_by(& &1.key)
  end

  def variable_entries_from_map(_other), do: []

  def map_from_variable_entries(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      key =
        entry
        |> Map.get("key", Map.get(entry, :key, ""))
        |> to_string()
        |> String.trim()

      value =
        entry
        |> Map.get("value", Map.get(entry, :value, ""))
        |> to_string()

      if key == "" do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  def map_from_variable_entries(_other), do: %{}

  def user(%User{} = user) do
    %{
      id: user.id,
      username: user.username,
      is_admin: user.is_admin
    }
  end

  def admin_user(%User{} = user) do
    %{
      id: user.id,
      username: user.username,
      is_admin: user.is_admin,
      created_at: datetime_iso(user.created_at),
      updated_at: datetime_iso(user.updated_at),
      groups: user.groups |> loaded_records() |> Enum.map(&admin_user_group_summary/1)
    }
  end

  def admin_user_summary(%User{} = user) do
    %{
      id: user.id,
      username: user.username,
      is_admin: user.is_admin
    }
  end

  def admin_user_group(%UserGroup{} = group) do
    %{
      id: group.id,
      name: group.name,
      created_at: datetime_iso(group.created_at),
      updated_at: datetime_iso(group.updated_at),
      users: group.users |> loaded_records() |> Enum.map(&admin_user_summary/1)
    }
  end

  def admin_user_group_summary(%UserGroup{} = group) do
    %{
      id: group.id,
      name: group.name
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
      compatible_configuration_tag_ids: loaded_ids(Map.get(bot, :compatible_configuration_tags)),
      context_soft_limit_percent: bot.context_soft_limit_percent,
      supports_file_processing: bot.supports_file_processing,
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
      context_length: configuration.context_length,
      supports_image_input: configuration.supports_image_input,
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
      type: atom_to_string(block.type),
      version: block.version,
      token_count: block.token_count,
      can_edit: loaded_value(Map.get(block, :can_edit)),
      shared_incoming: loaded_value(Map.get(block, :shared_incoming)),
      shared_outgoing: loaded_value(Map.get(block, :shared_outgoing))
    }
  end

  def chat_summary(%Chat{} = chat, opts \\ []) do
    bot_name =
      case Map.get(chat, :bot) do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> "No bot"
      end

    llm_configuration_label =
      case Map.get(chat, :llm_configuration) do
        %LlmConfiguration{} = configuration -> configuration_display_label(configuration)
        _ -> nil
      end

    %{
      id: chat.id,
      title: chat.title,
      note: chat.note,
      bot_id: chat.bot_id,
      bot_name: bot_name,
      llm_configuration_id: chat.llm_configuration_id,
      llm_configuration_label: llm_configuration_label,
      active_generation_message_id: active_generation_message_id(chat),
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

  def chat_detail(%Chat{} = chat) do
    %{
      id: chat.id,
      title: chat.title,
      note: chat.note,
      bot_id: chat.bot_id,
      llm_configuration_id: chat.llm_configuration_id,
      variables: variable_entries_from_map(chat.variables || %{}),
      created_at: datetime_iso(chat.created_at),
      updated_at: datetime_iso(chat.updated_at)
    }
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
      type: tool.type,
      outlet_online: loaded_value(Map.get(tool, :outlet_online)),
      can_edit: loaded_value(Map.get(tool, :can_edit))
    }
  end

  def chat_tool_binding(%ChatToolBinding{} = binding) do
    tool_instance = Map.get(binding, :tool_instance)

    %{
      id: binding.id,
      chat_id: binding.chat_id,
      tool_instance_id: binding.tool_instance_id,
      alias: binding.alias,
      enabled: binding.enabled,
      sequence: binding.sequence,
      tool_instance: if(is_map(tool_instance), do: tool_instance_option(tool_instance), else: nil)
    }
  end

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
      role: atom_to_string(message.role),
      status: atom_to_string(message.status),
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
      status: atom_to_string(step.status),
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
    type = atom_to_string(item.type)
    contents = ordered_by_sequence(item.contents)

    %{
      id: item.id,
      sequence: item.sequence,
      created_at: datetime_iso(item.created_at),
      type: type,
      contents:
        contents
        |> Enum.filter(&content_visible_in_bff?(&1, type))
        |> Enum.map(&content(&1, type))
    }
  end

  def content(%ChatMessageContent{} = content, item_type \\ nil) do
    kind = atom_to_string(content.kind)
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

  def normalize_runtime_step_for_client(step) when is_map(step) do
    items =
      step
      |> map_get(:items, "items", [])
      |> List.wrap()
      |> ordered_by_sequence()

    normalized_items = Enum.map(items, &normalize_runtime_item/1)
    put_key(step, :items, "items", normalized_items)
  end

  def normalize_runtime_step_for_client(step), do: step

  defp configuration_display_label(%LlmConfiguration{} = configuration) do
    note = String.trim(to_string(configuration.note || ""))
    model_name = String.trim(to_string(configuration.model_name || ""))

    cond do
      model_name != "" and note != "" -> "#{model_name} (#{note})"
      model_name != "" -> model_name
      note != "" -> note
      true -> "No config"
    end
  end

  defp loaded_value(%Ash.NotLoaded{}), do: nil
  defp loaded_value(value), do: value

  defp loaded_records(%Ash.NotLoaded{}), do: []
  defp loaded_records(values) when is_list(values), do: values
  defp loaded_records(_other), do: []

  defp loaded_ids(%Ash.NotLoaded{}), do: []

  defp loaded_ids(values) when is_list(values) do
    values
    |> Enum.map(fn
      %{id: id} when is_integer(id) -> id
      %{"id" => id} when is_integer(id) -> id
      id when is_integer(id) -> id
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp loaded_ids(_other), do: []

  defp active_generation_message_id(%Chat{} = chat) do
    case Map.get(chat, :last_message) do
      %ChatMessage{id: id, status: :generating} when is_integer(id) -> id
      %ChatMessage{id: id, status: "generating"} when is_integer(id) -> id
      _ -> nil
    end
  end

  defp normalize_runtime_item(item) when is_map(item) do
    type = map_get(item, :type, "type") |> atom_to_string()

    created_at =
      item
      |> map_get(:created_at, "created_at")
      |> datetime_iso()

    contents =
      item
      |> map_get(:contents, "contents", [])
      |> List.wrap()
      |> ordered_by_sequence()
      |> Enum.filter(&content_visible_in_bff?(&1, type))
      |> Enum.map(&normalize_runtime_content(&1, type))

    item
    |> put_key(:created_at, "created_at", created_at)
    |> put_key(:contents, "contents", contents)
  end

  defp normalize_runtime_item(item), do: item

  defp normalize_runtime_content(content, item_type) when is_map(content) do
    kind = map_get(content, :kind, "kind") |> atom_to_string()
    text = map_get(content, :content_text, "content_text", "") |> to_string()
    {preview_text, truncated?} = maybe_truncate_content_text(item_type, kind, text)
    content_json = map_get(content, :content_json, "content_json")
    sanitized_content_json = sanitize_content_json(item_type, kind, content_json)

    content
    |> put_key(:external_id, "external_id", map_get(content, :external_id, "external_id"))
    |> put_key(:content_text, "content_text", preview_text)
    |> put_key(:content_text_truncated, "content_text_truncated", truncated?)
    |> put_key(:content_json, "content_json", sanitized_content_json)
    |> put_key(:media, "media", Media.media_descriptor(content))
  end

  defp normalize_runtime_content(content, _item_type), do: content

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
      |> maybe_put_compact("tool_call_id", map_get(content_json, :tool_call_id, "tool_call_id"))
      |> maybe_put_compact("call_id", map_get(content_json, :call_id, "call_id"))
      |> maybe_put_compact("name", map_get(content_json, :name, "name"))

    case sanitize_responses_item_preview(map_get(content_json, :responses_item, "responses_item")) do
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
      |> maybe_put_compact("type", map_get(responses_item, :type, "type"))
      |> maybe_put_compact("id", map_get(responses_item, :id, "id"))
      |> maybe_put_compact("call_id", map_get(responses_item, :call_id, "call_id"))
      |> maybe_put_compact(
        "tool_call_id",
        map_get(responses_item, :tool_call_id, "tool_call_id")
      )
      |> maybe_put_compact("name", map_get(responses_item, :name, "name"))

    if map_size(compact) == 0, do: nil, else: compact
  end

  defp sanitize_responses_item_preview(_other), do: nil

  defp content_visible_in_bff?(content, item_type) do
    kind = map_get(content, :kind, "kind") |> atom_to_string()
    not (kind == "opaque" and item_type in ["reasoning", "answer"])
  end

  defp maybe_put_compact(map, _key, nil) when is_map(map), do: map
  defp maybe_put_compact(map, _key, ""), do: map

  defp maybe_put_compact(map, key, value) when is_map(map) and is_binary(key) do
    Map.put(map, key, value)
  end

  defp map_get(map, atom_key, string_key, default \\ nil) when is_map(map) do
    cond do
      Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> default
    end
  end

  defp put_key(map, atom_key, string_key, value) when is_map(map) do
    cond do
      Map.has_key?(map, atom_key) -> Map.put(map, atom_key, value)
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, atom_key, value)
    end
  end

  defp ordered_by_sequence(values) when is_list(values) do
    Enum.sort_by(values, &sort_seq/1)
  end

  defp ordered_by_sequence(_other), do: []

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value) when is_binary(value), do: value
  defp atom_to_string(value), do: to_string(value)
end
