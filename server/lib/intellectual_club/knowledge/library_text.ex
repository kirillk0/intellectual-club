defmodule IntellectualClub.Knowledge.LibraryText do
  @moduledoc """
  Lossless, model-visible slices and literal edits of knowledge block source.
  Hidden comment lines separate slices and are never replacement targets.
  """

  alias IntellectualClub.Knowledge.PromptContent

  @doc "Returns the exact visible fragments on one edit page and the total number of pages."
  @spec page(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [String.t()], pos_integer()} | {:error, String.t()}
  def page(content, page_number, chunk_size_tokens)
      when is_binary(content) and is_integer(page_number) and is_integer(chunk_size_tokens) and
             chunk_size_tokens > 0 do
    requested = if page_number == 0, do: 1, else: page_number
    # Match TokenCounter's 3.5 bytes/token, with room for at least one UTF-8 code point.
    capacity = max(4, div(chunk_size_tokens * 7, 2))

    {total, _remaining, fragments} =
      Enum.reduce(visible_ranges(content), {1, capacity, []}, fn {from, to}, state ->
        pack(binary_part(content, from, to - from), capacity, requested, state)
      end)

    if requested in 1..total do
      {:ok, Enum.reverse(fragments), total}
    else
      {:error, "Page out of range: #{requested} (total pages: #{total})"}
    end
  end

  @doc "Applies unique visible replacements in order, then appends text without modifying comments."
  @spec edit(String.t(), [map()], String.t() | nil) ::
          {:ok, String.t()} | {:error, atom(), String.t()}
  def edit(content, replacements, append_text)
      when is_binary(content) and is_list(replacements) and
             (is_binary(append_text) or is_nil(append_text)) do
    with {:ok, result} <- replace_all(content, replacements) do
      {:ok, append(result, append_text)}
    end
  end

  def edit(_content, _replacements, _append_text) do
    {:error, :invalid_arguments, "Expected a list of replacements and an optional append string."}
  end

  # Half-open ranges in the original binary, including each visible line's original terminator.
  defp visible_ranges(content) do
    size = byte_size(content)

    {from, to, ranges} =
      content
      |> :binary.split("\n", [:global])
      |> Enum.reduce({0, 0, []}, fn line, {from, at, ranges} ->
        next = min(at + byte_size(line) + 1, size)

        if PromptContent.comment_line?(line) do
          {next, next, add_range(ranges, from, at)}
        else
          {from, next, ranges}
        end
      end)

    Enum.reverse(add_range(ranges, from, to))
  end

  defp add_range(ranges, from, to) when from < to, do: [{from, to} | ranges]
  defp add_range(ranges, _from, _to), do: ranges

  # Only retain slices for the requested page, not the text of every page.
  defp pack("", _capacity, _requested, state), do: state

  defp pack(fragment, capacity, requested, {number, remaining, fragments}) do
    case prefix_size(fragment, remaining) do
      0 ->
        pack(fragment, capacity, requested, {number + 1, capacity, fragments})

      size ->
        <<slice::binary-size(^size), rest::binary>> = fragment
        fragments = if number == requested, do: [slice | fragments], else: fragments
        pack(rest, capacity, requested, {number, remaining - size, fragments})
    end
  end

  defp prefix_size(text, limit) when byte_size(text) <= limit, do: byte_size(text)
  defp prefix_size(_text, 0), do: 0

  defp prefix_size(text, limit) do
    case :binary.at(text, limit) do
      byte when byte in 0x80..0xBF -> prefix_size(text, limit - 1)
      ?\n -> if :binary.at(text, limit - 1) == ?\r, do: limit - 1, else: limit
      _other -> limit
    end
  end

  defp replace_all(content, []), do: {:ok, content}

  defp replace_all(content, [%{"old_text" => old, "new_text" => new} = change | rest])
       when map_size(change) == 2 and is_binary(old) and old != "" and is_binary(new) do
    with {:ok, {at, visible_end}} <- unique_match(content, old) do
      size = byte_size(old)
      <<head::binary-size(^at), _old::binary-size(^size), tail::binary>> = content
      last = if new == "", do: head, else: new

      if at + size == visible_end and visible_end < byte_size(content) and last != "" and
           not String.ends_with?(last, "\n") do
        {:error, :invalid_arguments, "Replacement must keep the newline before a hidden line."}
      else
        replace_all(head <> new <> tail, rest)
      end
    end
  end

  defp replace_all(_content, _invalid) do
    {:error, :invalid_arguments,
     "Each replacement must contain a non-empty old_text and a string new_text."}
  end

  defp unique_match(content, old) do
    pattern = :binary.compile_pattern(old)

    visible_ranges(content)
    |> Enum.reduce_while(:nomatch, fn {from, to}, found ->
      case :binary.match(content, pattern, scope: {from, to - from}) do
        :nomatch ->
          {:cont, found}

        {at, _length} ->
          # Start one byte later so overlapping occurrences also count as ambiguous.
          if found != :nomatch or
               :binary.match(content, pattern, scope: {at + 1, to - at - 1}) != :nomatch do
            {:halt, :ambiguous}
          else
            {:cont, {at, to}}
          end
      end
    end)
    |> case do
      :nomatch -> {:error, :text_not_found, "old_text was not found in a visible fragment."}
      :ambiguous -> {:error, :ambiguous_match, "old_text matches more than one visible position."}
      match -> {:ok, match}
    end
  end

  defp append(content, suffix) when suffix in [nil, ""], do: content

  defp append(content, suffix) do
    # An unterminated final comment must not absorb the appended text.
    if not String.starts_with?(suffix, ["\n", "\r\n"]) and
         PromptContent.comment_line?(List.last(:binary.split(content, "\n", [:global]))) do
      content <> "\n" <> suffix
    else
      content <> suffix
    end
  end
end
