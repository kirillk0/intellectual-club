defmodule IntellectualClub.Chat.Listing do
  @moduledoc """
  Chat list queries and list-level derived values.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Previews
  alias IntellectualClub.Chat.Threads

  require Ash.Expr
  require Ash.Query

  @spec read_page(map(), term(), map(), list()) :: map()
  def read_page(actor, bot_filter, pagination, loads) do
    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> apply_hierarchy_filter(actor, Map.get(pagination, :section))
    |> apply_bot_filter(bot_filter)
    |> apply_view(Map.get(pagination, :view, "inbox"), actor, Map.get(pagination, :section))
    |> apply_section_sort(Map.get(pagination, :section))
    |> apply_section(Map.get(pagination, :section))
    |> Ash.Query.load([:read_state | loads], strict?: true)
    |> Ash.Query.page(
      limit: pagination.per_page,
      offset: (pagination.page - 1) * pagination.per_page,
      count: true
    )
    |> Ash.read!(actor: actor)
  end

  @doc """
  Reads independently paginated sections from one lightweight membership snapshot.

  Drafts overlap the inbox and can include subchats. Classification and ordering
  use the same authorized SQL expressions as `read_page/4`, but related records
  and read-state details are loaded only for the distinct visible page IDs.
  """
  @spec read_sections(map(), term(), map(), list()) :: map()
  def read_sections(actor, bot_filter, paginations, loads, view \\ "inbox") do
    section_keys =
      Enum.filter(["drafts", "unread", "working", "other"], &Map.has_key?(paginations, &1))

    rows =
      Chat
      |> Ash.Query.filter(owner_id == ^actor.id)
      |> section_candidates("drafts" in section_keys)
      |> apply_view(view, actor, if("drafts" in section_keys, do: "drafts"))
      |> apply_bot_filter(bot_filter)
      |> Ash.Query.select([:id, :subagent])
      |> Ash.Query.load([:last_activity_at, :inbox_unread, :personal_draft_updated_at],
        strict?: true
      )
      |> Ash.Query.calculate(
        :list_working,
        :boolean,
        Ash.Expr.expr(exists(last_message, status == :generating))
      )
      |> Ash.read!(actor: actor, page: false)
      |> Enum.sort_by(&{datetime_sort_value(&1.last_activity_at), &1.id}, :desc)

    grouped =
      Enum.reduce(rows, %{}, fn chat, acc ->
        acc =
          if is_nil(chat.personal_draft_updated_at),
            do: acc,
            else: Map.update(acc, "drafts", [chat], &[chat | &1])

        if chat.subagent do
          acc
        else
          section =
            cond do
              chat.inbox_unread == true -> "unread"
              chat.calculations.list_working == true -> "working"
              true -> "other"
            end

          Map.update(acc, section, [chat], &[chat | &1])
        end
      end)

    sections =
      Map.new(section_keys, fn section ->
        pagination = Map.fetch!(paginations, section)
        candidates = grouped |> Map.get(section, []) |> section_order(section)
        total = length(candidates)
        offset = (pagination.page - 1) * pagination.per_page
        ids = candidates |> Enum.slice(offset, pagination.per_page) |> Enum.map(& &1.id)

        {section,
         %{
           ids: ids,
           page: %{
             number: pagination.page,
             per_page: pagination.per_page,
             total: total,
             has_next: offset + pagination.per_page < total
           }
         }}
      end)

    ids = section_keys |> Enum.flat_map(&sections[&1].ids) |> Enum.uniq()

    chats =
      if ids == [] do
        []
      else
        Chat
        |> Ash.Query.filter(owner_id == ^actor.id and id in ^ids)
        |> apply_bot_filter(bot_filter)
        |> Ash.Query.load([:read_state | loads], strict?: true)
        |> Ash.read!(actor: actor, page: false)
      end

    by_id = Map.new(chats, &{&1.id, &1})
    %{results: Enum.flat_map(ids, &List.wrap(Map.get(by_id, &1))), sections: sections}
  end

  def apply_view(query, view, actor, section \\ nil)

  def apply_view(query, view, actor, "drafts") do
    ids = IntellectualClub.Chat.Archive.visible_ids(actor, view)
    Ash.Query.filter(query, id in ^ids)
  end

  def apply_view(query, view, _actor, _section) do
    archived = view == "archive"
    Ash.Query.filter(query, is_archived == ^archived)
  end

  defp section_candidates(query, true) do
    Ash.Query.filter(
      query,
      subagent == false or exists(drafts, user_id == ^Ash.Expr.actor(:id) and text != "")
    )
  end

  defp section_candidates(query, false), do: Ash.Query.filter(query, subagent == false)

  defp section_order(chats, "drafts"),
    do: Enum.sort_by(chats, &{datetime_sort_value(&1.personal_draft_updated_at), &1.id}, :desc)

  defp section_order(chats, _section), do: Enum.reverse(chats)

  defp datetime_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp datetime_sort_value(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  def apply_hierarchy_filter(query, _actor, "drafts"), do: query

  def apply_hierarchy_filter(query, _actor, _section) do
    Ash.Query.filter(query, subagent == false)
  end

  def apply_section_sort(query, "drafts"),
    do: Ash.Query.sort(query, personal_draft_updated_at: :desc, id: :desc)

  def apply_section_sort(query, _section), do: apply_sort(query)

  def apply_section(query, "drafts"),
    do: Ash.Query.filter(query, exists(drafts, user_id == ^Ash.Expr.actor(:id) and text != ""))

  def apply_section(query, "unread"), do: Ash.Query.filter(query, inbox_unread == true)

  def apply_section(query, "working"),
    do:
      Ash.Query.filter(
        query,
        inbox_unread == false and exists(last_message, status == :generating)
      )

  def apply_section(query, "other"),
    do:
      Ash.Query.filter(
        query,
        inbox_unread == false and not exists(last_message, status == :generating)
      )

  def apply_section(query, _section), do: query

  @spec apply_bot_filter(Ash.Query.t(), term()) :: Ash.Query.t()
  def apply_bot_filter(query, nil), do: query
  def apply_bot_filter(query, :none), do: Ash.Query.filter(query, is_nil(bot_id))

  def apply_bot_filter(query, bot_id) when is_integer(bot_id) do
    Ash.Query.filter(query, bot_id == ^bot_id)
  end

  def apply_bot_filter(query, _other), do: query

  @spec apply_sort(Ash.Query.t()) :: Ash.Query.t()
  def apply_sort(query), do: Ash.Query.sort(query, last_activity_at: :desc, id: :desc)

  @spec activity_at(Chat.t()) :: DateTime.t() | NaiveDateTime.t() | nil
  def activity_at(%Chat{} = chat) do
    case Map.get(chat, :last_activity_at) do
      %DateTime{} = activity_at ->
        activity_at

      %NaiveDateTime{} = activity_at ->
        activity_at

      _ ->
        case Map.get(chat, :last_message) do
          %{finished_at: %DateTime{} = finished_at} -> finished_at
          %{finished_at: %NaiveDateTime{} = finished_at} -> finished_at
          %{updated_at: %DateTime{} = updated_at} -> updated_at
          %{updated_at: %NaiveDateTime{} = updated_at} -> updated_at
          %{created_at: %DateTime{} = created_at} -> created_at
          %{created_at: %NaiveDateTime{} = created_at} -> created_at
          _ -> chat.created_at
        end
    end
  end

  @subchat_relation_kinds [:fork, :spawn]

  @spec child_subchat_counts([integer()], map()) :: map()
  def child_subchat_counts(chat_ids, actor) when is_list(chat_ids) do
    ids =
      chat_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Chat
      |> Ash.Query.filter(
        parent_chat_id in ^ids and parent_relation_kind in ^@subchat_relation_kinds and
          subagent == true
      )
      |> Ash.Query.select([:id, :parent_chat_id])
      |> Ash.read(actor: actor)
      |> case do
        {:ok, children} ->
          Enum.reduce(children, %{}, fn child, acc ->
            Map.update(acc, child.parent_chat_id, 1, &(&1 + 1))
          end)

        _other ->
          %{}
      end
    end
  end

  def child_subchat_counts(_chat_ids, _actor), do: %{}

  @spec direct_subchats([integer()], map(), list()) :: map()
  def direct_subchats(chat_ids, actor, loads \\ [])

  def direct_subchats(chat_ids, actor, loads) when is_list(chat_ids) do
    ids =
      chat_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Chat
      |> Ash.Query.filter(
        parent_chat_id in ^ids and parent_relation_kind in ^@subchat_relation_kinds and
          subagent == true
      )
      |> Ash.Query.sort(created_at: :asc, id: :asc)
      |> Ash.Query.load([:read_state | loads], strict?: true)
      |> Ash.read(actor: actor)
      |> case do
        {:ok, children} when is_list(children) ->
          Enum.group_by(children, & &1.parent_chat_id)

        _other ->
          %{}
      end
    end
  end

  def direct_subchats(_chat_ids, _actor, _loads), do: %{}

  @spec active_root_message_previews([Chat.t()], map(), integer(), map()) :: map()
  def active_root_message_previews(chats, active_branch_summaries, preview_len, actor)
      when is_list(chats) and is_integer(preview_len) do
    root_message_ids_by_chat =
      chats
      |> Enum.reduce(%{}, fn chat, acc ->
        summary = Map.get(active_branch_summaries, chat.id, %{})

        case Map.get(summary, :root_message_id) do
          message_id when is_integer(message_id) -> Map.put(acc, chat.id, message_id)
          _ -> acc
        end
      end)

    message_ids = root_message_ids_by_chat |> Map.values() |> Enum.uniq()

    messages_by_id =
      if message_ids == [] do
        %{}
      else
        ChatMessage
        |> Ash.Query.filter(id in ^message_ids)
        |> Ash.Query.select([:id, :role])
        |> Ash.Query.load(message_preview_tree(preview_len), strict?: true)
        |> Ash.read!(actor: actor)
        |> Map.new(fn message -> {message.id, message} end)
      end

    Enum.reduce(root_message_ids_by_chat, %{}, fn {chat_id, message_id}, acc ->
      case Map.get(messages_by_id, message_id) do
        nil -> acc
        message -> Map.put(acc, chat_id, Previews.message_preview(message, preview_len))
      end
    end)
  end

  @spec active_branch_summaries([Chat.t()], map()) :: map()
  def active_branch_summaries(chats, actor) when is_list(chats) do
    chats
    |> Enum.map(& &1.id)
    |> Threads.active_branch_summaries_by_chat(actor)
  end

  defp message_preview_tree(preview_len) do
    user_types = Previews.regular_item_types(:user)
    assistant_types = Previews.regular_item_types(:assistant)

    item_filter =
      Ash.Expr.expr(
        type in [:handoff_history, :handoff_message] or
          (type in ^user_types and chat_message_step.chat_message.role == :user) or
          (type in ^assistant_types and chat_message_step.chat_message.role == :assistant)
      )

    items =
      ChatMessageItem
      |> Ash.Query.filter(^item_filter)
      |> Ash.Query.select([:sequence, :type, :chat_message_step_id])
      |> Ash.Query.load(contents: preview_contents(preview_len, user_types ++ assistant_types))

    steps =
      ChatMessageStep
      |> Ash.Query.filter(exists(items, ^item_filter))
      |> Ash.Query.select([:sequence, :chat_message_id])
      |> Ash.Query.load(items: items)

    [steps: steps]
  end

  defp preview_contents(preview_len, regular_types) do
    ChatMessageContent
    |> Ash.Query.filter(
      (kind == :text and
         (item_type != :handoff_history or
            fragment("?->>'entry_kind'", content_json) == "message")) or
        (kind == :media and item_type in ^regular_types)
    )
    |> Ash.Query.select([:sequence, :kind, :chat_message_item_id])
    |> Ash.Query.calculate(
      :preview_text,
      :string,
      preview_text_expression(preview_len),
      %{},
      trim?: false,
      allow_empty?: true
    )
    |> Ash.Query.calculate(
      :preview_metadata,
      :map,
      Ash.Expr.expr(
        if item_type == :handoff_history do
          fragment(
            """
            jsonb_build_object('entry_kind', 'message', 'role',
              CASE WHEN ?->>'role' IN ('user', 'assistant') THEN ?->>'role' END)
            """,
            content_json,
            content_json
          )
        else
          nil
        end
      )
    )
  end

  defp preview_text_expression(preview_len) do
    budget = max(preview_len, 0) + 1

    # Bound ASCII blocks without losing leading, internal or trailing whitespace.
    # The extra dot is outside the preview budget and keeps a truncated whitespace
    # suffix from being trimmed as if it were the real end of the text.
    # PostgreSQL slices code points, not graphemes: keep Unicode blocks intact.
    Ash.Expr.expr(
      if kind == :text do
        fragment(
          ~S"""
          (SELECT CASE
            WHEN octet_length(value) <> char_length(value) THEN value
            WHEN body = '' THEN left(value, budget)
            ELSE left(value, least(char_length(value) - char_length(ltrim(value, spaces)), budget))
              || left(body, budget)
              || CASE WHEN char_length(body) > budget THEN '.'
                ELSE left(substring(value FROM char_length(rtrim(value, spaces)) + 1), budget)
              END
            END
            FROM (SELECT ?::text AS value, ?::integer AS budget,
              E' \t\n\r\f\013' AS spaces) AS preview_input
            CROSS JOIN LATERAL (SELECT btrim(value, spaces) AS body) AS preview_trimmed)
          """,
          content_text,
          ^budget
        )
      else
        ""
      end
    )
  end
end
