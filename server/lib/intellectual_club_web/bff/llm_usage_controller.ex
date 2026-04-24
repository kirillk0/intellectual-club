defmodule IntellectualClubWeb.Bff.LlmUsageController do
  @moduledoc """
  Aggregated LLM configuration usage reports.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClubWeb.Bff.Helpers

  require Ash.Query

  def index(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, range} <- parse_date_range(params) do
      records = load_usage_records(actor, range)
      configurations = load_configurations(actor)

      json(conn, build_payload(records, configurations, range))
    else
      {:error, :invalid_date_range} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid date range"})
    end
  end

  defp parse_date_range(params) when is_map(params) do
    with {:ok, from_date} <- parse_date(Map.get(params, "from")),
         {:ok, to_date} <- parse_date(Map.get(params, "to")),
         true <- Date.compare(from_date, to_date) != :gt do
      from_dt = DateTime.new!(from_date, ~T[00:00:00.000000], "Etc/UTC")
      to_exclusive_dt = DateTime.new!(Date.add(to_date, 1), ~T[00:00:00.000000], "Etc/UTC")

      {:ok,
       %{
         from_date: from_date,
         to_date: to_date,
         from_dt: from_dt,
         to_exclusive_dt: to_exclusive_dt
       }}
    else
      _other -> {:error, :invalid_date_range}
    end
  end

  defp parse_date(value) when is_binary(value) do
    value
    |> String.trim()
    |> Date.from_iso8601()
  end

  defp parse_date(_value), do: {:error, :invalid_date}

  defp load_usage_records(actor, %{from_dt: from_dt, to_exclusive_dt: to_exclusive_dt}) do
    LlmUsageRecord
    |> Ash.Query.filter(occurred_at >= ^from_dt and occurred_at < ^to_exclusive_dt)
    |> Ash.Query.select([
      :id,
      :usage_user_id_snapshot,
      :usage_username_snapshot,
      :configuration_owner_id_snapshot,
      :llm_configuration_id_snapshot,
      :llm_configuration_external_id_snapshot,
      :llm_configuration_label_snapshot,
      :chat_message_id_snapshot,
      :chat_message_step_id_snapshot,
      :step_sequence,
      :cost,
      :occurred_at
    ])
    |> Ash.read!(actor: actor)
  end

  defp load_configurations(actor) do
    LlmConfiguration
    |> Ash.Query.select([:id, :external_id, :model_name, :note, :owner_id])
    |> Ash.Query.load([:shared_incoming, :shared_outgoing])
    |> Ash.read!(actor: actor)
  end

  defp build_payload(records, configurations, range) do
    rows =
      configurations
      |> Enum.reduce(%{}, fn configuration, acc ->
        key = configuration_key(configuration)

        Map.put(acc, key, %{
          key: key,
          configuration_id: configuration.id,
          configuration_external_id: uuid_string(configuration.external_id),
          label:
            configuration_label(configuration.model_name, configuration.note, configuration.id),
          deleted: false,
          shared_incoming: loaded_bool(Map.get(configuration, :shared_incoming)),
          shared_outgoing: loaded_bool(Map.get(configuration, :shared_outgoing)),
          cells: %{}
        })
      end)
      |> add_usage_records(records)
      |> Map.values()
      |> Enum.sort_by(&{String.downcase(&1.label || ""), &1.key})
      |> Enum.map(&serialize_row/1)

    users =
      records
      |> Enum.reduce(%{}, fn record, acc ->
        user_id = record.usage_user_id_snapshot
        username = record.usage_username_snapshot || "User ##{user_id}"
        Map.put(acc, user_id, %{id: user_id, username: username})
      end)
      |> Map.values()
      |> Enum.sort_by(&{String.downcase(&1.username || ""), &1.id})

    %{
      from: Date.to_iso8601(range.from_date),
      to: Date.to_iso8601(range.to_date),
      users: users,
      rows: rows
    }
  end

  defp add_usage_records(rows, records) do
    Enum.reduce(records, rows, fn record, acc ->
      key = usage_record_configuration_key(record)
      row = Map.get(acc, key) || historical_row(record, key)

      cell_key = Integer.to_string(record.usage_user_id_snapshot)

      cell =
        Map.get(row.cells, cell_key, %{
          message_ids: MapSet.new(),
          step_count: 0,
          cost: 0.0
        })

      cell = %{
        cell
        | message_ids: MapSet.put(cell.message_ids, record.chat_message_id_snapshot),
          step_count: cell.step_count + 1,
          cost: cell.cost + numeric_cost(record.cost)
      }

      row = %{row | cells: Map.put(row.cells, cell_key, cell)}
      Map.put(acc, key, row)
    end)
  end

  defp historical_row(record, key) do
    %{
      key: key,
      configuration_id: nil,
      configuration_external_id: uuid_string(record.llm_configuration_external_id_snapshot),
      label: record.llm_configuration_label_snapshot || "Deleted configuration",
      deleted: true,
      shared_incoming: false,
      shared_outgoing: false,
      cells: %{}
    }
  end

  defp serialize_row(row) do
    cells =
      row.cells
      |> Enum.map(fn {user_id, cell} ->
        {user_id,
         %{
           message_count: MapSet.size(cell.message_ids),
           step_count: cell.step_count,
           cost: cell.cost
         }}
      end)
      |> Map.new()

    row
    |> Map.delete(:cells)
    |> Map.put(:cells, cells)
  end

  defp configuration_key(%LlmConfiguration{} = configuration) do
    case uuid_string(configuration.external_id) do
      nil -> "id:#{configuration.id}"
      value -> "external:#{value}"
    end
  end

  defp usage_record_configuration_key(record) do
    case uuid_string(record.llm_configuration_external_id_snapshot) do
      nil -> "snapshot:#{record.llm_configuration_id_snapshot}"
      value -> "external:#{value}"
    end
  end

  defp configuration_label(model_name, note, id) do
    model_name =
      case model_name do
        value when is_binary(value) and value != "" -> value
        _ -> "Configuration ##{id}"
      end

    note =
      case note do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    if note == "" do
      model_name
    else
      "#{model_name} (#{note})"
    end
  end

  defp uuid_string(nil), do: nil

  defp uuid_string(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} ->
        uuid

      :error ->
        case Ecto.UUID.load(value) do
          {:ok, uuid} -> uuid
          :error -> value
        end
    end
  end

  defp uuid_string(value), do: to_string(value)

  defp numeric_cost(value) when is_integer(value), do: value * 1.0
  defp numeric_cost(value) when is_float(value), do: value
  defp numeric_cost(_value), do: 0.0

  defp loaded_bool(%Ash.NotLoaded{}), do: false
  defp loaded_bool(value), do: value == true
end
