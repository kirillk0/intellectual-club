defmodule IntellectualClub.Knowledge.PromptContent do
  @moduledoc """
  Helpers for rendering knowledge block content inside prompts.
  """

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

  defp comment_line?(line) when is_binary(line) do
    String.starts_with?(line, @comment_prefix)
  end

  defp comment_line?(_line), do: false
end
