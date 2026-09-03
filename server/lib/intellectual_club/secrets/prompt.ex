defmodule IntellectualClub.Secrets.Prompt do
  @moduledoc """
  Renders safe model-visible metadata for managed secret bindings.
  """

  @spec binding_lines(term()) :: String.t()
  def binding_lines(bindings) do
    bindings
    |> normalize_bindings()
    |> Enum.reject(&(Map.get(&1, :kind) == :driver))
    |> Enum.filter(&(Map.get(&1, :enabled, true) != false))
    |> Enum.sort_by(&{Map.get(&1, :sequence) || 0, Map.get(&1, :id) || 0})
    |> Enum.map(&binding_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec instance_context(map()) :: String.t() | nil
  def instance_context(tool_instance) when is_map(tool_instance) do
    case binding_lines(Map.get(tool_instance, :secret_bindings, [])) do
      "" -> nil
      lines -> "Available managed secrets (pass their names in `use_secrets`):\n" <> lines
    end
  end

  def instance_context(_tool_instance), do: nil

  defp binding_line(binding) when is_map(binding) do
    env_name = binding |> Map.get(:env_name, "") |> to_string() |> String.trim()
    secret = Map.get(binding, :secret)
    description = if is_map(secret), do: Map.get(secret, :description, ""), else: ""
    description = description |> to_string() |> String.trim()

    cond do
      env_name == "" -> ""
      description == "" -> "- `#{env_name}`"
      true -> "- `#{env_name}` — #{description}"
    end
  end

  defp binding_line(_binding), do: ""
  defp normalize_bindings(%Ash.NotLoaded{}), do: []
  defp normalize_bindings(bindings) when is_list(bindings), do: bindings
  defp normalize_bindings(_bindings), do: []
end
