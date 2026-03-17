defmodule IntellectualClub.Generation.History do
  @moduledoc """
  Provider-independent helpers for preparing model history.

  History is reconstructed from persisted trace items:
  - `input` for user messages
  - `answer`, `tool_call`, `tool_result` for assistant messages

  `reasoning` items are intentionally excluded from cross-message history.
  """

  alias IntellectualClub.Chat.Media

  @responses_item_types MapSet.new([
                          "message",
                          "reasoning",
                          "function_call",
                          "function_call_output"
                        ])
  @allowed_roles ["user", "assistant"]

  @doc """
  Builds model-ready messages by prepending an optional system prompt to history.
  """
  def build_messages(history, opts \\ []) when is_list(history) and is_list(opts) do
    history_mode = Keyword.get(opts, :history_mode, :agent)
    supports_image_input = Keyword.get(opts, :supports_image_input, false)

    system_prompt =
      opts
      |> Keyword.get(:system_prompt, "")
      |> to_string()
      |> String.trim()

    history_messages =
      case history_mode do
        :responses ->
          build_responses_input_items(history, supports_image_input: supports_image_input)

        _other ->
          build_chat_completions_history_messages(history,
            supports_image_input: supports_image_input
          )
      end

    if system_prompt == "" do
      history_messages
    else
      [%{"role" => "system", "content" => system_prompt} | history_messages]
    end
  end

  @doc """
  Builds history payload for the selected history mode.
  """
  def build_history_messages(history, :responses), do: build_responses_input_items(history)
  def build_history_messages(history, :chat), do: build_chat_completions_history_messages(history)

  def build_history_messages(history, :agent),
    do: build_chat_completions_history_messages(history)

  def build_history_messages(history, _other),
    do: build_chat_completions_history_messages(history)

  @doc """
  Builds chat-completions compatible history from a linear message branch.
  """
  def build_chat_completions_history_messages(history, opts \\ [])
      when is_list(history) and is_list(opts) do
    history
    |> Enum.flat_map(&chat_messages_from_message(&1, opts))
    |> Enum.flat_map(&normalize_chat_payload_message/1)
  end

  @doc """
  Builds Responses API `input[]` items from a linear message branch.
  """
  def build_responses_input_items(history, opts \\ []) when is_list(history) and is_list(opts) do
    history
    |> Enum.flat_map(&responses_items_from_message(&1, opts))
    |> Enum.flat_map(fn
      nil -> []
      %{} = item -> [item]
      _other -> []
    end)
  end

  defp normalize_history_message(%{role: role, content: content}) do
    role = normalize_role(role)

    if role in @allowed_roles do
      %{"role" => role, "content" => normalize_content(content)}
    else
      nil
    end
  end

  defp normalize_history_message(%{"role" => role, "content" => content}) do
    role = normalize_role(role)

    if role in @allowed_roles do
      %{"role" => role, "content" => normalize_content(content)}
    else
      nil
    end
  end

  defp normalize_history_message(_other), do: nil

  defp normalize_chat_payload_message(%{} = message) do
    role =
      message
      |> Map.get("role", Map.get(message, :role))
      |> normalize_chat_role()

    case role do
      "user" ->
        content = Map.get(message, "content", Map.get(message, :content))

        [
          Map.put(Map.new(message), "role", "user")
          |> Map.put("content", normalize_content(content))
        ]

      "assistant" ->
        content = Map.get(message, "content", Map.get(message, :content))

        [
          Map.put(Map.new(message), "role", "assistant")
          |> Map.put("content", normalize_content(content))
        ]

      "tool" ->
        content = Map.get(message, "content", Map.get(message, :content))

        [
          Map.put(Map.new(message), "role", "tool")
          |> Map.put("content", normalize_content(content))
        ]

      _other ->
        case normalize_history_message(message) do
          nil -> []
          normalized -> [normalized]
        end
    end
  end

  defp normalize_chat_payload_message(_other), do: []

  defp chat_messages_from_message(message, opts) do
    if trace_message?(message) do
      role = normalize_role(Map.get(message, :role, Map.get(message, "role")))

      case role do
        "user" ->
          input_contents = project_contents_for_item_type(message, :input)

          [
            %{
              "role" => "user",
              "content" => Media.chat_message_content(input_contents, opts)
            }
          ]

        "assistant" ->
          emitted =
            message
            |> steps_of()
            |> Enum.sort_by(&sort_seq/1)
            |> Enum.flat_map(&chat_messages_from_step(&1, opts))

          if emitted == [] do
            fallback_text = project_text_for_item_type(message, :answer)

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
      case normalize_history_message(message) do
        nil -> []
        normalized -> [normalized]
      end
    end
  end

  defp chat_messages_from_step(step, opts) do
    items = step |> items_of() |> Enum.sort_by(&sort_seq/1)

    {answer_parts, tool_calls, tool_results} =
      Enum.reduce(items, {[], [], []}, fn item, {answers_acc, calls_acc, results_acc} ->
        case normalize_item_type(Map.get(item, :type, Map.get(item, "type"))) do
          :answer ->
            {[item_text(item) | answers_acc], calls_acc, results_acc}

          :tool_call ->
            call =
              case chat_tool_call_payload(item) do
                %{} = payload -> payload
                _ -> nil
              end

            next_calls = if is_map(call), do: [call | calls_acc], else: calls_acc
            {answers_acc, next_calls, results_acc}

          :tool_result ->
            {answers_acc, calls_acc, [chat_tool_result_payload(item) | results_acc]}

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

  defp chat_tool_call_payload(item) do
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
              if(call_id == "", do: "call_" <> Integer.to_string(sort_seq(item)), else: call_id),
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
                if(call_id == "", do: "call_" <> Integer.to_string(sort_seq(item)), else: call_id),
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

  defp chat_tool_result_payload(item) do
    responses_item = extract_responses_item(item)
    tool_meta = extract_tool_meta(item)

    text =
      case responses_item do
        %{} ->
          responses_output_text(responses_item)

        _ ->
          item_text(item)
      end

    text =
      if String.trim(text) == "" do
        item_text(item)
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

        _ ->
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
      "media_contents" => media_contents_for_item(item)
    }
  end

  defp responses_items_from_message(message, opts) do
    if trace_message?(message) do
      role = normalize_role(Map.get(message, :role, Map.get(message, "role")))

      case role do
        "user" ->
          input_contents = project_contents_for_item_type(message, :input)

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
            |> steps_of()
            |> Enum.sort_by(&sort_seq/1)
            |> Enum.flat_map(fn step ->
              step
              |> items_of()
              |> Enum.sort_by(&sort_seq/1)
            end)

          indexed_items = Enum.with_index(items)
          last_answer_index = last_answer_item_index(indexed_items)

          out =
            Enum.flat_map(indexed_items, fn {item, item_index} ->
              case normalize_item_type(Map.get(item, :type, Map.get(item, "type"))) do
                :reasoning ->
                  []

                :answer ->
                  case responses_item_for_answer(item) do
                    nil ->
                      text = item_text(item)

                      if String.trim(text) == "" do
                        []
                      else
                        [
                          synthesized_responses_answer_item(
                            text,
                            fallback_answer_phase(item_index, last_answer_index)
                          )
                        ]
                      end

                    %{} = map ->
                      [map]
                  end

                :tool_call ->
                  case responses_item_for_tool_call(item) do
                    nil -> []
                    %{} = map -> [map]
                  end

                :tool_result ->
                  out =
                    case responses_item_for_tool_result(item) do
                      nil -> []
                      %{} = map -> [map]
                    end

                  out ++ Media.media_followup_input_items(media_contents_for_item(item), opts)

                :artifact ->
                  []

                _other ->
                  []
              end
            end)

          if out == [] do
            fallback_text = project_text_for_item_type(message, :answer)

            [
              synthesized_responses_answer_item(fallback_text, "final_answer")
            ]
          else
            out
          end

        _other ->
          []
      end
    else
      case normalize_history_message(message) do
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

  defp responses_item_for_answer(item) do
    case extract_responses_item(item) do
      %{} = responses_item ->
        case get_any(responses_item, [{"type", :type}]) do
          "message" -> sanitize_responses_item(responses_item)
          "reasoning" -> nil
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp responses_item_for_tool_call(item) do
    case extract_responses_item(item) do
      %{} = responses_item ->
        case get_any(responses_item, [{"type", :type}]) do
          "function_call" -> sanitize_responses_item(responses_item)
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
                "fc_" <> if(call_id == "", do: Integer.to_string(sort_seq(item)), else: call_id),
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
                "fc_" <> if(call_id == "", do: Integer.to_string(sort_seq(item)), else: call_id),
              "call_id" => if(call_id == "", do: nil, else: call_id),
              "name" => name,
              "arguments" => args
            }
          end
        end
    end
  end

  defp responses_item_for_tool_result(item) do
    case extract_responses_item(item) do
      %{} = responses_item ->
        case get_any(responses_item, [{"type", :type}]) do
          "function_call_output" ->
            sanitize_responses_item(responses_item)

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

        text = item_text(item)

        %{
          "type" => "function_call_output",
          "id" =>
            "fco_" <> if(call_id == "", do: Integer.to_string(sort_seq(item)), else: call_id),
          "call_id" => if(call_id == "", do: nil, else: call_id),
          "output" => text
        }
    end
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

  defp extract_responses_item(item) do
    item
    |> opaque_payloads()
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
    |> opaque_payloads()
    |> Enum.find(%{}, fn payload ->
      not is_map(get_any(payload, [{"responses_item", :responses_item}])) and
        (Map.has_key?(payload, "tool_call_id") or Map.has_key?(payload, :tool_call_id) or
           Map.has_key?(payload, "call_id") or Map.has_key?(payload, :call_id) or
           Map.has_key?(payload, "raw") or Map.has_key?(payload, :raw) or
           Map.has_key?(payload, "name") or Map.has_key?(payload, :name))
    end)
  end

  defp opaque_payloads(item) do
    item
    |> contents_of()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn content ->
      kind = normalize_kind(Map.get(content, :kind, Map.get(content, "kind")))
      content_json = Map.get(content, :content_json, Map.get(content, "content_json"))

      if kind == :opaque and is_map(content_json) do
        [Map.new(content_json)]
      else
        []
      end
    end)
  end

  defp project_text_for_item_type(message, wanted_type) do
    message
    |> steps_of()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn step ->
      step
      |> items_of()
      |> Enum.sort_by(&sort_seq/1)
    end)
    |> Enum.filter(fn item ->
      normalize_item_type(Map.get(item, :type, Map.get(item, "type"))) == wanted_type
    end)
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp project_contents_for_item_type(message, wanted_type) do
    message
    |> steps_of()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn step ->
      step
      |> items_of()
      |> Enum.sort_by(&sort_seq/1)
    end)
    |> Enum.filter(fn item ->
      normalize_item_type(Map.get(item, :type, Map.get(item, "type"))) == wanted_type
    end)
    |> Enum.flat_map(&contents_of/1)
    |> Enum.sort_by(&sort_seq/1)
  end

  defp item_text(item) do
    item
    |> contents_of()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn content ->
      kind = normalize_kind(Map.get(content, :kind, Map.get(content, "kind")))
      text = Map.get(content, :content_text, Map.get(content, "content_text"))

      if kind == :text and is_binary(text) do
        [text]
      else
        []
      end
    end)
    |> Enum.join("")
  end

  defp trace_message?(message) when is_map(message) do
    steps = Map.get(message, :steps, Map.get(message, "steps"))
    is_list(steps)
  end

  defp trace_message?(_other), do: false

  defp steps_of(message) when is_map(message) do
    Map.get(message, :steps, Map.get(message, "steps")) || []
  end

  defp steps_of(_other), do: []

  defp items_of(step) when is_map(step) do
    Map.get(step, :items, Map.get(step, "items")) || []
  end

  defp items_of(_other), do: []

  defp contents_of(item) when is_map(item) do
    Map.get(item, :contents, Map.get(item, "contents")) || []
  end

  defp contents_of(_other), do: []

  defp normalize_item_type(value) when is_binary(value) do
    case value do
      "input" -> :input
      "answer" -> :answer
      "reasoning" -> :reasoning
      "tool_call" -> :tool_call
      "tool_result" -> :tool_result
      "artifact" -> :artifact
      _ -> :other
    end
  end

  defp normalize_item_type(value) when is_atom(value),
    do: normalize_item_type(Atom.to_string(value))

  defp normalize_item_type(_other), do: :other

  defp normalize_kind(value) when is_binary(value) do
    case value do
      "text" -> :text
      "opaque" -> :opaque
      "media" -> :media
      _ -> :other
    end
  end

  defp normalize_kind(value) when is_atom(value), do: normalize_kind(Atom.to_string(value))
  defp normalize_kind(_other), do: :other

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

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

  defp last_answer_item_index(indexed_items) when is_list(indexed_items) do
    Enum.reduce(indexed_items, nil, fn {item, index}, acc ->
      case normalize_item_type(Map.get(item, :type, Map.get(item, "type"))) do
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

  defp synthesized_responses_answer_item(text, phase) do
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

  defp sanitize_responses_item(item) when is_map(item) do
    item_type = get_any(item, [{"type", :type}]) |> to_string()
    id = get_any(item, [{"id", :id}])

    if item_type == "reasoning" and is_binary(id) and String.starts_with?(id, "rs_") do
      Map.delete(Map.new(item), "id")
    else
      Map.new(item)
    end
  end

  defp sanitize_responses_item(_other), do: nil

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn {string_key, atom_key} ->
      Map.get(map, string_key, Map.get(map, atom_key))
    end)
  end

  defp get_any(_map, _keys), do: nil

  defp normalize_role(role) when is_atom(role), do: role |> Atom.to_string() |> normalize_role()
  defp normalize_role("user"), do: "user"
  defp normalize_role("assistant"), do: "assistant"
  defp normalize_role(_other), do: nil

  defp normalize_chat_role(role) when is_atom(role),
    do: role |> Atom.to_string() |> normalize_chat_role()

  defp normalize_chat_role("user"), do: "user"
  defp normalize_chat_role("assistant"), do: "assistant"
  defp normalize_chat_role("tool"), do: "tool"
  defp normalize_chat_role(_other), do: nil

  defp normalize_content(nil), do: ""
  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_list(content), do: Enum.map(content, &Map.new/1)
  defp normalize_content(content) when is_map(content), do: Map.new(content)
  defp normalize_content(content), do: to_string(content)

  defp media_contents_for_item(item) do
    item
    |> contents_of()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.filter(&Media.media_content?/1)
  end
end
