defmodule IntellectualClub.PromptVariables do
  @moduledoc """
  Normalization and rendering helpers for prompt variables.
  """

  @placeholder_regex ~r/\{\{\s*(.+?)\s*\}\}/

  @doc """
  Converts a map or key-value list into `%{key => value}` with string values.
  """
  def normalize_map(raw)

  def normalize_map(raw) when is_map(raw) do
    Enum.reduce(raw, %{}, fn {key, value}, acc ->
      put_key_value(acc, key, value)
    end)
  end

  def normalize_map(raw) when is_list(raw) do
    Enum.reduce(raw, %{}, fn
      %{"key" => key, "value" => value}, acc -> put_key_value(acc, key, value)
      %{key: key, value: value}, acc -> put_key_value(acc, key, value)
      _, acc -> acc
    end)
  end

  def normalize_map(_raw), do: %{}

  @doc """
  Renders `{{key}}` placeholders using the provided variable map.
  """
  def render(text, vars) when is_map(vars) do
    text = to_string(text || "")

    Regex.replace(@placeholder_regex, text, fn _match, key ->
      key = String.trim(key)
      Map.get(vars, key, "") |> to_string()
    end)
  end

  defp put_key_value(acc, key, value) do
    key = to_string(key || "") |> String.trim()

    if key == "" do
      acc
    else
      Map.put(acc, key, normalize_value(value))
    end
  end

  defp normalize_value(nil), do: ""
  defp normalize_value(value), do: to_string(value)
end
