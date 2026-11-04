defmodule IntellectualClub.Chat.Archive do
  @moduledoc "Authorized hierarchy and confirmation snapshots for the personal inbox."
  alias IntellectualClub.Chat.Chat
  require Ash.Query

  def roots(chats) do
    by_id = Map.new(chats, &{&1.id, &1})
    Map.new(chats, &{&1.id, root_id(&1, by_id, MapSet.new())})
  end

  defp root_id(%{subagent: false, id: id}, _chats, _seen), do: id

  defp root_id(chat, chats, seen) do
    if MapSet.member?(seen, chat.id) do
      nil
    else
      case Map.get(chats, chat.parent_chat_id) do
        nil -> nil
        parent -> root_id(parent, chats, MapSet.put(seen, chat.id))
      end
    end
  end

  def visible_ids(actor, view) do
    chats =
      Chat
      |> Ash.Query.filter(owner_id == ^actor.id)
      |> Ash.Query.select([:id, :parent_chat_id, :subagent])
      |> Ash.Query.load(:is_archived)
      |> Ash.read!(actor: actor, page: false)

    archived = Map.new(chats, &{&1.id, &1.is_archived})

    roots(chats)
    |> Enum.filter(fn {_id, root} -> Map.get(archived, root, false) == (view == "archive") end)
    |> Enum.map(&elem(&1, 0))
  end

  def snapshot(actor, bot_filter) do
    chats =
      Chat
      |> Ash.Query.filter(owner_id == ^actor.id)
      |> Ash.Query.select([:id, :parent_chat_id, :subagent, :bot_id])
      |> Ash.Query.load([:read_state, :personal_draft_updated_at, :inbox_unread])
      |> Ash.Query.calculate(
        :archive_working,
        :boolean,
        Ash.Expr.expr(exists(last_message, status == :generating))
      )
      |> Ash.read!(actor: actor, page: false)

    roots = roots(chats)

    protected =
      chats
      |> Enum.filter(&(not is_nil(&1.personal_draft_updated_at) or &1.read_state.is_snoozed))
      |> MapSet.new(&Map.get(roots, &1.id))

    candidates =
      chats
      |> Enum.filter(fn chat ->
        not chat.subagent and not chat.read_state.is_archived and
          not chat.inbox_unread and not chat.calculations.archive_working and
          not MapSet.member?(protected, chat.id) and matches_bot?(chat, bot_filter)
      end)
      |> Enum.sort_by(& &1.id)

    rows =
      Enum.map(candidates, &{&1.id, &1.read_state.state_version, &1.read_state.activity_revision})

    revision =
      :crypto.hash(:sha256, :erlang.term_to_binary({actor.id, bot_filter, rows}))
      |> Base.url_encode64(padding: false)

    %{count: length(rows), revision: revision, rows: rows}
  end

  defp matches_bot?(_chat, nil), do: true
  defp matches_bot?(chat, :none), do: is_nil(chat.bot_id)
  defp matches_bot?(chat, bot), do: chat.bot_id == bot
end
