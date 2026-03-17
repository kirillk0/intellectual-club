defmodule IntellectualClub.Chat.Calculations.MessageCount do
  @moduledoc """
  Message count calculation for already-authorized chat records.
  """

  use Ash.Resource.Calculation

  alias IntellectualClub.Db

  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(records, _opts, _context) do
    chat_ids =
      records
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    counts =
      if chat_ids == [] do
        %{}
      else
        sql = """
        SELECT chat_id, COUNT(*) AS message_count
        FROM chat_messages
        WHERE chat_id IN (#{sql_placeholders(length(chat_ids))})
        GROUP BY chat_id
        """

        rows = Db.repo().query!(sql, chat_ids).rows || []

        Map.new(rows, fn [chat_id, message_count] ->
          {
            chat_id,
            case message_count do
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
    case Db.adapter() do
      :postgres -> Enum.map_join(1..count, ", ", fn index -> "$#{index}" end)
      _ -> Enum.map_join(1..count, ", ", fn _index -> "?" end)
    end
  end
end
