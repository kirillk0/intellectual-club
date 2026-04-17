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

  def resolve_for_chat(%{} = chat, actor) do
    chat_id = Map.get(chat, :id)
    bot_id = Map.get(chat, :bot_id)

    bot_bindings = load_bot_bindings(bot_id, actor)
    user_bindings = load_user_bindings(bot_id, actor)
    chat_bindings = load_chat_bindings(chat_id, actor)

    {entries, missing_aliases} =
      bot_bindings
      |> merge_bot_bindings()
      |> merge_user_bindings(user_bindings)
      |> merge_chat_bindings(chat_bindings)

    %{
      ordered_alias_entries: entries,
      tool_instances_by_alias: Map.new(entries),
      tools_payload: build_tools_payload(entries, actor),
      missing_aliases: missing_aliases,
      active_tool_instances: unique_tool_instances(entries)
    }
  end

  def resolve_for_chat(_other, _actor) do
    %{
      ordered_alias_entries: [],
      tool_instances_by_alias: %{},
      tools_payload: [],
      missing_aliases: [],
      active_tool_instances: []
    }
  end

  defp merge_bot_bindings(bindings) when is_list(bindings) do
    Enum.reduce(bindings, {[], MapSet.new()}, fn binding, {entries, missing_aliases} ->
      alias_value = normalized_alias(binding)

      cond do
        alias_value == "" ->
          {entries, missing_aliases}

        Map.get(binding, :sharing_mode) == :per_user ->
          {entries, MapSet.put(missing_aliases, alias_value)}

        is_map(Map.get(binding, :tool_instance)) ->
          {put_alias_entry(entries, alias_value, Map.get(binding, :tool_instance)),
           missing_aliases}

        true ->
          {entries, missing_aliases}
      end
    end)
  end

  defp merge_bot_bindings(_other), do: {[], MapSet.new()}

  defp merge_user_bindings({entries, missing_aliases}, bindings) when is_list(bindings) do
    Enum.reduce(bindings, {entries, missing_aliases}, fn binding,
                                                         {acc_entries, acc_missing_aliases} ->
      maybe_put_override_entry(binding, acc_entries, acc_missing_aliases)
    end)
  end

  defp merge_user_bindings(acc, _other), do: acc

  defp merge_chat_bindings({entries, missing_aliases}, bindings) when is_list(bindings) do
    merged =
      Enum.reduce(bindings, {entries, missing_aliases}, fn binding,
                                                           {acc_entries, acc_missing_aliases} ->
        maybe_put_override_entry(binding, acc_entries, acc_missing_aliases)
      end)

    normalize_resolved_bindings(merged)
  end

  defp merge_chat_bindings(acc, _other), do: normalize_resolved_bindings(acc)

  defp maybe_put_override_entry(binding, entries, missing_aliases) do
    alias_value = normalized_alias(binding)
    tool_instance = Map.get(binding, :tool_instance)

    if alias_value != "" and is_map(tool_instance) do
      {
        put_alias_entry(entries, alias_value, tool_instance),
        MapSet.delete(missing_aliases, alias_value)
      }
    else
      {entries, missing_aliases}
    end
  end

  defp normalize_resolved_bindings({entries, missing_aliases}) do
    {entries, missing_aliases |> MapSet.to_list() |> Enum.sort()}
  end

  defp put_alias_entry(entries, alias_value, tool_instance) when is_list(entries) do
    case Enum.find_index(entries, fn {existing_alias, _tool_instance} ->
           existing_alias == alias_value
         end) do
      nil ->
        entries ++ [{alias_value, tool_instance}]

      index ->
        List.replace_at(entries, index, {alias_value, tool_instance})
    end
  end

  defp unique_tool_instances(entries) when is_list(entries) do
    {items, _seen_ids} =
      Enum.reduce(entries, {[], MapSet.new()}, fn
        {_alias_value, %{id: tool_id} = tool_instance}, {acc, seen_ids}
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

  defp build_tools_payload(entries, actor) when is_list(entries) do
    Enum.flat_map(entries, fn {alias_value, tool_instance} ->
      functions = list_model_functions(tool_instance, actor)

      Enum.flat_map(functions, fn fn_spec ->
        if fn_spec.enabled do
          [
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
          ]
        else
          []
        end
      end)
    end)
  end

  defp build_tools_payload(_other, _actor), do: []

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
          apply(driver, :fixed_functions, [tool_instance])
          |> List.wrap()
          |> Enum.map(&normalize_fixed_function/1)
          |> Enum.reject(&is_nil/1)
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

  defp load_bot_bindings(bot_id, actor) when is_integer(bot_id) do
    BotToolBinding
    |> Ash.Query.filter(bot_id == ^bot_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load(
      [
        tool_instance: [
          :name,
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
        tool_instance: [
          :name,
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
        tool_instance: [
          :name,
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
    binding
    |> Map.get(:alias, "")
    |> to_string()
    |> String.trim()
  end
end
