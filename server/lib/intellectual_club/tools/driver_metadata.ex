defmodule IntellectualClub.Tools.DriverMetadata do
  @moduledoc """
  Public tool driver metadata for the SPA.

  The frontend can use this data to build settings/credentials UI dynamically
  from the driver-provided JSON schemas.
  """

  alias IntellectualClub.Tools.{Registry, ToolInstance}

  @spec list() :: list(map())
  def list do
    Registry.list_types()
    |> Enum.map(&for_type/1)
  end

  @spec for_type(String.t()) :: map()
  def for_type(type) when is_binary(type) do
    driver = Registry.driver_for_type!(type)

    default_config =
      driver.default_config()
      |> normalize_map()

    config_schema =
      driver.config_schema()
      |> normalize_map()
      |> inject_defaults(default_config)

    secrets_schema =
      case driver.secrets_schema() do
        nil -> nil
        %{} = schema -> normalize_map(schema)
        _other -> nil
      end

    fixed_functions =
      case driver.functions_mode() do
        :fixed -> fixed_functions_for(driver, type, default_config)
        _other -> []
      end

    %{
      "type" => driver.type(),
      "title" => driver.title(),
      "description" => driver.description(),
      "functions_mode" => Atom.to_string(driver.functions_mode()),
      "supports_discovery" => driver.supports_discovery?(),
      "supports_artifacts" => driver.supports_artifacts?(),
      "config_schema" => config_schema,
      "secrets_schema" => secrets_schema,
      "default_config" => default_config,
      "fixed_functions" => fixed_functions
    }
  end

  defp fixed_functions_for(driver, type, default_config)
       when is_binary(type) and is_map(default_config) do
    if function_exported?(driver, :fixed_functions, 1) do
      tool_instance = %ToolInstance{type: type, config: default_config, secrets: %{}}

      driver.fixed_functions(tool_instance)
      |> List.wrap()
      |> Enum.map(&normalize_fixed_function/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp normalize_fixed_function(%{} = raw) do
    name =
      raw
      |> Map.get("name", Map.get(raw, :name, ""))
      |> to_string()
      |> String.trim()

    if name == "" do
      nil
    else
      description =
        raw
        |> Map.get("description", Map.get(raw, :description, ""))
        |> to_string()

      parameters_schema =
        cond do
          is_map(Map.get(raw, "schema")) -> Map.get(raw, "schema")
          is_map(Map.get(raw, :schema)) -> Map.get(raw, :schema)
          is_map(Map.get(raw, "parameters_schema")) -> Map.get(raw, "parameters_schema")
          is_map(Map.get(raw, :parameters_schema)) -> Map.get(raw, :parameters_schema)
          true -> %{"type" => "object", "properties" => %{}}
        end
        |> normalize_map()

      enabled =
        case Map.get(raw, "enabled", Map.get(raw, :enabled)) do
          false -> false
          _ -> true
        end

      %{
        "name" => name,
        "description" => description,
        "enabled" => enabled,
        "parameters_schema" => parameters_schema
      }
    end
  end

  defp normalize_fixed_function(_other), do: nil

  defp normalize_map(%{} = value) do
    value
    |> Enum.into(%{}, fn {k, v} -> {normalize_key(k), normalize_map(v)} end)
  end

  defp normalize_map(value) when is_list(value), do: Enum.map(value, &normalize_map/1)
  defp normalize_map(value), do: value

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp inject_defaults(%{} = schema, defaults) when is_map(defaults) do
    schema_type = Map.get(schema, "type")

    if schema_type == "object" do
      props = Map.get(schema, "properties")

      if is_map(props) do
        patched =
          Enum.into(props, %{}, fn {key, prop_schema} ->
            prop_schema = if is_map(prop_schema), do: prop_schema, else: %{}
            default_value = Map.get(defaults, key)

            prop_schema =
              if Map.has_key?(prop_schema, "default") or is_nil(default_value) do
                prop_schema
              else
                Map.put(prop_schema, "default", default_value)
              end

            prop_schema =
              if Map.get(prop_schema, "type") == "object" and is_map(default_value) do
                inject_defaults(prop_schema, default_value)
              else
                prop_schema
              end

            {key, prop_schema}
          end)

        Map.put(schema, "properties", patched)
      else
        schema
      end
    else
      schema
    end
  end

  defp inject_defaults(schema, _defaults), do: schema
end
