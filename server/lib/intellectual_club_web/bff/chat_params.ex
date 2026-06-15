defmodule IntellectualClubWeb.Bff.ChatParams do
  @moduledoc """
  Request parameter parsing for chat BFF route groups.
  """

  alias IntellectualClubWeb.Bff.Helpers

  @chat_update_fields ~w(note bot_id llm_configuration_id knowledge_block_bindings tool_bindings)

  def bot_filter(params) when is_map(params) do
    raw =
      params
      |> Map.get("bot")
      |> case do
        nil -> ""
        other -> to_string(other)
      end
      |> String.trim()

    cond do
      raw == "" ->
        {:ok, nil}

      raw == "none" ->
        {:ok, :none}

      true ->
        case Integer.parse(raw) do
          {value, ""} when value > 0 -> {:ok, value}
          _ -> {:error, "bot must be an integer or none"}
        end
    end
  end

  def pagination(params) when is_map(params) do
    %{
      page: parse_positive_integer(Map.get(params, "page"), 1),
      per_page: parse_positive_integer(Map.get(params, "per_page"), 20, 100)
    }
  end

  def preview_len(params) when is_map(params) do
    default = 200

    case Map.get(params, "preview_len") do
      nil ->
        default

      "" ->
        default

      raw ->
        with {value, ""} <- Integer.parse(to_string(raw)),
             value when value > 0 <- value do
          min(value, 500)
        else
          _ -> default
        end
    end
  end

  def resource_id(id) do
    case Helpers.parse_optional_integer(id) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :not_found}
    end
  end

  def group_ids(params) do
    case Map.get(params, "group_ids", []) do
      ids when is_list(ids) ->
        if Enum.all?(ids, &valid_integer_like?/1) do
          {:ok, Helpers.parse_integer_list(ids)}
        else
          {:error, {:validation, "group_ids must contain integers."}}
        end

      _other ->
        {:error, {:validation, "group_ids must be a list."}}
    end
  end

  def create_chat_attrs(params) when is_map(params) do
    attrs = %{
      note: Map.get(params, "note", ""),
      bot_id: Helpers.parse_optional_integer(Map.get(params, "bot_id"))
    }

    if Map.has_key?(params, "llm_configuration_id") do
      Map.put(
        attrs,
        :llm_configuration_id,
        Helpers.parse_optional_integer(Map.get(params, "llm_configuration_id"))
      )
    else
      attrs
    end
  end

  def chat_patch(params) when is_map(params) do
    params
    |> Map.take(@chat_update_fields)
    |> Enum.reduce(%{}, fn
      {"bot_id", value}, acc ->
        Map.put(acc, :bot_id, Helpers.parse_optional_integer(value))

      {"llm_configuration_id", value}, acc ->
        Map.put(acc, :llm_configuration_id, Helpers.parse_optional_integer(value))

      {"knowledge_block_bindings", value}, acc ->
        Map.put(acc, :knowledge_block_bindings, knowledge_block_bindings(value))

      {"tool_bindings", value}, acc ->
        Map.put(acc, :tool_bindings, tool_bindings(value))

      {"note", value}, acc ->
        Map.put(acc, :note, value)

      _other, acc ->
        acc
    end)
  end

  def switch_params(params) when is_map(params) do
    %{}
    |> maybe_put_switch_direction(Map.get(params, "direction"))
    |> maybe_put_switch_target(Helpers.parse_optional_integer(Map.get(params, "target_id")))
  end

  def generation_parent_opts(params, actor) when is_map(params) do
    raw_parent_id = Map.get(params, "parent_id")
    explicit_parent? = Map.has_key?(params, "parent_id")
    parent_id = Helpers.parse_optional_integer(raw_parent_id)

    [actor: actor]
    |> maybe_put_generation_parent_id(raw_parent_id, parent_id, explicit_parent?)
  end

  def match_type(:meta), do: "meta"
  def match_type(:active_message), do: "active_message"
  def match_type(:inactive_message), do: "inactive_message"
  def match_type(other) when is_binary(other), do: other
  def match_type(other) when is_atom(other), do: Atom.to_string(other)
  def match_type(_other), do: nil

  def branch_user_replacement_contents(params, file_ids) do
    content = params |> Map.get("content", "") |> to_string()

    text_contents =
      case content do
        "" -> []
        text -> [%{kind: :text, content_text: text}]
      end

    media_contents = Enum.map(file_ids, &%{kind: :media, file_id: &1})
    text_contents ++ media_contents
  end

  defp parse_positive_integer(nil, default), do: default
  defp parse_positive_integer("", default), do: default
  defp parse_positive_integer(value, default), do: parse_positive_integer(value, default, nil)

  defp parse_positive_integer(value, default, max_value) do
    parsed =
      case Integer.parse(to_string(value)) do
        {number, ""} when number > 0 -> number
        _ -> default
      end

    if is_integer(max_value) and max_value > 0 do
      min(parsed, max_value)
    else
      parsed
    end
  end

  defp knowledge_block_bindings(value) do
    value
    |> List.wrap()
    |> Enum.map(fn
      %{} = item ->
        id = Helpers.parse_optional_integer(Map.get(item, "id"))

        knowledge_block_id =
          Helpers.parse_optional_integer(
            Map.get(item, "knowledge_block_id") || Map.get(item, "block")
          )

        enabled = truthy?(Map.get(item, "enabled", true))

        cond do
          not is_integer(knowledge_block_id) ->
            nil

          is_integer(id) and id > 0 ->
            %{id: id, knowledge_block_id: knowledge_block_id, enabled: enabled}

          true ->
            %{knowledge_block_id: knowledge_block_id, enabled: enabled}
        end

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_bindings(value) do
    value
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn
      {%{} = item, index} ->
        id = Helpers.parse_optional_integer(Map.get(item, "id"))
        tool_instance_id = Helpers.parse_optional_integer(Map.get(item, "tool_instance_id"))
        enabled = truthy?(Map.get(item, "enabled", true))

        cond do
          not is_integer(tool_instance_id) ->
            nil

          is_integer(id) and id > 0 ->
            %{id: id, tool_instance_id: tool_instance_id, enabled: enabled, sequence: index}

          true ->
            %{tool_instance_id: tool_instance_id, enabled: enabled, sequence: index}
        end

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp truthy?(false), do: false
  defp truthy?("false"), do: false
  defp truthy?(_value), do: true

  defp maybe_put_switch_direction(opts, "prev"), do: Map.put(opts, :direction, :prev)
  defp maybe_put_switch_direction(opts, "next"), do: Map.put(opts, :direction, :next)
  defp maybe_put_switch_direction(opts, _direction), do: opts

  defp maybe_put_switch_target(opts, target_id) when is_integer(target_id),
    do: Map.put(opts, :target_id, target_id)

  defp maybe_put_switch_target(opts, _target_id), do: opts

  defp maybe_put_generation_parent_id(opts, _raw_parent_id, parent_id, true)
       when is_integer(parent_id) do
    Keyword.put(opts, :parent_id, parent_id)
  end

  defp maybe_put_generation_parent_id(opts, raw_parent_id, _parent_id, true)
       when is_nil(raw_parent_id) or raw_parent_id == "" do
    Keyword.put(opts, :parent_id, nil)
  end

  defp maybe_put_generation_parent_id(opts, _raw_parent_id, _parent_id, _explicit_parent?),
    do: opts

  defp valid_integer_like?(value) when is_integer(value), do: true

  defp valid_integer_like?(value) when is_binary(value) do
    match?({number, ""} when number > 0, Integer.parse(value))
  end

  defp valid_integer_like?(_value), do: false
end
