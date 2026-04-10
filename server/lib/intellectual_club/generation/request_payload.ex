defmodule IntellectualClub.Generation.RequestPayload do
  @moduledoc false

  @reserved_keys [
    "model",
    "messages",
    "input",
    "stream",
    "store",
    "instructions",
    "tools",
    "include",
    "tool_choice"
  ]

  def reserved_keys, do: @reserved_keys

  def stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  def model_name(payload, fallback \\ nil)

  def model_name(%{} = payload, fallback) do
    from_payload =
      payload
      |> Map.get("model")
      |> to_string()
      |> String.trim()

    if from_payload != "", do: from_payload, else: fallback
  end

  def model_name(_payload, fallback), do: fallback

  def parameters(payload, fallback \\ %{})

  def parameters(%{} = payload, fallback) do
    parameters =
      payload
      |> Map.drop(@reserved_keys)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(parameters) > 0 do
      parameters
    else
      normalize_fallback_parameters(fallback)
    end
  end

  def parameters(_payload, fallback), do: normalize_fallback_parameters(fallback)

  def messages(%{} = payload) do
    payload
    |> Map.get("messages")
    |> normalize_list()
  end

  def messages(_payload), do: []

  def input(%{} = payload) do
    payload
    |> Map.get("input")
    |> normalize_list()
  end

  def input(_payload), do: []

  def instructions(%{} = payload) do
    payload
    |> Map.get("instructions")
    |> to_string()
  end

  def instructions(_payload), do: ""

  def include(%{} = payload) do
    payload
    |> Map.get("include")
    |> normalize_list()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def include(_payload), do: []

  def tools(%{} = payload) do
    payload
    |> Map.get("tools")
    |> normalize_list()
  end

  def tools(_payload), do: []

  def tool_choice(%{} = payload), do: Map.get(payload, "tool_choice")
  def tool_choice(_payload), do: nil

  defp normalize_fallback_parameters(%{} = fallback), do: stringify_keys(fallback)
  defp normalize_fallback_parameters(_fallback), do: %{}

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []
end
