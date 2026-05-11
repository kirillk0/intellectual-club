defmodule IntellectualClub.Tools.Changes.ValidateToolConfig do
  @moduledoc """
  Validates tool instance config against driver-declared required fields.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Tools.Registry

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      type = tool_type(changeset)
      config = tool_config(changeset)

      with {:ok, driver} <- driver_for_type(type),
           %{} = schema <- driver.config_schema(),
           required when required != [] <- required_fields(schema) do
        defaults = normalize_map(driver.default_config())
        merged_config = Map.merge(defaults, normalize_map(config))

        Enum.reduce(required, changeset, fn field, acc ->
          if required_value_present?(Map.get(merged_config, field)) do
            acc
          else
            Changeset.add_error(acc,
              field: :config,
              message: "#{field_label(schema, field)} is required."
            )
          end
        end)
      else
        _other -> changeset
      end
    end)
  end

  defp tool_type(changeset) do
    raw =
      Changeset.get_attribute(changeset, :type) ||
        case changeset.data do
          %{type: type} -> type
          _ -> nil
        end

    raw |> to_string() |> String.trim()
  end

  defp tool_config(changeset) do
    Changeset.get_attribute(changeset, :config) ||
      case changeset.data do
        %{config: %{} = config} -> config
        _ -> %{}
      end
  end

  defp driver_for_type(""), do: :error

  defp driver_for_type(type) do
    {:ok, Registry.driver_for_type!(type)}
  rescue
    _ -> :error
  end

  defp required_fields(%{} = schema) do
    schema
    |> Map.get("required", Map.get(schema, :required, []))
    |> List.wrap()
    |> Enum.map(fn value -> value |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_map(%{} = map) do
    Enum.into(map, %{}, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_map(_other), do: %{}

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp required_value_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp required_value_present?(value) when is_number(value), do: true
  defp required_value_present?(value) when is_boolean(value), do: true
  defp required_value_present?(%{}), do: true
  defp required_value_present?(value) when is_list(value), do: value != []
  defp required_value_present?(_other), do: false

  defp field_label(schema, field) do
    schema
    |> schema_properties()
    |> Map.get(field, %{})
    |> case do
      %{} = field_schema ->
        field_schema
        |> Map.get("title", Map.get(field_schema, :title, ""))
        |> to_string()
        |> String.trim()

      _other ->
        ""
    end
    |> case do
      "" -> humanize_key(field)
      title -> title
    end
  end

  defp schema_properties(%{} = schema) do
    schema
    |> Map.get("properties", Map.get(schema, :properties, %{}))
    |> normalize_map()
  end

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.split("_", trim: true)
    |> Enum.map_join(" ", fn part -> String.capitalize(part) end)
  end
end
