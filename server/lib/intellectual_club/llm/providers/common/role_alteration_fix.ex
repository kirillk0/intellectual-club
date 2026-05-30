defmodule IntellectualClub.Llm.Providers.Common.RoleAlterationFix do
  @moduledoc """
  Normalizes provider payload message roles for models that require user turns.
  """

  @default_separator "\n\n"
  @assistant_user_roles ["user", "assistant"]
  @leading_roles ["system", "developer"]

  @spec fix_chat_messages([term()], keyword()) :: [term()]
  def fix_chat_messages(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    separator = Keyword.get(opts, :separator, @default_separator)

    messages
    |> merge_adjacent(&chat_role/1, &merge_chat_message(&1, &2, &3, separator))
    |> ensure_user_boundaries(&chat_role/1, &empty_chat_user_message/0)
  end

  @spec fix_responses_input_items([term()], keyword()) :: [term()]
  def fix_responses_input_items(items, opts \\ []) when is_list(items) and is_list(opts) do
    separator = Keyword.get(opts, :separator, @default_separator)

    items
    |> merge_adjacent(&responses_message_role/1, &merge_responses_message(&1, &2, &3, separator))
    |> ensure_user_boundaries(&responses_message_role/1, &empty_responses_user_item/0)
  end

  defp merge_adjacent(items, role_fun, merge_fun) do
    items
    |> Enum.reduce([], fn item, acc ->
      role = role_fun.(item)

      case acc do
        [previous | rest] when role in @assistant_user_roles ->
          previous_role = role_fun.(previous)

          if previous_role == role do
            [merge_fun.(previous, item, role) | rest]
          else
            [item | acc]
          end

        _other ->
          [item | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp ensure_user_boundaries(items, role_fun, empty_user_fun) do
    {leading, rest} = Enum.split_while(items, &(role_fun.(&1) in @leading_roles))

    rest =
      case rest do
        [] -> [empty_user_fun.()]
        [first | _] -> if role_fun.(first) == "user", do: rest, else: [empty_user_fun.() | rest]
      end

    fixed = leading ++ rest

    case List.last(fixed) do
      nil -> [empty_user_fun.()]
      last -> if role_fun.(last) == "user", do: fixed, else: fixed ++ [empty_user_fun.()]
    end
  end

  defp merge_chat_message(left, right, role, separator) do
    left
    |> merge_message_base(right)
    |> put_merged_content(left, right, merge_chat_content(left, right, role, separator))
    |> put_merged_tool_calls(left, right)
  end

  defp merge_responses_message(left, right, role, separator) do
    left
    |> merge_message_base(right)
    |> put_merged_content(left, right, merge_responses_content(left, right, role, separator))
  end

  defp merge_message_base(left, right) when is_map(left) and is_map(right) do
    Map.merge(Map.new(right), Map.new(left))
  end

  defp merge_message_base(left, _right) when is_map(left), do: Map.new(left)
  defp merge_message_base(_left, right) when is_map(right), do: Map.new(right)
  defp merge_message_base(left, _right), do: left

  defp merge_chat_content(left, right, _role, separator) do
    merge_content(content_of(left), content_of(right), separator, &chat_text_block/1)
  end

  defp merge_responses_content(left, right, role, separator) do
    text_block_fun =
      case role do
        "assistant" -> &responses_output_text_block/1
        _other -> &responses_input_text_block/1
      end

    merge_content(content_of(left), content_of(right), separator, text_block_fun)
  end

  defp merge_content(left, right, separator, text_block_fun)
       when is_list(left) or is_list(right) or is_map(left) or is_map(right) do
    left_blocks = content_blocks(left, text_block_fun)
    right_blocks = content_blocks(right, text_block_fun)

    cond do
      blocks_present?(left_blocks) and blocks_present?(right_blocks) ->
        left_blocks ++ [text_block_fun.(separator)] ++ right_blocks

      blocks_present?(left_blocks) ->
        left_blocks

      blocks_present?(right_blocks) ->
        right_blocks

      true ->
        []
    end
  end

  defp merge_content(left, right, separator, _text_block_fun) do
    merge_text(text_content(left), text_content(right), separator)
  end

  defp merge_text("", "", _separator), do: ""
  defp merge_text("", right, _separator), do: right
  defp merge_text(left, "", _separator), do: left
  defp merge_text(left, right, separator), do: left <> separator <> right

  defp content_blocks(nil, _text_block_fun), do: []

  defp content_blocks(content, text_block_fun) when is_binary(content) do
    if content == "", do: [], else: [text_block_fun.(content)]
  end

  defp content_blocks(content, _text_block_fun) when is_map(content), do: [Map.new(content)]

  defp content_blocks(content, text_block_fun) when is_list(content) do
    Enum.flat_map(content, fn
      %{} = block ->
        [Map.new(block)]

      text when is_binary(text) ->
        if text == "", do: [], else: [text_block_fun.(text)]

      nil ->
        []

      other ->
        [text_block_fun.(to_string(other))]
    end)
  end

  defp content_blocks(content, text_block_fun), do: [text_block_fun.(to_string(content))]

  defp blocks_present?(blocks) when is_list(blocks) do
    Enum.any?(blocks, &block_present?/1)
  end

  defp block_present?(%{} = block) do
    text = Map.get(block, "text", Map.get(block, :text))
    content = Map.get(block, "content", Map.get(block, :content))

    cond do
      is_binary(text) -> text != ""
      is_binary(content) -> content != ""
      true -> true
    end
  end

  defp block_present?(text) when is_binary(text), do: text != ""
  defp block_present?(nil), do: false
  defp block_present?(_other), do: true

  defp text_content(nil), do: ""
  defp text_content(content) when is_binary(content), do: content
  defp text_content(content), do: to_string(content)

  defp put_merged_content(message, left, right, content) when is_map(message) do
    key = content_key(left, right)

    message
    |> Map.delete("content")
    |> Map.delete(:content)
    |> Map.put(key, content)
  end

  defp put_merged_content(message, _left, _right, _content), do: message

  defp put_merged_tool_calls(message, left, right) when is_map(message) do
    tool_calls = tool_calls_of(left) ++ tool_calls_of(right)

    if tool_calls == [] do
      message
    else
      key = tool_calls_key(left, right)

      message
      |> Map.delete("tool_calls")
      |> Map.delete(:tool_calls)
      |> Map.put(key, tool_calls)
    end
  end

  defp put_merged_tool_calls(message, _left, _right), do: message

  defp content_key(left, right) do
    cond do
      is_map(left) and Map.has_key?(left, :content) and not Map.has_key?(left, "content") ->
        :content

      is_map(right) and Map.has_key?(right, :content) and not Map.has_key?(right, "content") ->
        :content

      true ->
        "content"
    end
  end

  defp tool_calls_key(left, right) do
    cond do
      is_map(left) and Map.has_key?(left, :tool_calls) and not Map.has_key?(left, "tool_calls") ->
        :tool_calls

      is_map(right) and Map.has_key?(right, :tool_calls) and not Map.has_key?(right, "tool_calls") ->
        :tool_calls

      true ->
        "tool_calls"
    end
  end

  defp content_of(%{} = message), do: Map.get(message, "content", Map.get(message, :content))
  defp content_of(_message), do: nil

  defp tool_calls_of(%{} = message) do
    case Map.get(message, "tool_calls", Map.get(message, :tool_calls)) do
      calls when is_list(calls) -> calls
      _other -> []
    end
  end

  defp tool_calls_of(_message), do: []

  defp chat_role(message), do: message |> role_value() |> normalize_role()

  defp responses_message_role(%{} = item) do
    type = item |> Map.get("type", Map.get(item, :type)) |> normalize_type()

    if type in ["", "message"] do
      item |> role_value() |> normalize_role()
    else
      nil
    end
  end

  defp responses_message_role(_item), do: nil

  defp role_value(%{} = message), do: Map.get(message, "role", Map.get(message, :role))
  defp role_value(_message), do: nil

  defp normalize_role(role) when is_atom(role), do: role |> Atom.to_string() |> normalize_role()
  defp normalize_role(role) when is_binary(role), do: role |> String.trim()
  defp normalize_role(_role), do: nil

  defp normalize_type(type) when is_atom(type), do: type |> Atom.to_string() |> normalize_type()
  defp normalize_type(type) when is_binary(type), do: String.trim(type)
  defp normalize_type(_type), do: ""

  defp chat_text_block(text), do: %{"type" => "text", "text" => text}
  defp responses_input_text_block(text), do: %{"type" => "input_text", "text" => text}

  defp responses_output_text_block(text) do
    %{"type" => "output_text", "text" => text, "annotations" => []}
  end

  defp empty_chat_user_message, do: %{"role" => "user", "content" => ""}

  defp empty_responses_user_item do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => ""}]
    }
  end
end
