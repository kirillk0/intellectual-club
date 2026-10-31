defmodule IntellectualClub.Chat.Listing do
  @moduledoc """
  Chat list queries and list-level derived values.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Handoff
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

  def apply_hierarchy_filter(query, _actor, "drafts"), do: query

  def apply_hierarchy_filter(query, actor, _section) do
    query |> Ash.Query.filter(subagent == false) |> without_handoff_children(actor)
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

  @spec without_handoff_children(Ash.Query.t(), map()) :: Ash.Query.t()
  def without_handoff_children(query, actor) do
    relation_kind = Handoff.relation_kind()

    Ash.Query.filter(
      query,
      not exists(
        child_chats,
        owner_id == ^actor.id and parent_relation_kind == ^relation_kind
      )
    )
  end

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

  @spec child_handoff_counts([integer()], map()) :: map()
  def child_handoff_counts(chat_ids, actor) when is_list(chat_ids) do
    ids =
      chat_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if ids == [] do
      %{}
    else
      relation_kind = Handoff.relation_kind()

      Chat
      |> Ash.Query.filter(parent_chat_id in ^ids and parent_relation_kind == ^relation_kind)
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

  def child_handoff_counts(_chat_ids, _actor), do: %{}

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
