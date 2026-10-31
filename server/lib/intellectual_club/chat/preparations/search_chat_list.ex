defmodule IntellectualClub.Chat.Preparations.SearchChatList do
  @moduledoc """
  Owner-only list search. OFFSET 0 deliberately preserves the correlated early
  exit instead of hashing every global text match before applying the page limit.
  The fragments are only used behind the owner filter and Ash read policies.
  """
  use Ash.Resource.Preparation
  alias IntellectualClub.Chat.{ChatMessage, MessageText}
  require Ash.Query
  require Ash.Expr

  @impl true
  def prepare(query, opts, %{actor: %{id: owner_id}}) do
    term = query |> Ash.Query.get_argument(:q) |> String.trim()
    query = Ash.Query.filter(query, owner_id == ^owner_id)

    cond do
      term == "" -> Ash.Query.filter(query, false)
      opts[:message?] -> message(query, term, owner_id)
      true -> chats(query, term, owner_id)
    end
  end

  def prepare(query, _opts, _context), do: Ash.Query.filter(query, false)

  defp chats(query, term, owner_id) do
    pattern = MessageText.like_pattern(term)

    predicate =
      cond do
        not MessageText.indexable_term?(term) ->
          false

        Ash.Query.get_argument(query, :strategy) == :correlated ->
          pattern = MessageText.like_pattern(term)

          Ash.Expr.expr(
            fragment(
              """
              EXISTS (
                    SELECT 1 FROM chat_messages m
                    WHERE m.chat_id = ? AND m.owner_id = ? AND m.role IN ('user', 'assistant')
                      AND EXISTS (
                    SELECT 1 FROM chat_message_steps s
                    JOIN chat_message_items i ON i.chat_message_step_id = s.id
                    JOIN chat_message_contents c ON c.chat_message_item_id = i.id
                    WHERE s.chat_message_id = m.id AND c.owner_id = m.owner_id
                      AND c.kind = 'text'
                      AND c.item_type IN ('input', 'handoff_request', 'handoff_context', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')
                      AND i.type IN ('input', 'handoff_request', 'handoff_context', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')
                      AND c.content_text ILIKE ?
                    OFFSET 0
                  )
                    OFFSET 0
                  )
              """,
              id,
              ^owner_id,
              ^pattern
            )
          )

        true ->
          text = ChatMessage |> MessageText.filter({:contains, term}, owner_id: owner_id)
          text_predicate = text.filter.expression

          Ash.Expr.expr(
            exists(
              messages,
              owner_id == ^owner_id and role in [:user, :assistant] and ^text_predicate
            )
          )
      end

    Ash.Query.filter(
      query,
      fragment("? ILIKE ?", note, ^pattern) or exists(bot, fragment("? ILIKE ?", name, ^pattern)) or
        ^predicate
    )
  end

  defp message(query, term, owner_id) do
    chat_id = Ash.Query.get_argument(query, :chat_id)
    active_ids = Ash.Query.get_argument(query, :active_ids)
    pattern = MessageText.like_pattern(term)

    # Sort cheap message IDs before inspecting text. Sorting matched rows would
    # evaluate the expensive predicate for every message, even with LIMIT 1.
    query
    |> Ash.Query.filter(chat_id == ^chat_id and role in [:user, :assistant])
    |> Ash.Query.filter(
      id ==
        fragment(
          """
          (SELECT ranked.id FROM (
            SELECT m.id FROM chat_messages m
            WHERE m.chat_id = ? AND m.owner_id = ? AND m.role IN ('user', 'assistant')
            ORDER BY (m.id = ANY(?::bigint[])) DESC, (m.role = 'user') DESC,
              m.created_at DESC, m.id DESC
            OFFSET 0
          ) ranked
          WHERE EXISTS (
            SELECT 1 FROM chat_message_steps s
            JOIN chat_message_items i ON i.chat_message_step_id = s.id
            JOIN chat_message_contents c ON c.chat_message_item_id = i.id
            WHERE s.chat_message_id = ranked.id AND c.owner_id = ?
              AND c.kind = 'text'
              AND c.item_type IN ('input', 'handoff_request', 'handoff_context', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')
              AND i.type IN ('input', 'handoff_request', 'handoff_context', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')
              AND c.content_text ILIKE ?
            OFFSET 0
          ) LIMIT 1)
          """,
          ^chat_id,
          ^owner_id,
          ^active_ids,
          ^owner_id,
          ^pattern
        )
    )
    |> Ash.Query.limit(1)
  end
end
