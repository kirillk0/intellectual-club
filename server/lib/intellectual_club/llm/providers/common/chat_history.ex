defmodule IntellectualClub.Llm.Providers.Common.ChatHistory do
  @moduledoc """
  Projects canonical persisted history into Chat Completions messages.
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
  Builds Chat Completions-compatible history from a linear message branch.
  """
  def build_messages(history, opts \\ []) when is_list(history) and is_list(opts) do
    history
    |> Enum.flat_map(&messages_from_history_entry(&1, opts))
    |> Enum.flat_map(&normalize_payload_message/1)
  end

  defp messages_from_history_entry(message, opts) do
    if History.trace_message?(message) do
      case History.message_role(message) do
        "user" ->
          input_contents = History.project_contents_for_item_type(message, :input)

          [
            %{
              "role" => "user",
              "content" => Media.chat_message_content(input_contents, opts)
            }
          ]

        "assistant" ->
          emitted =
            message
            |> History.steps()
            |> Enum.sort_by(&History.sort_seq/1)
            |> Enum.flat_map(&messages_from_step(&1, opts))

          if emitted == [] do
            fallback_text = History.project_text_for_item_type(message, :answer)

            if String.trim(fallback_text) == "" do
              []
            else
              [%{"role" => "assistant", "content" => fallback_text}]
            end
          else
            emitted
          end

        _other ->
          []
      end
    else
      case History.normalize_message(message) do
        nil -> []
        normalized -> [normalized]
      end
    end
  end

  defp normalize_payload_message(%{} = message) do
    role =
      message
      |> Map.get("role", Map.get(message, :role))
      |> normalize_chat_role()

    case role do
      "user" ->
        content = Map.get(message, "content", Map.get(message, :content))

        [
          Map.put(Map.new(message), "role", "user")
          |> Map.put("content", History.normalize_content(content))
        ]

      "assistant" ->
        content = Map.get(message, "content", Map.get(message, :content))

        [
          Map.put(Map.new(message), "role", "assistant")
          |> Map.put("content", History.normalize_content(content))
        ]

      "tool" ->
        content = Map.get(message, "content", Map.get(message, :content))

        [
          Map.put(Map.new(message), "role", "tool")
          |> Map.put("content", History.normalize_content(content))
        ]

      _other ->
        case History.normalize_message(message) do
          nil -> []
          normalized -> [normalized]
        end
    end
  end

  defp normalize_payload_message(_other), do: []

  defp messages_from_step(step, opts) do
    items = step |> History.items() |> Enum.sort_by(&History.sort_seq/1)

    {answer_parts, tool_calls, tool_results} =
      Enum.reduce(items, {[], [], []}, fn item, {answers_acc, calls_acc, results_acc} ->
        case History.item_type(item) do
          :answer ->
            {[History.item_text(item) | answers_acc], calls_acc, results_acc}

          :tool_call ->
            call =
              case tool_call_payload(item) do
                %{} = payload -> payload
                _other -> nil
              end

            next_calls = if is_map(call), do: [call | calls_acc], else: calls_acc
            {answers_acc, next_calls, results_acc}

          :tool_result ->
            {answers_acc, calls_acc, [tool_result_payload(item) | results_acc]}

          :artifact ->
            {answers_acc, calls_acc, results_acc}

          :reasoning ->
            {answers_acc, calls_acc, results_acc}

          _other ->
            {answers_acc, calls_acc, results_acc}
        end
      end)

    answer_text =
      answer_parts
      |> Enum.reverse()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    tool_calls = Enum.reverse(tool_calls)
    tool_results = Enum.reverse(tool_results)

    assistant_message =
      %{"role" => "assistant", "content" => answer_text}
      |> maybe_put("tool_calls", tool_calls, tool_calls != [])

    tool_call_ids =
      tool_calls
      |> Enum.map(fn call ->
        call
        |> get_any([{"id", :id}])
        |> to_string()
        |> String.trim()
      end)

    tool_messages =
      tool_results
      |> Enum.with_index()
      |> Enum.flat_map(fn {result, idx} ->
        text =
          result
          |> get_any([{"content", :content}, {"text", :text}])
          |> to_string()

        call_id =
          result
          |> get_any([{"tool_call_id", :tool_call_id}, {"call_id", :call_id}])
          |> to_string()
          |> String.trim()
          |> case do
            "" -> Enum.at(tool_call_ids, idx) |> to_string() |> String.trim()
            value -> value
          end

        text =
          if String.trim(text) == "" do
            "(tool returned no output)"
          else
            text
          end

        base_messages =
          if call_id == "" do
            []
          else
            [
              %{"role" => "tool", "content" => text, "tool_call_id" => call_id}
            ]
          end

        base_messages ++
          Media.media_followup_messages(Map.get(result, "media_contents", []), opts)
      end)

    if String.trim(answer_text) == "" and tool_calls == [] do
      tool_messages
    else
      [assistant_message | tool_messages]
    end
  end

  defp tool_call_payload(item) do
    responses_item = extract_responses_item(item)

    cond do
      is_map(responses_item) and get_any(responses_item, [{"type", :type}]) == "function_call" ->
        call_id =
          responses_item
          |> get_any([{"call_id", :call_id}, {"id", :id}])
          |> to_string()
          |> String.trim()

        name = responses_item |> get_any([{"name", :name}]) |> to_string() |> String.trim()

        arguments =
          responses_item
          |> get_any([{"arguments", :arguments}])
          |> normalize_arguments_json()

        if name == "" do
          nil
        else
          %{
            "id" =>
              if(call_id == "",
                do: "call_" <> Integer.to_string(History.sort_seq(item)),
                else: call_id
              ),
            "type" => "function",
            "function" => %{
              "name" => name,
              "arguments" => arguments
            }
          }
        end

      true ->
        tool_meta = extract_tool_meta(item)
        raw = tool_meta |> get_any([{"raw", :raw}])

        if is_map(raw) and is_map(get_any(raw, [{"function", :function}])) do
          call_id =
            raw
            |> get_any([{"id", :id}])
            |> to_string()
            |> String.trim()

          call_id =
            if call_id == "" do
              tool_meta
              |> get_any([{"tool_call_id", :tool_call_id}, {"call_id", :call_id}])
              |> to_string()
              |> String.trim()
            else
              call_id
            end

          if call_id == "" do
            raw
          else
            Map.put(Map.new(raw), "id", call_id)
          end
        else
          call_id =
            tool_meta
            |> get_any([{"tool_call_id", :tool_call_id}, {"call_id", :call_id}])
            |> to_string()
            |> String.trim()

          name = tool_meta |> get_any([{"name", :name}]) |> to_string() |> String.trim()

          arguments =
            tool_meta |> get_any([{"arguments", :arguments}]) |> normalize_arguments_json()

          if name == "" do
            nil
          else
            %{
              "id" =>
                if(call_id == "",
                  do: "call_" <> Integer.to_string(History.sort_seq(item)),
                  else: call_id
                ),
              "type" => "function",
              "function" => %{
                "name" => name,
                "arguments" => arguments
              }
            }
          end
        end
    end
  end

  defp tool_result_payload(item) do
    responses_item = extract_responses_item(item)
    tool_meta = extract_tool_meta(item)

    text =
      case responses_item do
        %{} ->
          responses_output_text(responses_item)

        _other ->
          History.item_text(item)
      end

    text =
      if String.trim(text) == "" do
        History.item_text(item)
      else
        text
      end

    call_id =
      case responses_item do
        %{} ->
          responses_item
          |> get_any([{"call_id", :call_id}])
          |> to_string()
          |> String.trim()

        _other ->
          ""
      end
      |> case do
        "" ->
          tool_meta
          |> get_any([{"tool_call_id", :tool_call_id}, {"call_id", :call_id}])
          |> to_string()
          |> String.trim()

        value ->
          value
      end

    %{
      "content" => text,
      "tool_call_id" => call_id,
      "media_contents" => History.media_contents_for_item(item)
    }
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

  defp responses_output_text(item_map) when is_map(item_map) do
    output = get_any(item_map, [{"output", :output}])

    cond do
      is_binary(output) ->
        output

      is_list(output) ->
        output
        |> Enum.map(&responses_content_part_text/1)
        |> Enum.filter(&is_binary/1)
        |> Enum.join("")

      is_nil(output) ->
        ""

      true ->
        Jason.encode!(%{"output" => output})
    end
  end

  defp responses_output_text(_other), do: ""

  defp responses_content_part_text(part) when is_map(part) do
    type = get_any(part, [{"type", :type}])

    cond do
      type in ["output_text", "input_text", "text", "summary_text", "reasoning_text"] ->
        get_any(part, [{"text", :text}])

      type == "refusal" ->
        get_any(part, [{"refusal", :refusal}])

      true ->
        nil
    end
  end

  defp responses_content_part_text(_other), do: nil

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

  defp normalize_chat_role(role) when is_atom(role),
    do: role |> Atom.to_string() |> normalize_chat_role()

  defp normalize_chat_role("user"), do: "user"
  defp normalize_chat_role("assistant"), do: "assistant"
  defp normalize_chat_role("tool"), do: "tool"
  defp normalize_chat_role(_other), do: nil

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn {string_key, atom_key} ->
      Map.get(map, string_key, Map.get(map, atom_key))
    end)
  end

  defp get_any(_map, _keys), do: nil
end
