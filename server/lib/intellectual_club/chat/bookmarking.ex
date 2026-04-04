defmodule IntellectualClub.Chat.Bookmarking do
  @moduledoc """
  Helpers for message bookmark lookups and toggling.
  """

  alias IntellectualClub.Chat.MessageBookmark

  require Ash.Query

  @spec bookmarked_message_id_set(list(integer()), any()) :: MapSet.t(integer())
  def bookmarked_message_id_set(message_ids, actor) when is_list(message_ids) do
    ids =
      message_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if ids == [] do
      MapSet.new()
    else
      MessageBookmark
      |> Ash.Query.filter(chat_message_id in ^ids)
      |> Ash.Query.select([:chat_message_id])
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.chat_message_id)
      |> MapSet.new()
    end
  end

  @spec toggle_message(integer(), any()) :: {:ok, boolean()} | {:error, term()}
  def toggle_message(message_id, actor) when is_integer(message_id) do
    existing =
      MessageBookmark
      |> Ash.Query.filter(chat_message_id == ^message_id)
      |> Ash.Query.limit(1)
      |> Ash.read!(actor: actor)
      |> List.first()

    case existing do
      %MessageBookmark{} = bookmark ->
        case Ash.destroy(bookmark, actor: actor) do
          :ok -> {:ok, false}
          {:ok, _bookmark} -> {:ok, false}
          {:error, error} -> {:error, error}
        end

      nil ->
        MessageBookmark
        |> Ash.Changeset.for_create(:create, %{chat_message_id: message_id}, actor: actor)
        |> Ash.create()
        |> case do
          {:ok, _bookmark} -> {:ok, true}
          {:error, error} -> {:error, error}
        end
    end
  end
end
