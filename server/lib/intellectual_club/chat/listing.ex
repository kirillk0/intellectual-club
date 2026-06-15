defmodule IntellectualClub.Chat.Listing do
  @moduledoc """
  Chat list queries and list-level derived values.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Handoff
  alias IntellectualClub.Chat.Previews
  alias IntellectualClub.Chat.Threads

  require Ash.Query

  @spec read_page(map(), term(), map(), list()) :: map()
  def read_page(actor, bot_filter, pagination, loads) do
    Chat
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> apply_bot_filter(bot_filter)
    |> apply_sort()
    |> Ash.Query.load(loads, strict?: true)
    |> Ash.Query.page(
      limit: pagination.per_page,
      offset: (pagination.page - 1) * pagination.per_page,
      count: true
    )
    |> Ash.read!(actor: actor)
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
        |> Ash.Query.load(message_preview_tree(), strict?: true)
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

  defp message_preview_tree do
    [
      steps: [
        :sequence,
        items: [
          :sequence,
          :type,
          contents: [
            :sequence,
            :kind,
            :content_text
          ]
        ]
      ]
    ]
  end
end
