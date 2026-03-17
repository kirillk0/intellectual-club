defmodule IntellectualClub.Chat.ListingStats do
  @moduledoc """
  Aggregates for chat list sidebars and filter counters.
  """

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db

  @type bot_stat :: %{
          bot_id: integer(),
          bot_name: String.t() | nil,
          count: non_neg_integer()
        }

  @type sidebar_stats :: %{
          total_chat_count: non_neg_integer(),
          no_bot_chat_count: non_neg_integer(),
          bot_stats: [bot_stat()]
        }

  @spec sidebar(any()) :: sidebar_stats()
  def sidebar(%{id: owner_id}) when is_integer(owner_id) do
    rows =
      Db.repo().all(
        from(c in "chats",
          left_join: b in "bots",
          on: b.id == c.bot_id and b.owner_id == c.owner_id,
          where: c.owner_id == ^owner_id,
          group_by: [c.bot_id, b.name],
          select: %{
            bot_id: c.bot_id,
            bot_name: b.name,
            count: count(c.id)
          }
        )
      )

    Enum.reduce(rows, empty_sidebar_stats(), fn row, acc ->
      count = normalize_count(Map.get(row, :count))
      bot_id = Map.get(row, :bot_id)

      next_acc = %{acc | total_chat_count: acc.total_chat_count + count}

      if is_integer(bot_id) and bot_id > 0 do
        stat = %{
          bot_id: bot_id,
          bot_name: normalize_name(Map.get(row, :bot_name)),
          count: count
        }

        %{next_acc | bot_stats: [stat | next_acc.bot_stats]}
      else
        %{next_acc | no_bot_chat_count: next_acc.no_bot_chat_count + count}
      end
    end)
    |> Map.update!(:bot_stats, fn stats ->
      Enum.sort_by(stats, fn stat ->
        {
          String.downcase(Map.get(stat, :bot_name) || ""),
          Map.get(stat, :bot_id) || 0
        }
      end)
    end)
  end

  def sidebar(_actor), do: empty_sidebar_stats()

  defp empty_sidebar_stats do
    %{
      total_chat_count: 0,
      no_bot_chat_count: 0,
      bot_stats: []
    }
  end

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(_value), do: 0

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_name(_value), do: nil
end
