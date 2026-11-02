defmodule IntellectualClub.Chat.Preparations.ListSearch do
  @moduledoc """
  Owner-only chat-list text search over messages with two explicit plans.

  `:correlated` checks the contents of the messages the caller selected (a
  bounded id window) and nothing else; `OFFSET 0` keeps PostgreSQL from
  rewriting it into a global hash of every text match. `:indexed` is the
  ordinary nested `EXISTS` predicate, which the planner serves through the
  trigram index: cheap for rare terms, and multi-term queries narrow the index
  scan with every pattern. The fragment is only used behind the owner filter
  and Ash read policies; term patterns are bound as parameters.
  """
  use Ash.Resource.Preparation
  alias IntellectualClub.Chat.MessageText
  require Ash.Query
  require Ash.Expr

  @searchable_types_sql "('input', 'handoff_request', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')"

  if @searchable_types_sql !=
       "(" <>
         Enum.map_join(MessageText.searchable_trace_item_type_strings(), ", ", &"'#{&1}'") <> ")" do
    raise "searchable item types in raw SQL are out of sync with MessageText"
  end

  @impl true
  def prepare(query, _opts, %{actor: %{id: owner_id}}) do
    search =
      MessageText.search(
        Ash.Query.get_argument(query, :q),
        Ash.Query.get_argument(query, :exact) == true
      )

    query = Ash.Query.filter(query, owner_id == ^owner_id and role in [:user, :assistant])

    case search do
      :empty ->
        Ash.Query.filter(query, false)

      search ->
        case Ash.Query.get_argument(query, :strategy) do
          :correlated -> correlated(query, owner_id, search)
          _indexed -> MessageText.filter(query, search, owner_id: owner_id)
        end
    end
  end

  def prepare(query, _opts, _context), do: Ash.Query.filter(query, false)

  defp correlated(query, owner_id, search) do
    [first_pattern | _] = patterns = MessageText.like_patterns(search)

    Ash.Query.filter(
      query,
      fragment(
        """
        EXISTS (
          SELECT 1 FROM chat_message_steps s
          JOIN chat_message_items i ON i.chat_message_step_id = s.id
          JOIN chat_message_contents c ON c.chat_message_item_id = i.id
          WHERE s.chat_message_id = ? AND c.owner_id = ? AND c.kind = 'text'
            AND c.item_type IN ('input', 'handoff_request', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')
            AND i.type IN ('input', 'handoff_request', 'handoff_history', 'handoff_message', 'answer', 'handoff_summary')
            AND c.content_text ILIKE ? AND c.content_text ILIKE ALL(?::text[])
          OFFSET 0
        )
        """,
        id,
        ^owner_id,
        ^first_pattern,
        ^patterns
      )
    )
  end
end
