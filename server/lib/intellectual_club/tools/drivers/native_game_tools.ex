defmodule IntellectualClub.Tools.Drivers.NativeGameTools do
  @moduledoc """
  Native game tools driver.

  This fixed-function tool exposes server-side randomness helpers for roleplay
  and game scenarios.
  """

  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Tools.ToolInstance

  @random_unit_denominator 18_446_744_073_709_551_616

  @impl true
  def type, do: "native-game-tools"

  @impl true
  def title, do: "Game Tools"

  @impl true
  def description, do: "Native randomness helpers for roleplay and game scenarios."

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def supports_artifacts?, do: false

  @impl true
  def default_config, do: %{}

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{},
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema, do: nil

  @impl true
  def fixed_functions(%ToolInstance{} = _tool_instance) do
    [
      %{
        "name" => "random_select",
        "description" =>
          "Select one option using weighted server-side randomness. " <>
            "Use when a roleplay or game scenario needs a real random outcome.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "options" => %{
              "type" => "array",
              "description" =>
                "Weighted options. Each item is an object with option text and a non-negative weight.",
              "minItems" => 1,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "option" => %{
                    "type" => "string",
                    "description" => "Option text to return when selected."
                  },
                  "weight" => %{
                    "type" => "number",
                    "minimum" => 0,
                    "description" =>
                      "Non-negative selection weight. Options with weight 0 are never selected."
                  }
                },
                "required" => ["option", "weight"],
                "additionalProperties" => false
              }
            }
          },
          "required" => ["options"],
          "additionalProperties" => false
        },
        "enabled" => true
      }
    ]
  end

  @impl true
  def discover(%ToolInstance{} = _tool_instance) do
    {:error, "Discovery is not supported for this tool type."}
  end

  @impl true
  def execute(tool_instance, function_name, args, execution_context \\ nil)

  def execute(%ToolInstance{} = _tool_instance, "random_select", args, _execution_context)
      when is_map(args) do
    with {:ok, options, total_weight} <- parse_options(args) do
      selected = weighted_select(options, total_weight)

      {:ok,
       {"Selected option: #{selected.option}",
        %{
          "selected_option" => selected.option,
          "selected_index" => selected.index,
          "total_weight" => total_weight,
          "options" => Enum.map(options, &raw_option/1)
        }}}
    end
  end

  def execute(%ToolInstance{} = _tool_instance, "random_select", _args, _execution_context) do
    {:error, "Argument `options` is required."}
  end

  def execute(%ToolInstance{} = _tool_instance, function_name, _args, _execution_context)
      when is_binary(function_name) do
    {:error, "Unknown function: #{function_name}"}
  end

  defp parse_options(args) when is_map(args) do
    raw_options = Map.get(args, "options", Map.get(args, :options))

    cond do
      not is_list(raw_options) ->
        {:error, "Argument `options` must be a non-empty list."}

      raw_options == [] ->
        {:error, "Argument `options` must be a non-empty list."}

      true ->
        with {:ok, options} <- normalize_options(raw_options),
             total_weight = Enum.reduce(options, 0.0, &(&1.weight + &2)),
             true <- total_weight > 0.0 do
          {:ok, options, total_weight}
        else
          {:error, _message} = error -> error
          false -> {:error, "At least one option weight must be greater than 0."}
        end
    end
  end

  defp normalize_options(raw_options) when is_list(raw_options) do
    raw_options
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
      case normalize_option(raw, index) do
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, options} -> {:ok, Enum.reverse(options)}
      {:error, _message} = error -> error
    end
  end

  defp normalize_option(%{} = raw, index) do
    with {:ok, option} <- required_option(Map.get(raw, "option", Map.get(raw, :option)), index),
         {:ok, weight} <- required_weight(Map.get(raw, "weight", Map.get(raw, :weight)), index) do
      {:ok, %{index: index, option: option, weight: weight}}
    end
  end

  defp normalize_option([option, weight], index) do
    with {:ok, option} <- required_option(option, index),
         {:ok, weight} <- required_weight(weight, index) do
      {:ok, %{index: index, option: option, weight: weight}}
    end
  end

  defp normalize_option(_raw, index) do
    {:error, "Option #{index} must be an object with `option` and `weight` fields."}
  end

  defp required_option(value, index) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> {:error, "Option #{index} `option` must be a non-empty string."}
      option -> {:ok, option}
    end
  end

  defp required_option(_value, index) do
    {:error, "Option #{index} `option` must be a non-empty string."}
  end

  defp required_weight(value, index) when is_integer(value) do
    validate_weight(value * 1.0, index)
  end

  defp required_weight(value, index) when is_float(value) do
    validate_weight(value, index)
  end

  defp required_weight(value, index) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {weight, ""} -> validate_weight(weight, index)
      _other -> weight_error(index)
    end
  end

  defp required_weight(_value, index), do: weight_error(index)

  defp validate_weight(weight, _index) when is_number(weight) and weight >= 0 do
    {:ok, weight * 1.0}
  end

  defp validate_weight(_weight, index), do: weight_error(index)

  defp weight_error(index) do
    {:error, "Option #{index} `weight` must be a non-negative number."}
  end

  defp weighted_select(options, total_weight) when is_list(options) and total_weight > 0 do
    threshold = random_unit() * total_weight

    Enum.reduce_while(options, {threshold, nil}, fn option, {remaining, _selected} ->
      cond do
        option.weight <= 0 ->
          {:cont, {remaining, nil}}

        remaining < option.weight ->
          {:halt, {remaining, option}}

        true ->
          {:cont, {remaining - option.weight, nil}}
      end
    end)
    |> case do
      {_remaining, nil} -> last_positive_option(options)
      {_remaining, option} -> option
    end
  end

  defp random_unit do
    <<value::unsigned-big-integer-size(64)>> = :crypto.strong_rand_bytes(8)
    value / @random_unit_denominator
  end

  defp last_positive_option(options) do
    options
    |> Enum.filter(&(&1.weight > 0))
    |> List.last()
  end

  defp raw_option(option) do
    %{
      "index" => option.index,
      "option" => option.option,
      "weight" => option.weight
    }
  end
end
