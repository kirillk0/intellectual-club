defmodule IntellectualClubWeb.Bff.ChatExportPayload do
  @moduledoc """
  Builds the safe, presentation-oriented payload used by standalone chat exports.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context, as: GenerationContext
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Tools.BindingResolver
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClubWeb.Bff.Loads
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  @relation_kinds [:handoff, :fork, :spawn]
  @max_lineage_hops 100
  @compact_preview_character_limit 50
  @message_text_types %{
    "user" => [
      :input,
      :handoff_request,
      :handoff_context,
      :handoff_history,
      :handoff_message
    ],
    "assistant" => [:answer, :handoff_summary, :steering]
  }
  @message_media_types %{
    "user" => [
      :input,
      :handoff_request,
      :handoff_context,
      :handoff_history,
      :handoff_message
    ],
    "assistant" => [:handoff_summary, :artifact]
  }

  @spec build(Chat.t(), map()) :: map()
  def build(%Chat{} = selected_chat, actor) do
    root = lineage_root(load_export_chat(selected_chat.id, actor) || selected_chat, actor)
    {chats, active_branches} = collect_family(root, actor)
    family_ids = MapSet.new(chats, & &1.id)
    chat_ids = MapSet.to_list(family_ids)

    block_bindings_by_chat = load_chat_block_bindings(chat_ids, actor)
    tool_bindings_by_chat = load_chat_tool_bindings(chat_ids, actor)

    {chat_payloads, block_ids, tool_ids} =
      Enum.reduce(chats, {[], MapSet.new(), MapSet.new()}, fn chat,
                                                              {payloads, block_ids, tool_ids} ->
        tool_resolution = BindingResolver.resolve_for_chat(chat, actor)

        prompt_snapshot =
          GenerationContext.prompt_snapshot!(chat,
            actor: actor,
            tool_resolution: tool_resolution
          )

        context_blocks = serialize_context_block_refs(prompt_snapshot.prompt_blocks)
        context_tools = serialize_context_tool_refs(tool_resolution.effective_tool_bindings)

        chat_blocks =
          block_bindings_by_chat
          |> Map.get(chat.id, [])
          |> Enum.map(&serialize_chat_block_ref/1)

        chat_tools =
          tool_bindings_by_chat
          |> Map.get(chat.id, [])
          |> Enum.map(&serialize_chat_tool_ref/1)

        next_block_ids =
          block_ids
          |> put_ref_ids(context_blocks, :block_id)
          |> put_ref_ids(chat_blocks, :block_id)

        next_tool_ids =
          tool_ids
          |> put_ref_ids(context_tools, :tool_instance_id)
          |> put_ref_ids(chat_tools, :tool_instance_id)

        payload =
          serialize_chat(chat, family_ids, Map.fetch!(active_branches, chat.id),
            context_blocks: context_blocks,
            context_tools: context_tools,
            chat_blocks: chat_blocks,
            chat_tools: chat_tools
          )

        {payloads ++ [payload], next_block_ids, next_tool_ids}
      end)

    %{
      schema_version: 1,
      exported_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      selected_chat_id: selected_chat.id,
      root_chat_id: root.id,
      chats: chat_payloads,
      resources: %{
        knowledge_blocks: serialize_knowledge_blocks(MapSet.to_list(block_ids), actor),
        tools: serialize_tools(MapSet.to_list(tool_ids), actor)
      }
    }
  end

  defp lineage_root(%Chat{} = chat, actor) do
    do_lineage_root(chat, actor, MapSet.new(), 0)
  end

  defp do_lineage_root(%Chat{} = chat, _actor, _visited, hops)
       when hops >= @max_lineage_hops,
       do: chat

  defp do_lineage_root(%Chat{id: id} = chat, actor, visited, hops) do
    cond do
      MapSet.member?(visited, id) ->
        chat

      not is_integer(chat.parent_chat_id) ->
        chat

      true ->
        case load_export_chat(chat.parent_chat_id, actor) do
          %Chat{} = parent ->
            if relation_on_active_branch?(chat, active_branch_ids(parent, actor)) do
              do_lineage_root(parent, actor, MapSet.put(visited, id), hops + 1)
            else
              chat
            end

          nil ->
            chat
        end
    end
  end

  defp collect_family(%Chat{} = root, actor) do
    do_collect_family([root], actor, MapSet.new(), [], %{})
  end

  defp do_collect_family([], _actor, _visited, collected, active_branches),
    do: {collected, active_branches}

  defp do_collect_family(frontier, actor, visited, collected, active_branches) do
    current =
      frontier
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&MapSet.member?(visited, &1.id))

    if current == [] do
      {collected, active_branches}
    else
      next_visited = Enum.reduce(current, visited, &MapSet.put(&2, &1.id))
      current_ids = Enum.map(current, & &1.id)

      current_branches =
        Map.new(current, fn chat -> {chat.id, active_branch(chat, actor)} end)

      active_message_ids =
        Map.new(current_branches, fn {chat_id, messages} ->
          {chat_id, MapSet.new(messages, & &1.id)}
        end)

      children =
        current_ids
        |> load_child_chats(actor)
        |> Enum.filter(fn child ->
          relation_on_active_branch?(
            child,
            Map.get(active_message_ids, child.parent_chat_id, MapSet.new())
          )
        end)

      do_collect_family(
        children,
        actor,
        next_visited,
        collected ++ current,
        Map.merge(active_branches, current_branches)
      )
    end
  end

  defp active_branch_ids(chat, actor), do: chat |> active_branch(actor) |> MapSet.new(& &1.id)

  defp relation_on_active_branch?(%Chat{parent_message_id: nil}, _active_message_ids), do: true

  defp relation_on_active_branch?(
         %Chat{parent_message_id: parent_message_id},
         active_message_ids
       ),
       do: MapSet.member?(active_message_ids, parent_message_id)

  defp load_export_chat(chat_id, actor) when is_integer(chat_id) do
    Chat
    |> Ash.Query.filter(id == ^chat_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(export_chat_load(), strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> chat
      _other -> nil
    end
  end

  defp load_export_chat(_chat_id, _actor), do: nil

  defp load_child_chats([], _actor), do: []

  defp load_child_chats(parent_ids, actor) do
    Chat
    |> Ash.Query.filter(
      parent_chat_id in ^parent_ids and parent_relation_kind in ^@relation_kinds
    )
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.Query.load(export_chat_load(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp export_chat_load do
    [
      bot: [:id, :name, compatible_configuration_tags: [:id, :name]],
      llm_configuration: [:id, :model_name, :note, tags: [:id, :name]]
    ]
  end

  defp load_chat_block_bindings([], _actor), do: %{}

  defp load_chat_block_bindings(chat_ids, actor) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id in ^chat_ids)
    |> Ash.Query.sort(chat_id: :asc, sequence: :asc, id: :asc)
    |> Ash.Query.select([:id, :chat_id, :knowledge_block_id, :enabled, :sequence])
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.chat_id)
  end

  defp load_chat_tool_bindings([], _actor), do: %{}

  defp load_chat_tool_bindings(chat_ids, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id in ^chat_ids)
    |> Ash.Query.sort(chat_id: :asc, sequence: :asc, id: :asc)
    |> Ash.Query.select([:id, :chat_id, :tool_instance_id, :enabled, :sequence])
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.chat_id)
  end

  defp serialize_chat(chat, family_ids, messages, refs) do
    %{
      id: chat.id,
      title: chat_title(chat),
      note: to_string(chat.note || ""),
      subagent: chat.subagent == true,
      created_at: Serializer.datetime_iso(chat.created_at),
      updated_at: Serializer.datetime_iso(chat.updated_at),
      relation: serialize_relation(chat, family_ids),
      bot: serialize_bot(Map.get(chat, :bot)),
      llm_configuration: serialize_configuration(Map.get(chat, :llm_configuration)),
      active_generation: Enum.any?(messages, &(&1.status == :generating)),
      messages: Enum.map(messages, &serialize_message/1),
      context: %{
        blocks: Keyword.fetch!(refs, :context_blocks),
        tools: Keyword.fetch!(refs, :context_tools)
      },
      library: %{
        blocks: Keyword.fetch!(refs, :chat_blocks),
        tools: Keyword.fetch!(refs, :chat_tools)
      }
    }
  end

  defp active_branch(chat, actor) do
    Threads.active_branch(chat, actor,
      load:
        Loads.message_tree() ++
          [llm_configuration: [:id, :model_name, :note, tags: [:id, :name]]],
      strict?: true
    )
  end

  defp serialize_relation(%Chat{parent_chat_id: parent_id} = chat, family_ids)
       when is_integer(parent_id) do
    if MapSet.member?(family_ids, parent_id) do
      %{
        parent_chat_id: parent_id,
        parent_message_id: chat.parent_message_id,
        kind: atom_string(chat.parent_relation_kind)
      }
    end
  end

  defp serialize_relation(_chat, _family_ids), do: nil

  defp serialize_message(message) do
    steps = ordered(Map.get(message, :steps, []))
    role = atom_string(message.role)

    %{
      id: message.id,
      parent_id: message.parent_id,
      role: role,
      status: atom_string(message.status),
      error_detail: message.error_detail,
      token_count: message.token_count,
      created_at: Serializer.datetime_iso(message.created_at),
      finished_at: Serializer.datetime_iso(message.finished_at),
      llm_configuration: serialize_configuration(Map.get(message, :llm_configuration)),
      usage: Serializer.usage_summary(steps),
      content: serialize_message_content(steps, role),
      working_steps:
        if(role == "assistant", do: Enum.map(steps, &serialize_working_step/1), else: [])
    }
  end

  defp serialize_message_content(steps, role) do
    Enum.flat_map(steps, fn step ->
      step
      |> Map.get(:items, [])
      |> ordered()
      |> Enum.flat_map(&serialize_display_item(&1, step, role))
    end)
  end

  defp serialize_display_item(%ChatMessageItem{} = item, step, role) do
    text_visible? = item.type in Map.get(@message_text_types, role, [])
    media_visible? = item.type in Map.get(@message_media_types, role, [])

    if text_visible? or media_visible? do
      contents = ordered(item.contents)

      parts =
        if text_visible? do
          contents
          |> Enum.filter(&(&1.kind == :text))
          |> Enum.map(&serialize_text_part(&1, item.type))
          |> Enum.reject(&(String.trim(&1.text) == ""))
        else
          []
        end

      attachments =
        if media_visible? do
          contents
          |> Enum.filter(&(&1.kind == :media))
          |> Enum.map(&serialize_content_attachment/1)
          |> Enum.reject(&is_nil/1)
        else
          []
        end

      if parts == [] and attachments == [] do
        []
      else
        [
          %{
            type: atom_string(item.type),
            step_sequence: step.sequence,
            item_sequence: item.sequence,
            created_at: Serializer.datetime_iso(item.created_at || step.created_at),
            parts: parts,
            attachments: attachments
          }
        ]
      end
    else
      []
    end
  end

  defp serialize_text_part(%ChatMessageContent{} = content, item_type) do
    %{
      text: to_string(content.content_text || ""),
      handoff_entry: serialize_handoff_entry(item_type, content.content_json)
    }
  end

  defp serialize_handoff_entry(:handoff_history, metadata) when is_map(metadata) do
    entry_kind = map_value(metadata, "entry_kind")
    role = map_value(metadata, "role")
    omitted_count = map_value(metadata, "omitted_count")
    created_at = map_value(metadata, "created_at")

    %{
      entry_kind: if(entry_kind in ["message", "continuation", "omission"], do: entry_kind),
      role: if(role in ["user", "assistant"], do: role),
      omitted_count: if(is_integer(omitted_count) and omitted_count > 0, do: omitted_count),
      created_at: if(is_binary(created_at), do: created_at)
    }
  end

  defp serialize_handoff_entry(_item_type, _metadata), do: nil

  defp serialize_working_step(%ChatMessageStep{} = step) do
    step
    |> Serializer.working_step_summary()
    |> Map.put(
      :items,
      step
      |> Map.get(:items, [])
      |> ordered()
      |> Enum.reject(&(&1.type == :input))
      |> Enum.flat_map(&serialize_working_item/1)
    )
  end

  defp serialize_working_item(%ChatMessageItem{type: :tool_call} = item) do
    {name, arguments} = tool_call_info(item.contents)

    [
      %{
        type: "tool_call",
        sequence: item.sequence,
        created_at: Serializer.datetime_iso(item.created_at),
        name: name,
        arguments: arguments
      }
    ]
  end

  defp serialize_working_item(%ChatMessageItem{type: :tool_result} = item) do
    previews =
      item.contents
      |> ordered()
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.map(&Serializer.content(&1, "tool_result"))

    attachments =
      item.contents
      |> ordered()
      |> Enum.filter(&(&1.kind == :media))
      |> Enum.map(&serialize_content_attachment/1)
      |> Enum.reject(&is_nil/1)

    [
      %{
        type: "tool_result",
        sequence: item.sequence,
        created_at: Serializer.datetime_iso(item.created_at),
        text: Enum.map_join(previews, "\n", &to_string(Map.get(&1, :content_text) || "")),
        truncated: Enum.any?(previews, &(Map.get(&1, :content_text_truncated) == true)),
        attachments: attachments
      }
    ]
  end

  defp serialize_working_item(%ChatMessageItem{type: :artifact} = item) do
    attachments =
      item.contents
      |> ordered()
      |> Enum.filter(&(&1.kind == :media))
      |> Enum.map(&serialize_content_attachment/1)
      |> Enum.reject(&is_nil/1)

    if attachments == [] do
      []
    else
      [
        %{
          type: "artifact",
          sequence: item.sequence,
          created_at: Serializer.datetime_iso(item.created_at),
          attachments: attachments
        }
      ]
    end
  end

  defp serialize_working_item(%ChatMessageItem{type: type} = item)
       when type in [:answer, :steering, :handoff_summary, :handoff_request] do
    text = item_text(item)

    if String.trim(text) == "" do
      []
    else
      [
        %{
          type: atom_string(type),
          sequence: item.sequence,
          created_at: Serializer.datetime_iso(item.created_at),
          text: compact_preview(text)
        }
      ]
    end
  end

  defp serialize_working_item(%ChatMessageItem{} = item) do
    text = item_text(item)

    if String.trim(text) == "" do
      []
    else
      [
        %{
          type: atom_string(item.type),
          sequence: item.sequence,
          created_at: Serializer.datetime_iso(item.created_at),
          text: text
        }
      ]
    end
  end

  defp item_text(%ChatMessageItem{} = item) do
    item.contents
    |> ordered()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("", &to_string(&1.content_text || ""))
  end

  defp compact_preview(text) do
    normalized = text |> String.trim() |> String.replace(~r/\s+/u, " ")

    if String.length(normalized) <= @compact_preview_character_limit do
      normalized
    else
      String.slice(normalized, 0, @compact_preview_character_limit) <> "…"
    end
  end

  defp tool_call_info(contents) do
    payload =
      contents
      |> ordered()
      |> Enum.find_value(fn
        %ChatMessageContent{kind: :opaque, content_json: value} when is_map(value) -> value
        _content -> nil
      end)

    function = payload |> map_value("raw") |> map_value("function")
    raw = map_value(payload, "raw")

    name =
      map_value(payload, "name") || map_value(function, "name") || map_value(raw, "name") || ""

    arguments =
      map_value(payload, "arguments") || map_value(function, "arguments") ||
        map_value(raw, "arguments")

    {to_string(name), normalize_tool_arguments(arguments)}
  end

  defp normalize_tool_arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _error -> value
    end
  end

  defp normalize_tool_arguments(value), do: value

  defp serialize_context_block_refs(prompt_blocks) do
    Enum.flat_map(prompt_blocks || [], fn entry ->
      case Map.get(entry, :knowledge_block) do
        %{id: id} when is_integer(id) ->
          [
            %{
              block_id: id,
              source: atom_string(Map.get(entry, :source)),
              selection: atom_string(Map.get(entry, :selection)),
              sequence: Map.get(entry, :sequence) || 0,
              order: Map.get(entry, :prompt_order) || 0,
              enabled: true
            }
          ]

        _other ->
          []
      end
    end)
  end

  defp serialize_context_tool_refs(bindings) do
    Enum.flat_map(bindings || [], fn binding ->
      case Map.get(binding, :tool_instance_id) do
        id when is_integer(id) ->
          [
            %{
              tool_instance_id: id,
              alias: to_string(Map.get(binding, :alias) || ""),
              source: atom_string(Map.get(binding, :source)),
              sequence: Map.get(binding, :sequence) || 0,
              enabled: true,
              background_functions_unavailable:
                Map.get(binding, :background_functions_unavailable) == true
            }
          ]

        _other ->
          []
      end
    end)
  end

  defp serialize_chat_block_ref(binding) do
    %{
      block_id: binding.knowledge_block_id,
      sequence: binding.sequence || 0,
      enabled: binding.enabled != false
    }
  end

  defp serialize_chat_tool_ref(binding) do
    %{
      tool_instance_id: binding.tool_instance_id,
      sequence: binding.sequence || 0,
      enabled: binding.enabled != false
    }
  end

  defp serialize_knowledge_blocks([], _actor), do: []

  defp serialize_knowledge_blocks(block_ids, actor) do
    KnowledgeBlock
    |> Ash.Query.filter(id in ^block_ids)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.Query.select([
      :id,
      :name,
      :version,
      :content,
      :token_count,
      :created_at,
      :updated_at,
      :image_file_id
    ])
    |> Ash.Query.load(
      [
        image_file: [:filename, :mime_type, :size_bytes],
        tag_bindings: [knowledge_tag: [:name, :full_name]],
        file_bindings: [
          :sequence,
          :enabled,
          file: [:filename, :mime_type, :size_bytes]
        ]
      ],
      strict?: true
    )
    |> Ash.read!(actor: actor)
    |> Enum.map(&serialize_knowledge_block/1)
  end

  defp serialize_knowledge_block(block) do
    image_attachment =
      case Map.get(block, :image_file) do
        %Ash.NotLoaded{} -> []
        nil -> []
        file -> [serialize_file_attachment(file, "image", true)]
      end

    file_attachments =
      block
      |> Map.get(:file_bindings, [])
      |> loaded_list()
      |> ordered()
      |> Enum.flat_map(fn binding ->
        case Map.get(binding, :file) do
          %Ash.NotLoaded{} -> []
          nil -> []
          file -> [serialize_file_attachment(file, "file", binding.enabled != false)]
        end
      end)

    tags =
      block
      |> Map.get(:tag_bindings, [])
      |> loaded_list()
      |> Enum.flat_map(fn binding ->
        case Map.get(binding, :knowledge_tag) do
          %Ash.NotLoaded{} -> []
          %{full_name: value} when is_binary(value) and value != "" -> [value]
          %{name: value} when is_binary(value) and value != "" -> [value]
          _other -> []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      id: block.id,
      name: block.name,
      version: block.version,
      content: block.content,
      token_count: block.token_count,
      tags: tags,
      attachments: image_attachment ++ file_attachments,
      created_at: Serializer.datetime_iso(block.created_at),
      updated_at: Serializer.datetime_iso(block.updated_at)
    }
  end

  defp serialize_tools([], _actor), do: []

  defp serialize_tools(tool_ids, actor) do
    ToolInstance
    |> Ash.Query.filter(id in ^tool_ids)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.Query.select([:id, :name, :description, :alias, :type, :config])
    |> Ash.read!(actor: actor)
    |> Enum.map(fn tool ->
      description = BindingResolver.describe_tool_instance(tool, actor)

      %{
        id: tool.id,
        name: tool.name,
        alias: tool.alias,
        type: tool.type,
        type_title: description.type_title,
        type_description: description.type_description,
        description: tool.description,
        functions: description.functions
      }
    end)
  end

  defp serialize_bot(nil), do: nil
  defp serialize_bot(%Ash.NotLoaded{}), do: nil

  defp serialize_bot(bot) do
    %{
      name: bot.name,
      tags:
        bot
        |> Map.get(:compatible_configuration_tags, [])
        |> loaded_list()
        |> Enum.map(&to_string(Map.get(&1, :name) || ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp serialize_configuration(nil), do: nil
  defp serialize_configuration(%Ash.NotLoaded{}), do: nil

  defp serialize_configuration(%LlmConfiguration{} = configuration) do
    %{
      label: configuration_label(configuration),
      tags:
        configuration
        |> Map.get(:tags, [])
        |> loaded_list()
        |> Enum.map(&to_string(Map.get(&1, :name) || ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp serialize_configuration(_other), do: nil

  defp configuration_label(configuration) do
    model_name = configuration |> Map.get(:model_name, "") |> to_string() |> String.trim()
    note = configuration |> Map.get(:note, "") |> to_string() |> String.trim()

    cond do
      model_name != "" and note != "" -> "#{model_name} (#{note})"
      model_name != "" -> model_name
      note != "" -> note
      true -> ""
    end
  end

  defp chat_title(chat) do
    note = chat |> Map.get(:note, "") |> to_string() |> String.trim()

    cond do
      note != "" ->
        note

      is_map(Map.get(chat, :bot)) and to_string(Map.get(chat.bot, :name) || "") != "" ->
        to_string(chat.bot.name)

      true ->
        "Chat ##{chat.id}"
    end
  end

  defp serialize_content_attachment(content) do
    case Map.get(content, :file) do
      %Ash.NotLoaded{} -> nil
      nil -> nil
      file -> serialize_file_attachment(file, "file", true)
    end
  end

  defp serialize_file_attachment(file, kind, enabled) do
    %{
      name: to_string(Map.get(file, :filename) || "Attachment"),
      mime_type: to_string(Map.get(file, :mime_type) || ""),
      size_bytes: normalize_size(Map.get(file, :size_bytes)),
      kind: kind,
      enabled: enabled
    }
  end

  defp put_ref_ids(ids, refs, key) do
    Enum.reduce(refs, ids, fn ref, acc ->
      case Map.get(ref, key) do
        id when is_integer(id) -> MapSet.put(acc, id)
        _other -> acc
      end
    end)
  end

  defp normalize_size(value) when is_integer(value) and value >= 0, do: value
  defp normalize_size(_value), do: 0

  defp loaded_list(%Ash.NotLoaded{}), do: []
  defp loaded_list(value) when is_list(value), do: value
  defp loaded_list(_value), do: []

  defp ordered(%Ash.NotLoaded{}), do: []

  defp ordered(values) when is_list(values) do
    Enum.sort_by(values, &{Map.get(&1, :sequence) || 0, Map.get(&1, :id) || 0})
  end

  defp ordered(_values), do: []

  defp map_value(value, key) when is_map(value) and is_binary(key) do
    Map.get(value, key, Map.get(value, String.to_existing_atom(key)))
  rescue
    ArgumentError -> Map.get(value, key)
  end

  defp map_value(_value, _key), do: nil

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value) when is_binary(value), do: value
  defp atom_string(value), do: to_string(value)
end
