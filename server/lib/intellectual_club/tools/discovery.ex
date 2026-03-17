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
          total: non_neg_integer()
        }

  @spec discover_and_sync!(ToolInstance.t(), actor :: any()) ::
          {discover_result(), list(ToolFunction.t())}
  def discover_and_sync!(%ToolInstance{} = tool_instance, actor) do
    driver = Registry.driver_for_type!(to_string(tool_instance.type || ""))

    now = DateTime.utc_now()

    case driver.discover(tool_instance) do
      {:ok, discovered} when is_list(discovered) ->
        stats = sync_discovered_functions!(tool_instance, discovered, actor, now: now)

        _ =
          tool_instance
          |> Ash.Changeset.for_update(:update_discovery_metadata, %{
            last_discovered_at: now,
            last_discovery_error: ""
          })
          |> Ash.update!(actor: actor)

        functions = load_functions!(tool_instance.id, actor)
        {stats, functions}

      {:ok, _other} ->
        mark_discovery_error!(tool_instance, actor, "Discovery returned an invalid payload")

      {:error, reason} ->
        mark_discovery_error!(tool_instance, actor, to_string(reason))
    end
  end

  defp mark_discovery_error!(%ToolInstance{} = tool_instance, actor, error_text) do
    error_text = error_text |> to_string() |> String.trim()

    _ =
      tool_instance
      |> Ash.Changeset.for_update(:update_discovery_metadata, %{
        last_discovery_error: String.slice(error_text, 0, 2000)
      })
      |> Ash.update!(actor: actor)

    raise RuntimeError, error_text
  end

  defp sync_discovered_functions!(%ToolInstance{} = tool_instance, discovered, actor, opts)
       when is_list(discovered) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    existing =
      ToolFunction
      |> Ash.Query.filter(tool_instance_id == ^tool_instance.id)
      |> Ash.read!(actor: actor)
      |> Map.new(fn fn_record -> {fn_record.name, fn_record} end)

    {created, updated} =
      Enum.reduce(discovered, {0, 0}, fn raw_spec, {created, updated} ->
        spec = normalize_discovered_spec(raw_spec)

        if spec == nil do
          {created, updated}
        else
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
                    enabled: true,
                    discovered_at: now
                  },
                  actor: actor
                )
                |> Ash.create!()

              {created + 1, updated}

            %ToolFunction{} = record ->
              updates = %{
                description: spec.description,
                parameters_schema: spec.schema
              }

              if record.description != spec.description or record.parameters_schema != spec.schema do
                _ =
                  record
                  |> Ash.Changeset.for_update(:update, updates, actor: actor)
                  |> Ash.update!()

                {created, updated + 1}
              else
                {created, updated}
              end
          end
        end
      end)

    %{
      created: created,
      updated: updated,
      total: length(discovered)
    }
  end

  defp load_functions!(tool_instance_id, actor) when is_integer(tool_instance_id) do
    ToolFunction
    |> Ash.Query.filter(tool_instance_id == ^tool_instance_id)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.read!(actor: actor)
  end

  defp normalize_discovered_spec(%{} = raw) do
    name = raw |> Map.get("name", Map.get(raw, :name, "")) |> to_string() |> String.trim()

    if name == "" do
      nil
    else
      description =
        raw
        |> Map.get("description", Map.get(raw, :description, ""))
        |> to_string()

      schema =
        case Map.get(raw, "schema", Map.get(raw, :schema)) do
          %{} = schema -> schema
          _ -> %{"type" => "object", "properties" => %{}}
        end

      %{name: name, description: description, schema: schema}
    end
  end

  defp normalize_discovered_spec(_other), do: nil
end
