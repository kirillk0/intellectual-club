defmodule IntellectualClub.Chat.Preparations.SearchMessages do
  @moduledoc "Applies the shared text predicate and optional resource filters before pagination."
  use Ash.Resource.Preparation
  require Ash.Query
  alias IntellectualClub.Chat.MessageText

  @impl true
  def prepare(query, _opts, _context) do
    search =
      MessageText.search(
        Ash.Query.get_argument(query, :q),
        Ash.Query.get_argument(query, :exact) == true
      )

    query =
      case search do
        :empty -> Ash.Query.filter(query, false)
        search -> MessageText.filter(query, search)
      end

    query
    |> filter_chat(Ash.Query.get_argument(query, :chat_id))
    |> filter_bot(Ash.Query.get_argument(query, :bot_id))
    |> filter_role(Ash.Query.get_argument(query, :role))
    |> Ash.Query.default_sort(created_at: :desc, id: :desc)
  end

  defp filter_chat(query, nil), do: query
  defp filter_chat(query, id), do: Ash.Query.filter(query, chat_id == ^id)
  defp filter_bot(query, nil), do: query
  defp filter_bot(query, id), do: Ash.Query.filter(query, exists(chat, bot_id == ^id))
  defp filter_role(query, nil), do: query
  defp filter_role(query, role), do: Ash.Query.filter(query, role == ^role)
end
