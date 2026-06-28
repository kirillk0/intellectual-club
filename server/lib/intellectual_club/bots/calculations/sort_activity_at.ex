defmodule IntellectualClub.Bots.Calculations.SortActivityAt do
  @moduledoc """
  Effective timestamp for bot sorting.

  Uses the latest message timestamp across chats with this bot for the current
  actor. Falls back to the bot update/create timestamp when no messages exist.
  """

  use Ash.Resource.Calculation

  alias IntellectualClub.Repo

  @impl true
  def load(_query, _opts, _context), do: [:id, :updated_at, :created_at]

  @impl true
  def calculate(records, _opts, context) do
    bot_ids =
      records
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    actor_id = actor_id_from_context(context)
    last_message_at_by_bot = load_last_message_at_by_bot(bot_ids, actor_id)

    Enum.map(records, fn record ->
      bot_id = Map.get(record, :id)
      Map.get(last_message_at_by_bot, bot_id) || record.updated_at || record.created_at
    end)
  end

  defp actor_id_from_context(%{actor: %{id: id}}) when is_integer(id), do: id
  defp actor_id_from_context(_context), do: nil

  defp load_last_message_at_by_bot([], _actor_id), do: %{}

  defp load_last_message_at_by_bot(bot_ids, actor_id) do
    {sql, params} = latest_message_sql(bot_ids, actor_id)
    rows = Repo.query!(sql, params).rows || []

    Map.new(rows, fn [bot_id, raw_datetime] ->
      {bot_id, normalize_datetime(raw_datetime)}
    end)
  end

  defp latest_message_sql(bot_ids, actor_id) do
    bot_placeholders = sql_placeholders(length(bot_ids), 1)

    {owner_clause, params} =
      if is_integer(actor_id) do
        owner_placeholder = "$#{length(bot_ids) + 1}"
        {" AND c.owner_id = #{owner_placeholder}", bot_ids ++ [actor_id]}
      else
        {"", bot_ids}
      end

    sql = """
    SELECT c.bot_id, MAX(m.created_at) AS last_message_at
    FROM chats c
    JOIN chat_messages m ON m.chat_id = c.id
    WHERE c.bot_id IN (#{bot_placeholders})#{owner_clause}
    GROUP BY c.bot_id
    """

    {sql, params}
  end

  defp sql_placeholders(count, start_index) when is_integer(count) and count > 0 do
    Enum.map_join(0..(count - 1), ", ", fn offset -> "$#{start_index + offset}" end)
  end

  defp normalize_datetime(%DateTime{} = value), do: value
  defp normalize_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp normalize_datetime(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace(" ", "T")

    case DateTime.from_iso8601(normalized) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        without_z = String.trim_trailing(normalized, "Z")

        case NaiveDateTime.from_iso8601(normalized) do
          {:ok, datetime} ->
            normalize_datetime(datetime)

          _ ->
            case NaiveDateTime.from_iso8601(without_z) do
              {:ok, datetime} -> normalize_datetime(datetime)
              _ -> nil
            end
        end
    end
  end

  defp normalize_datetime(_value), do: nil
end
