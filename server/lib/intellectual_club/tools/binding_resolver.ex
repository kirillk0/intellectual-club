defmodule IntellectualClub.Tools.BindingResolver do
  @moduledoc """
  Resolves effective tool bindings for chats and builds model-visible tool payloads.
  """

  alias IntellectualClub.Tools.{
    BotToolBinding,
    BotUserToolBinding,
    ChatToolBinding,
    Registry,
    ToolFunction
  }

  require Ash.Query

  @source_priorities %{bot: 1, user: 2, chat: 3}

  def resolve_for_chat(%{} = chat, actor) do
    chat_id = Map.get(chat, :id)
    bot_id = Map.get(chat, :bot_id)

    bot_bindings = load_bot_bindings(bot_id, actor)
    user_bindings = load_user_bindings(bot_id, actor)
    chat_bindings = load_chat_bindings(chat_id, actor)

    entries =
      (candidate_entries(bot_bindings, :bot) ++
         candidate_entries(user_bindings, :user) ++
         candidate_entries(chat_bindings, :chat))
      |> effective_entries()

    missing_aliases = missing_per_user_aliases(bot_bindings, entries)
    tool_groups = build_tool_groups(entries, actor)

    %{
      ordered_alias_entries: alias_entries(entries),
      effective_tool_bindings: entries,
      tool_instances_by_alias: Map.new(entries, &{&1.alias, &1.tool_instance}),
      tools_payload: tools_payload_from_groups(tool_groups),
      tool_context: render_tool_context(tool_groups),
      tool_groups: tool_groups,
      missing_aliases: missing_aliases,
      active_tool_instances: unique_tool_instances(entries)
    }
  end

  def resolve_for_chat(_other, _actor) do
    %{
      ordered_alias_entries: [],
      effective_tool_bindings: [],
      tool_instances_by_alias: %{},
      tools_payload: [],
      tool_context: "",
      tool_groups: [],
      missing_aliases: [],
      active_tool_instances: []
    }
  end

  defp candidate_entries(bindings, source) when is_list(bindings) do
    bindings
    |> Enum.flat_map(fn binding ->
      alias_value = normalized_alias(binding)
      tool_instance = Map.get(binding, :tool_instance)

      cond do
        alias_value == "" ->
          []

        source == :bot and Map.get(binding, :sharing_mode) == :per_user ->
          []

        not is_map(tool_instance) ->
          []

        true ->
          [
            %{
              id: Map.get(binding, :id) || 0,
              source: source,
              source_priority: Map.fetch!(@source_priorities, source),
              alias: alias_value,
              sequence: Map.get(binding, :sequence) || 0,
              tool_instance_id: Map.get(binding, :tool_instance_id),
              tool_instance: tool_instance
            }
          ]
      end
    end)
  end

  defp candidate_entries(_bindings, _source), do: []

  defp effective_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, by_alias ->
      case Map.get(by_alias, entry.alias) do
        nil ->
          Map.put(by_alias, entry.alias, entry)

        current ->
          if entry_wins?(entry, current) do
            Map.put(by_alias, entry.alias, entry)
          else
            by_alias
          end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.source_priority, &1.sequence, &1.id})
  end

  defp effective_entries(_entries), do: []

  defp entry_wins?(left, right) do
    {left.source_priority, left.sequence, left.id} >
      {right.source_priority, right.sequence, right.id}
  end

  defp missing_per_user_aliases(bot_bindings, entries) when is_list(bot_bindings) do
    provided_aliases =
      entries
      |> Enum.filter(&(&1.source in [:user, :chat]))
      |> Enum.map(& &1.alias)
      |> MapSet.new()

    bot_bindings
    |> Enum.filter(&(Map.get(&1, :sharing_mode) == :per_user))
    |> Enum.map(&normalized_alias/1)
    |> Enum.filter(&(&1 != "" and not MapSet.member?(provided_aliases, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp missing_per_user_aliases(_bot_bindings, _entries), do: []

  defp alias_entries(entries) when is_list(entries) do
    Enum.map(entries, &{&1.alias, &1.tool_instance})
  end

  defp alias_entries(_entries), do: []

  defp unique_tool_instances(entries) when is_list(entries) do
    {items, _seen_ids} =
      Enum.reduce(entries, {[], MapSet.new()}, fn
        %{tool_instance: %{id: tool_id} = tool_instance}, {acc, seen_ids}
        when is_integer(tool_id) ->
          if MapSet.member?(seen_ids, tool_id) do
            {acc, seen_ids}
          else
            {acc ++ [tool_instance], MapSet.put(seen_ids, tool_id)}
          end

        _other, acc ->
          acc
      end)

    items
  end

  defp unique_tool_instances(_other), do: []

  defp build_tool_groups(entries, actor) when is_list(entries) do
    Enum.flat_map(entries, fn %{alias: alias_value, tool_instance: tool_instance} ->
      functions =
        tool_instance
        |> list_model_functions(actor)
        |> Enum.filter(& &1.enabled)

      if functions == [] do
        []
      else
        tool_type = tool_instance.type |> to_string() |> String.trim()
        driver = Registry.driver_for_type!(tool_type)

        [
          %{
            alias: alias_value,
            tool_instance: tool_instance,
            type: tool_type,
            type_title: driver_title(driver, tool_type),
            type_description: driver_description(driver),
            instance_context: driver_instance_prompt_context(driver, tool_instance),
            functions: functions
          }
        ]
      end
    end)
  end

  defp build_tool_groups(_other, _actor), do: []

  defp tools_payload_from_groups(groups) when is_list(groups) do
    Enum.flat_map(groups, fn %{alias: alias_value, functions: functions} ->
      Enum.map(functions, fn fn_spec ->
        %{
          "type" => "function",
          "function" => %{
            "name" => "#{alias_value}__#{fn_spec.name}",
            "description" => to_string(fn_spec.description || ""),
            "parameters" =>
              if(
                is_map(fn_spec.parameters_schema) and map_size(fn_spec.parameters_schema) > 0,
                do: fn_spec.parameters_schema,
                else: %{"type" => "object", "properties" => %{}}
              )
          }
        }
      end)
    end)
  end

  defp tools_payload_from_groups(_other), do: []

  defp render_tool_context(groups) when is_list(groups) and groups != [] do
    group_sections =
      groups
      |> Enum.map(&render_tool_group/1)
      |> Enum.reject(&(&1 == ""))

    if group_sections == [] do
      ""
    else
      [
        "# Available tool instances",
        "",
        "The available tools are grouped by tool instance. Tool names have the form `<tool_alias>__<function_name>`.",
        "",
        Enum.join(group_sections, "\n\n")
      ]
      |> Enum.join("\n")
      |> String.trim()
    end
  end

  defp render_tool_context(_groups), do: ""

  defp render_tool_group(%{} = group) do
    alias_value = group.alias |> to_string() |> String.trim()
    tool_instance = Map.get(group, :tool_instance) || %{}
    functions = Map.get(group, :functions) || []

    if alias_value == "" or functions == [] do
      ""
    else
      display_name =
        (Map.get(tool_instance, :name) || "")
        |> to_string()
        |> String.trim()

      type_line = format_type_line(group)
      type_description = normalize_prompt_text(Map.get(group, :type_description))
      instance_description = normalize_prompt_text(Map.get(tool_instance, :description))
      instance_context = normalize_prompt_text(Map.get(group, :instance_context))

      [
        "## Tool instance `#{inline_code(alias_value)}`",
        maybe_line("Display name: ", display_name),
        maybe_line("Type: ", type_line),
        maybe_line("Type description: ", type_description),
        "Available functions:",
        render_function_list(alias_value, functions),
        maybe_block("Instance description:", instance_description),
        maybe_block("Instance context:", instance_context)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> String.trim()
    end
  end

  defp render_tool_group(_other), do: ""

  defp render_function_list(alias_value, functions) when is_list(functions) do
    functions
    |> Enum.map(fn fn_spec -> "- `#{inline_code("#{alias_value}__#{fn_spec.name}")}`" end)
    |> Enum.join("\n")
  end

  defp maybe_line(_prefix, ""), do: ""
  defp maybe_line(prefix, value), do: prefix <> value

  defp maybe_block(_title, ""), do: ""
  defp maybe_block(title, value), do: title <> "\n" <> value

  defp format_type_line(%{type: type, type_title: title}) do
    type = type |> to_string() |> String.trim()
    title = title |> to_string() |> String.trim()

    cond do
      title == "" -> type
      type == "" -> title
      title == type -> title
      true -> "#{title} (#{type})"
    end
  end

  defp driver_title(driver, fallback) do
    driver.title()
    |> to_string()
    |> String.trim()
    |> case do
      "" -> fallback
      value -> value
    end
  rescue
    _exception -> fallback
  end

  defp driver_description(driver) do
    driver.description()
    |> normalize_prompt_text()
  rescue
    _exception -> ""
  end

  defp driver_instance_prompt_context(driver, tool_instance) do
    if function_exported?(driver, :instance_prompt_context, 1) do
      driver
      |> apply(:instance_prompt_context, [tool_instance])
      |> normalize_prompt_text()
    else
      ""
    end
  rescue
    _exception -> ""
  end

  defp normalize_prompt_text(nil), do: ""

  defp normalize_prompt_text(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp inline_code(value) do
    value
    |> to_string()
    |> String.replace("`", "\\`")
  end

  defp list_model_functions(tool_instance, actor) when is_map(tool_instance) do
    tool_type = tool_instance.type |> to_string() |> String.trim()
    driver = Registry.driver_for_type!(tool_type)

    case driver.functions_mode() do
      :stored ->
        ToolFunction
        |> Ash.Query.filter(tool_instance_id == ^tool_instance.id)
        |> Ash.Query.sort(name: :asc, id: :asc)
        |> Ash.read!(actor: actor)
        |> Enum.map(fn fn_record ->
          %{
            name: fn_record.name,
            description: fn_record.description || "",
            parameters_schema: fn_record.parameters_schema || %{},
            enabled: fn_record.enabled
          }
        end)

      :fixed ->
        if function_exported?(driver, :fixed_functions, 1) do
          overrides = fixed_function_overrides(tool_instance, actor)

          apply(driver, :fixed_functions, [tool_instance])
          |> List.wrap()
          |> Enum.map(&normalize_fixed_function/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&apply_fixed_function_override(&1, overrides))
        else
          []
        end
    end
  end

  defp list_model_functions(_tool_instance, _actor), do: []

  defp normalize_fixed_function(raw) when is_map(raw) do
    name = raw |> Map.get("name", Map.get(raw, :name, "")) |> to_string() |> String.trim()

    if name == "" do
      nil
    else
      description =
        raw
        |> Map.get("description", Map.get(raw, :description, ""))
        |> to_string()

      parameters_schema =
        cond do
          is_map(Map.get(raw, "schema")) -> Map.get(raw, "schema")
          is_map(Map.get(raw, :schema)) -> Map.get(raw, :schema)
          is_map(Map.get(raw, "parameters_schema")) -> Map.get(raw, "parameters_schema")
          is_map(Map.get(raw, :parameters_schema)) -> Map.get(raw, :parameters_schema)
          true -> %{"type" => "object", "properties" => %{}}
        end

      enabled =
        case Map.get(raw, "enabled", Map.get(raw, :enabled)) do
          false -> false
          _ -> true
        end

      %{
        name: name,
        description: description,
        parameters_schema: parameters_schema,
        enabled: enabled
      }
    end
  end

  defp normalize_fixed_function(_other), do: nil

  defp fixed_function_overrides(%{id: tool_instance_id}, actor)
       when is_integer(tool_instance_id) do
    ToolFunction
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id)
    |> Ash.read!(actor: actor)
    |> Map.new(fn function -> {function.name, function.enabled} end)
  end

  defp fixed_function_overrides(_tool_instance, _actor), do: %{}

  defp apply_fixed_function_override(%{name: name} = function, overrides)
       when is_map(overrides) do
    case Map.fetch(overrides, name) do
      {:ok, enabled} when is_boolean(enabled) -> %{function | enabled: enabled}
      _other -> function
    end
  end

  defp load_bot_bindings(bot_id, actor) when is_integer(bot_id) do
    BotToolBinding
    |> Ash.Query.filter(bot_id == ^bot_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load(
      [
        :alias,
        tool_instance: [
          :name,
          :description,
          :alias,
          :type,
          :config,
          :secrets,
          :max_output_tokens,
          :outlet_online,
          :can_edit
        ]
      ],
      strict?: true
    )
    |> Ash.read!(actor: actor)
  end

  defp load_bot_bindings(_bot_id, _actor), do: []

  defp load_user_bindings(bot_id, actor) when is_integer(bot_id) do
    BotUserToolBinding
    |> Ash.Query.filter(bot_id == ^bot_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load(
      [
        :alias,
        tool_instance: [
          :name,
          :description,
          :alias,
          :type,
          :config,
          :secrets,
          :max_output_tokens,
          :outlet_online,
          :can_edit
        ]
      ],
      strict?: true
    )
    |> Ash.read!(actor: actor)
  end

  defp load_user_bindings(_bot_id, _actor), do: []

  defp load_chat_bindings(chat_id, actor) when is_integer(chat_id) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load(
      [
        :alias,
        tool_instance: [
          :name,
          :description,
          :alias,
          :type,
          :config,
          :secrets,
          :max_output_tokens,
          :outlet_online,
          :can_edit
        ]
      ],
      strict?: true
    )
    |> Ash.read!(actor: actor)
  end

  defp load_chat_bindings(_chat_id, _actor), do: []

  defp normalized_alias(binding) do
    case Map.get(binding, :alias) do
      alias_value when is_binary(alias_value) ->
        alias_value

      _ ->
        binding
        |> Map.get(:tool_instance)
        |> case do
          %{alias: alias_value} when is_binary(alias_value) -> alias_value
          _ -> ""
        end
    end
    |> to_string()
    |> String.trim()
  end
end
