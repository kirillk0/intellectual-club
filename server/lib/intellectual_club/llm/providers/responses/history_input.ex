defmodule IntellectualClub.Llm.Providers.Responses.HistoryInput do
  @moduledoc """
  Projects canonical persisted history into Responses API input items.
  """

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Generation.History

  @responses_item_types MapSet.new([
                          "message",
                          "reasoning",
                          "function_call",
                          "function_call_output"
                        ])

  @doc """
  Builds Responses API `input[]` items from a linear message branch.
  """
  def build_input_items(history, opts \\ []) when is_list(history) and is_list(opts) do
    history
    |> Enum.flat_map(&input_items_from_history_entry(&1, opts))
    |> Enum.flat_map(fn
      nil -> []
      %{} = item -> [item]
      _other -> []
    end)
  end

  defp input_items_from_history_entry(message, opts) do
    if History.trace_message?(message) do
      case History.message_role(message) do
        "user" ->
          input_contents = History.project_contents_for_item_type(message, :input)

          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => Media.responses_message_content(input_contents, opts)
            }
          ]

        "assistant" ->
          items =
            message
            |> History.steps()
            |> Enum.sort_by(&History.sort_seq/1)
            |> Enum.flat_map(fn step ->
              step
              |> History.items()
              |> Enum.sort_by(&History.sort_seq/1)
            end)

          valid_tool_call_refs = valid_tool_call_refs(items)
          indexed_items = Enum.with_index(items)
          last_answer_index = last_answer_item_index(indexed_items)

          out =
            Enum.flat_map(indexed_items, fn {item, item_index} ->
              case History.item_type(item) do
                :reasoning ->
                  []

                :answer ->
                  case item_for_answer(item) do
                    nil ->
                      text = History.item_text(item)

                      if String.trim(text) == "" do
                        []
                      else
                        [
                          synthesized_answer_item(
                            text,
                            fallback_answer_phase(item_index, last_answer_index)
                          )
                        ]
                      end

                    %{} = map ->
                      [map]
                  end

                :tool_call ->
                  case item_for_tool_call(item) do
                    nil ->
                      []

                    %{} = map ->
                      if orphaned_tool_call?(item, map, valid_tool_call_refs) do
                        []
                      else
                        [map]
                      end
                  end

                :tool_result ->
                  out =
                    case item_for_tool_result(item) do
                      nil -> []
                      %{} = map -> [map]
                    end

                  out ++
                    Media.media_followup_input_items(History.media_contents_for_item(item), opts)

                :artifact ->
                  []

                _other ->
                  []
              end
            end)

          if out == [] do
            fallback_text = History.project_text_for_item_type(message, :answer)

            [
              synthesized_answer_item(fallback_text, "final_answer")
            ]
          else
            out
          end

        _other ->
          []
      end
    else
      case History.normalize_message(message) do
        nil ->
          []

        %{"role" => "user", "content" => text} ->
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => text}]
            }
          ]

        %{"role" => "assistant", "content" => text} ->
          [
            %{
              "type" => "message",
              "role" => "assistant",
              "status" => "completed",
              "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
            }
          ]
      end
    end
  end

  defp item_for_answer(item) do
    case extract_responses_item(item) do
      %{} = responses_item ->
        case get_any(responses_item, [{"type", :type}]) do
          "message" -> sanitize_item(responses_item)
          "reasoning" -> nil
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp item_for_tool_call(item) do
    case extract_responses_item(item) do
      %{} = responses_item ->
        case get_any(responses_item, [{"type", :type}]) do
          "function_call" -> sanitize_item(responses_item)
          "reasoning" -> nil
          _other -> nil
        end

      _other ->
        tool_meta = extract_tool_meta(item)
        raw = tool_meta |> get_any([{"raw", :raw}])

        if is_map(raw) and is_map(get_any(raw, [{"function", :function}])) do
          fn_spec = get_any(raw, [{"function", :function}]) || %{}

          name = fn_spec |> get_any([{"name", :name}]) |> to_string() |> String.trim()
          call_id = raw |> get_any([{"id", :id}]) |> to_string() |> String.trim()
          args = fn_spec |> get_any([{"arguments", :arguments}]) |> normalize_arguments_json()

          if name == "" do
            nil
          else
            %{
              "type" => "function_call",
              "id" =>
                "fc_" <>
                  if(call_id == "", do: Integer.to_string(History.sort_seq(item)), else: call_id),
              "call_id" => if(call_id == "", do: nil, else: call_id),
              "name" => name,
              "arguments" => args
            }
          end
        else
          name = tool_meta |> get_any([{"name", :name}]) |> to_string() |> String.trim()

          call_id =
            tool_meta
            |> get_any([{"tool_call_id", :tool_call_id}, {"call_id", :call_id}])
            |> to_string()
            |> String.trim()

          args = tool_meta |> get_any([{"arguments", :arguments}]) |> normalize_arguments_json()

          if name == "" do
            nil
          else
            %{
              "type" => "function_call",
              "id" =>
                "fc_" <>
                  if(call_id == "", do: Integer.to_string(History.sort_seq(item)), else: call_id),
              "call_id" => if(call_id == "", do: nil, else: call_id),
              "name" => name,
              "arguments" => args
            }
          end
        end
    end
  end

  defp item_for_tool_result(item) do
    case extract_responses_item(item) do
      %{} = responses_item ->
        case get_any(responses_item, [{"type", :type}]) do
          "function_call_output" ->
            sanitize_item(responses_item)

          "reasoning" ->
            nil

          _other ->
            nil
        end

      _other ->
        tool_meta = extract_tool_meta(item)

        call_id =
          tool_meta
          |> get_any([{"tool_call_id", :tool_call_id}, {"call_id", :call_id}])
          |> to_string()
          |> String.trim()

        text = History.item_text(item)

        %{
          "type" => "function_call_output",
          "id" =>
            "fco_" <>
              if(call_id == "", do: Integer.to_string(History.sort_seq(item)), else: call_id),
          "call_id" => if(call_id == "", do: nil, else: call_id),
          "output" => text
        }
    end
  end

  defp extract_responses_item(item) do
    item
    |> History.opaque_payloads()
    |> Enum.find_value(fn payload ->
      responses_item = get_any(payload, [{"responses_item", :responses_item}])

      cond do
        is_map(responses_item) ->
          Map.new(responses_item)

        is_map(payload) and
            MapSet.member?(
              @responses_item_types,
              to_string(get_any(payload, [{"type", :type}]) || "")
            ) ->
          Map.new(payload)

        true ->
          nil
      end
    end)
  end

  defp extract_tool_meta(item) do
    item
    |> History.opaque_payloads()
    |> Enum.find(%{}, fn payload ->
      not is_map(get_any(payload, [{"responses_item", :responses_item}])) and
        (Map.has_key?(payload, "tool_call_id") or Map.has_key?(payload, :tool_call_id) or
           Map.has_key?(payload, "call_id") or Map.has_key?(payload, :call_id) or
           Map.has_key?(payload, "raw") or Map.has_key?(payload, :raw) or
           Map.has_key?(payload, "name") or Map.has_key?(payload, :name))
    end)
  end

  defp valid_tool_call_refs(items) when is_list(items) do
    Enum.reduce(items, %{item_ids: MapSet.new(), call_ids: MapSet.new()}, fn item, acc ->
      case History.item_type(item) do
        :tool_result ->
          acc =
            case History.tool_call_item_id(item) do
              value when is_integer(value) -> Map.update!(acc, :item_ids, &MapSet.put(&1, value))
              _other -> acc
            end

          case item_for_tool_result(item) do
            %{} = map ->
              call_id =
                map
                |> Map.get("call_id", "")
                |> to_string()
                |> String.trim()

              if call_id == "" do
                acc
              else
                Map.update!(acc, :call_ids, &MapSet.put(&1, call_id))
              end

            _other ->
              acc
          end

        _other ->
          acc
      end
    end)
  end

  defp valid_tool_call_refs(_items), do: %{item_ids: MapSet.new(), call_ids: MapSet.new()}

  defp orphaned_tool_call?(item, %{} = map, %{item_ids: item_ids, call_ids: call_ids}) do
    item_id = History.item_id(item)

    if is_integer(item_id) and MapSet.size(item_ids) > 0 do
      not MapSet.member?(item_ids, item_id)
    else
      orphaned_tool_call_by_call_id?(map, call_ids)
    end
  end

  defp orphaned_tool_call?(item, %{} = map, valid_tool_call_ids)
       when is_struct(valid_tool_call_ids, MapSet) do
    orphaned_tool_call?(item, map, %{item_ids: MapSet.new(), call_ids: valid_tool_call_ids})
  end

  defp orphaned_tool_call?(_item, _map, _valid_tool_call_refs), do: false

  defp orphaned_tool_call_by_call_id?(%{} = map, valid_tool_call_ids) do
    call_id =
      map
      |> Map.get("call_id", "")
      |> to_string()
      |> String.trim()

    call_id != "" and not MapSet.member?(valid_tool_call_ids, call_id)
  end

  defp orphaned_tool_call_by_call_id?(_map, _valid_tool_call_ids), do: false

  defp last_answer_item_index(indexed_items) when is_list(indexed_items) do
    Enum.reduce(indexed_items, nil, fn {item, index}, acc ->
      case History.item_type(item) do
        :answer -> index
        _other -> acc
      end
    end)
  end

  defp fallback_answer_phase(item_index, last_answer_index)
       when is_integer(item_index) and is_integer(last_answer_index) do
    if item_index == last_answer_index, do: "final_answer", else: "commentary"
  end

  defp fallback_answer_phase(_item_index, _last_answer_index), do: "final_answer"

  defp synthesized_answer_item(text, phase) do
    %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "phase" => phase,
      "content" => [
        %{
          "type" => "output_text",
          "text" => text,
          "annotations" => []
        }
      ]
    }
  end

  defp sanitize_item(item) when is_map(item) do
    item_type = get_any(item, [{"type", :type}]) |> to_string()
    id = get_any(item, [{"id", :id}])

    if item_type == "reasoning" and is_binary(id) and String.starts_with?(id, "rs_") do
      Map.delete(Map.new(item), "id")
    else
      Map.new(item)
    end
  end

  defp sanitize_item(_other), do: nil

  defp normalize_arguments_json(nil), do: "{}"

  defp normalize_arguments_json(%{} = arguments) do
    Jason.encode!(arguments)
  end

  defp normalize_arguments_json(arguments) when is_binary(arguments) do
    arguments
    |> String.trim()
    |> case do
      "" -> "{}"
      text -> text
    end
  end

  defp normalize_arguments_json(other), do: to_string(other)

  defp get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn {string_key, atom_key} ->
      Map.get(map, string_key, Map.get(map, atom_key))
    end)
  end

  defp get_any(_map, _keys), do: nil
end
