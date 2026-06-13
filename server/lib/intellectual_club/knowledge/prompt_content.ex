defmodule IntellectualClub.Knowledge.PromptContent do
  @moduledoc """
  Helpers for rendering knowledge block content inside prompts.
  """

  alias IntellectualClub.Chat.Media

  @comment_prefix "//// "

  @doc """
  Removes comment lines from knowledge block content before prompt rendering.
  """
  def strip_comments(content) when is_binary(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.reject(&comment_line?/1)
    |> Enum.join("\n")
  end

  def strip_comments(_content), do: ""

  @doc """
  Renders a knowledge block title, body, and file attachment placeholders.
  """
  def render_block(nil), do: ""

  def render_block(block) do
    title = block |> Map.get(:name, "") |> to_string() |> String.trim()

    body =
      block
      |> Map.get(:content, "")
      |> strip_comments()

    attachments = attachment_placeholders(block)

    parts =
      []
      |> maybe_append("# #{title}", title != "")
      |> maybe_append(body, body != "")
      |> maybe_append(attachments, attachments != "")

    case Enum.join(parts, "\n") do
      "" -> ""
      rendered -> rendered <> "\n\n---\n"
    end
  end

  @doc """
  Returns model-visible file placeholder lines for knowledge block attachments.
  """
  def attachment_placeholders(block) when is_map(block) do
    block
    |> Map.get(:file_bindings, [])
    |> normalize_bindings()
    |> Enum.filter(&binding_enabled?/1)
    |> Enum.sort_by(&binding_sort_key/1)
    |> Enum.flat_map(&placeholder_for_binding/1)
    |> Enum.join("\n")
  end

  def attachment_placeholders(_block), do: ""

  defp comment_line?(line) when is_binary(line) do
    String.starts_with?(line, @comment_prefix)
  end

  defp comment_line?(_line), do: false

  defp normalize_bindings(%Ash.NotLoaded{}), do: []
  defp normalize_bindings(bindings) when is_list(bindings), do: bindings
  defp normalize_bindings(_bindings), do: []

  defp binding_enabled?(binding) when is_map(binding),
    do: Map.get(binding, :enabled, true) != false

  defp binding_enabled?(_binding), do: false

  defp binding_sort_key(binding) when is_map(binding) do
    {Map.get(binding, :sequence) || 0, Map.get(binding, :id) || 0}
  end

  defp binding_sort_key(_binding), do: {0, 0}

  defp placeholder_for_binding(binding) when is_map(binding) do
    file = Map.get(binding, :file)

    if is_map(file) and not match?(%Ash.NotLoaded{}, file) do
      [
        Media.placeholder_text(%{
          kind: :media,
          external_id: Map.get(binding, :external_id),
          file_id: Map.get(binding, :file_id),
          file: file
        })
      ]
    else
      []
    end
  end

  defp placeholder_for_binding(_binding), do: []

  defp maybe_append(parts, value, true), do: parts ++ [value]
  defp maybe_append(parts, _value, false), do: parts
end
