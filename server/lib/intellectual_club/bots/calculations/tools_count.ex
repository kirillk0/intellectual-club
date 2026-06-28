defmodule IntellectualClub.Bots.Calculations.ToolsCount do
  @moduledoc """
  Tool binding count for already-authorized bot records.
  """

  use Ash.Resource.Calculation

  alias IntellectualClub.Repo

  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(records, _opts, _context) do
    bot_ids =
      records
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    counts =
      if bot_ids == [] do
        %{}
      else
        sql = """
        SELECT bot_id, COUNT(*) AS tools_count
        FROM bot_tool_bindings
        WHERE bot_id IN (#{sql_placeholders(length(bot_ids))})
        GROUP BY bot_id
        """

        rows = Repo.query!(sql, bot_ids).rows || []

        Map.new(rows, fn [bot_id, tools_count] ->
          {
            bot_id,
            case tools_count do
              count when is_integer(count) and count >= 0 -> count
              _ -> 0
            end
          }
        end)
      end

    Enum.map(records, fn record ->
      record
      |> Map.get(:id)
      |> then(&Map.get(counts, &1, 0))
    end)
  end

  defp sql_placeholders(count) when is_integer(count) and count > 0 do
    Enum.map_join(1..count, ", ", fn index -> "$#{index}" end)
  end
end
