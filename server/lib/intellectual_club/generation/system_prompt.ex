defmodule IntellectualClub.Generation.SystemPrompt do
  @moduledoc """
  Provider-independent helpers for system prompt rendering.
  """

  alias IntellectualClub.Knowledge.PromptContent
  alias IntellectualClub.PromptVariables

  @doc """
  Renders a single system prompt from bot/chat/config/user block collections.
  """
  def build(opts \\ []) do
    bot_blocks = Keyword.get(opts, :bot_blocks, [])
    chat_blocks = Keyword.get(opts, :chat_blocks, [])
    config_top_blocks = Keyword.get(opts, :config_top_blocks, [])

    config_bottom_blocks =
      Keyword.get(opts, :config_bottom_blocks, Keyword.get(opts, :config_blocks, []))

    user_blocks = Keyword.get(opts, :user_blocks, [])
    tool_context = Keyword.get(opts, :tool_context, "")

    bot_vars = PromptVariables.normalize_map(Keyword.get(opts, :bot_variables, %{}))
    chat_vars = PromptVariables.normalize_map(Keyword.get(opts, :chat_variables, %{}))
    base_vars = Map.merge(bot_vars, chat_vars)

    rendered_blocks =
      [config_top_blocks, bot_blocks, chat_blocks, config_bottom_blocks, user_blocks]
      |> List.flatten()
      |> Enum.map_join("\n", &format_block(&1, merged_vars_for_block(&1, base_vars)))

    [rendered_blocks, format_raw_section(tool_context)]
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
    |> String.trim()
  end

  @doc """
  Renders a single system prompt string from ordered bot knowledge blocks.
  """
  def from_bot_blocks(blocks) when is_list(blocks) do
    build(bot_blocks: blocks)
  end

  defp format_block(nil, _vars), do: ""

  defp format_block(block, vars) do
    title = String.trim(block.name || "")

    body =
      block.content
      |> PromptContent.strip_comments()
      |> PromptVariables.render(vars)

    parts =
      []
      |> maybe_append("# #{title}", title != "")
      |> maybe_append(body, body != "")

    case Enum.join(parts, "\n") do
      "" -> ""
      rendered -> rendered <> "\n\n---\n"
    end
  end

  defp maybe_append(parts, value, true), do: parts ++ [value]
  defp maybe_append(parts, _value, false), do: parts

  defp format_raw_section(nil), do: ""

  defp format_raw_section(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> ""
      rendered -> rendered <> "\n\n---\n"
    end
  end

  defp merged_vars_for_block(block, base_vars) when is_map(block) and is_map(base_vars) do
    block_vars =
      block
      |> Map.get(:variables, %{})
      |> PromptVariables.normalize_map()

    Map.merge(base_vars, block_vars)
  end

  defp merged_vars_for_block(_block, base_vars), do: base_vars
end
