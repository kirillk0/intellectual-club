defmodule IntellectualClub.Tools.Discovery do
  @moduledoc """
  Tool discovery orchestration.

  This module performs network I/O through tool drivers and persists discovered
  functions into Ash resources. It is intentionally not implemented as an Ash
  action to avoid long-running requests in AshJsonApi.
  """

  alias IntellectualClub.Tools.{Registry, ToolFunction, ToolInstance}

  require Ash.Query

  @type discover_result :: %{
          created: non_neg_integer(),
          updated: non_neg_integer(),
          deleted: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec discover_and_sync!(ToolInstance.t(), actor :: any()) ::
          {discover_result(), list(ToolFunction.t())}
  def discover_and_sync!(%ToolInstance{} = tool_instance, actor) do
    driver = Registry.driver_for_type!(to_string(tool_instance.type || ""))

    case driver.discover(tool_instance) do
      {:ok, discovered} when is_list(discovered) ->
        sync_discovered_functions!(tool_instance, discovered, actor)

      {:ok, _other} ->
        record_discovery_error!(tool_instance, actor, "Discovery returned an invalid payload")
        raise RuntimeError, "Discovery returned an invalid payload"

      {:error, reason} ->
        error_text = to_string(reason)
        record_discovery_error!(tool_instance, actor, error_text)
        raise RuntimeError, error_text
    end
  end

  @spec sync_discovered_functions!(ToolInstance.t(), list(map()), actor :: any(), keyword()) ::
          {discover_result(), list(ToolFunction.t())}
  def sync_discovered_functions!(%ToolInstance{} = tool_instance, discovered, actor, opts \\ [])
      when is_list(discovered) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    stats = do_sync_discovered_functions!(tool_instance, discovered, actor, now: now)

    _ =
      tool_instance
      |> Ash.Changeset.for_update(:update_discovery_metadata, %{
        last_discovered_at: now,
        last_discovery_error: ""
      })
      |> Ash.update!(actor: actor)

    functions = load_functions!(tool_instance.id, actor)
    {stats, functions}
  end

  @spec record_discovery_error!(ToolInstance.t(), actor :: any(), String.t()) :: String.t()
  def record_discovery_error!(%ToolInstance{} = tool_instance, actor, error_text) do
    error_text = error_text |> to_string() |> String.trim()

    _ =
      tool_instance
      |> Ash.Changeset.for_update(:update_discovery_metadata, %{
        last_discovery_error: String.slice(error_text, 0, 2000)
      })
      |> Ash.update!(actor: actor)

    error_text
  end

  defp do_sync_discovered_functions!(%ToolInstance{} = tool_instance, discovered, actor, opts)
       when is_list(discovered) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    existing =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool_instance.id)
      |> Ash.read!(actor: actor)
      |> Map.new(fn fn_record -> {fn_record.name, fn_record} end)

    discovered =
      discovered
      |> normalize_discovered_specs()
      |> Enum.sort_by(fn {name, _spec} -> name end)

    {created, updated} =
      Enum.reduce(discovered, {0, 0}, fn {_name, spec}, {created, updated} ->
        case Map.get(existing, spec.name) do
          nil ->
            _ =
              ToolFunction
              |> Ash.Changeset.for_create(
                :create,
                %{
                  tool_instance_id: tool_instance.id,
                  name: spec.name,
                  description: spec.description,
                  parameters_schema: spec.schema,
                  enabled: spec.enabled_by_default,
                  discovery_available: true,
                  execution_mode: spec.execution_mode,
                  target_function_name: spec.target_function_name,
                  discovered_at: now
                },
                actor: actor
              )
              |> Ash.create!()

            {created + 1, updated}

          %ToolFunction{} = record ->
            semantics_changed? =
              record.execution_mode != spec.execution_mode or
                record.target_function_name != spec.target_function_name

            updates =
              %{
                description: spec.description,
                parameters_schema: spec.schema,
                discovery_available: true,
                execution_mode: spec.execution_mode,
                target_function_name: spec.target_function_name
              }
              |> maybe_reset_enabled(spec.enabled_by_default, semantics_changed?)

            if record.description != spec.description or record.parameters_schema != spec.schema or
                 record.discovery_available != true or
                 record.execution_mode != spec.execution_mode or
                 record.target_function_name != spec.target_function_name or
                 (semantics_changed? and record.enabled != spec.enabled_by_default) do
              _ =
                record
                |> Ash.Changeset.for_update(:update, updates, actor: actor)
                |> Ash.update!()

              {created, updated + 1}
            else
              {created, updated}
            end
        end
      end)

    desired_names =
      discovered
      |> Enum.map(fn {name, _spec} -> name end)
      |> MapSet.new()

    deleted =
      existing
      |> Enum.reject(fn {name, _record} -> MapSet.member?(desired_names, name) end)
      |> Enum.sort_by(fn {name, _record} -> name end)
      |> Enum.reduce(0, fn {_name, record}, deleted ->
        cond do
          record.execution_mode == :background and record.discovery_available == true ->
            _ =
              record
              |> Ash.Changeset.for_update(
                :update,
                %{discovery_available: false},
                actor: actor
              )
              |> Ash.update!()

            deleted + 1

          record.execution_mode == :background ->
            deleted

          true ->
            _ = Ash.destroy!(record, actor: actor)
            deleted + 1
        end
      end)

    %{
      created: created,
      updated: updated,
      deleted: deleted,
      total: map_size(Map.new(discovered))
    }
  end

  defp load_functions!(tool_instance_id, actor) when is_integer(tool_instance_id) do
    ToolFunction
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id and discovery_available == true)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.read!(actor: actor)
  end

  defp maybe_reset_enabled(updates, enabled_by_default, true)
       when is_map(updates) and is_boolean(enabled_by_default) do
    Map.put(updates, :enabled, enabled_by_default)
  end

  defp maybe_reset_enabled(updates, _enabled_by_default, false), do: updates

  defp normalize_discovered_spec(%{} = raw) do
    name = raw |> Map.get("name", "") |> to_string() |> String.trim()

    if name == "" do
      nil
    else
      description =
        raw
        |> Map.get("description", "")
        |> to_string()

      schema =
        case Map.get(raw, "schema") do
          %{} = schema -> schema
          _ -> %{"type" => "object", "properties" => %{}}
        end

      enabled_by_default =
        case Map.get(raw, "enabled_by_default") do
          value when is_boolean(value) -> value
          _other -> true
        end

      execution_mode =
        case Map.get(raw, "execution_mode") do
          "background" -> :background
          _other -> :direct
        end

      target_function_name =
        raw
        |> Map.get("target_function_name")
        |> case do
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> nil
              target -> target
            end

          _other ->
            nil
        end

      %{
        name: name,
        description: description,
        schema: schema,
        enabled_by_default: enabled_by_default,
        execution_mode: execution_mode,
        target_function_name: target_function_name
      }
    end
  end

  defp normalize_discovered_spec(_other), do: nil

  defp normalize_discovered_specs(discovered) when is_list(discovered) do
    Enum.reduce(discovered, %{}, fn raw_spec, acc ->
      case normalize_discovered_spec(raw_spec) do
        nil -> acc
        spec -> Map.put(acc, spec.name, spec)
      end
    end)
  end
end
