defmodule IntellectualClub.Chat.Threads do
  @moduledoc """
  Helpers for chat message trees, branching, and branch navigation.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.TokenCounter

  require Ash.Query

  @type branch_node :: %{
          id: integer(),
          role: atom(),
          token_count: non_neg_integer(),
          created_at: DateTime.t() | nil,
          parent: integer() | nil,
          status: atom(),
          error_detail: String.t() | nil,
          llm_configuration: integer() | nil,
          prev_sibling: integer() | nil,
          next_sibling: integer() | nil,
          siblings: list(map())
        }

  @doc """
  Adds a message to the provided chat and marks it as active leaf.
  """
  def add_message(chat_or_id, role, content, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    chat = fetch_chat!(chat_or_id, actor)
    contents = normalize_contents(content, opts)
    token_count = TokenCounter.estimate(text_from_contents(contents))

    params = %{
      chat_id: chat.id,
      role: role,
      parent_id: Keyword.get(opts, :parent_id),
      llm_configuration_id: Keyword.get(opts, :llm_configuration_id),
      status: Keyword.get(opts, :status, :done),
      error_detail: Keyword.get(opts, :error_detail),
      token_count: token_count
    }

    message =
      ChatMessage
      |> Ash.Changeset.for_create(:add_message, params, actor: actor)
      |> Ash.create!()

    _ = persist_message_trace!(message, role, contents, actor)

    _chat = set_last_message!(chat, message.id, actor)
    {:ok, message}
  end

  @doc """
  Adds a message using the currently active leaf as parent.
  """
  def add_message_to_end(chat_or_id, role, content, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)

    chat_id =
      case chat_or_id do
        %Chat{id: id} when is_integer(id) -> id
        id when is_integer(id) -> id
        other -> raise ArgumentError, "Unsupported chat reference: #{inspect(other)}"
      end

    # Reload to ensure `last_message_id` is up to date even when callers pass a stale struct.
    chat = fetch_chat!(chat_id, actor)

    add_message(chat, role, content,
      actor: actor,
      parent_id: chat.last_message_id,
      contents: Keyword.get(opts, :contents),
      llm_configuration_id: Keyword.get(opts, :llm_configuration_id),
      status: Keyword.get(opts, :status, :done),
      error_detail: Keyword.get(opts, :error_detail)
    )
  end

  @doc """
  Returns active branch messages from root to `chat.last_message`.
  """
  def active_branch(chat_or_id, actor, opts \\ []) do
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)

    by_id = Map.new(messages, &{&1.id, &1})

    branch =
      chat.last_message_id
      |> chain_from_leaf(by_id)
      |> Enum.map(&Map.fetch!(by_id, &1))

    branch =
      case Keyword.get(opts, :load, nil) do
        nil ->
          branch

        load_spec ->
          Ash.load!(branch, load_spec,
            actor: actor,
            strict?: Keyword.get(opts, :strict?, false)
          )
      end

    branch
  end

  @doc """
  Returns active branch messages from root to `chat.last_message` together with
  sibling metadata, reusing the same in-memory message tree for both outputs.
  """
  def active_branch_with_meta(chat_or_id, actor, opts \\ []) do
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)

    by_id = Map.new(messages, &{&1.id, &1})

    branch =
      chat.last_message_id
      |> chain_from_leaf(by_id)
      |> Enum.map(&Map.fetch!(by_id, &1))

    branch =
      case Keyword.get(opts, :load, nil) do
        nil ->
          branch

        load_spec ->
          Ash.load!(branch, load_spec,
            actor: actor,
            strict?: Keyword.get(opts, :strict?, false)
          )
      end

    {branch, branch_meta_from_messages(chat, messages)}
  end

  @doc """
  Returns branch messages from root to the target message.
  """
  def branch_to_message(chat_or_id, message_id, actor, opts \\ []) when is_integer(message_id) do
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)

    by_id = Map.new(messages, &{&1.id, &1})

    with {:ok, target} <- fetch_message_from_chat(by_id, message_id) do
      branch =
        target.id
        |> chain_from_leaf(by_id)
        |> Enum.map(&Map.fetch!(by_id, &1))

      branch =
        case Keyword.get(opts, :load, nil) do
          nil ->
            branch

          load_spec ->
            Ash.load!(branch, load_spec,
              actor: actor,
              strict?: Keyword.get(opts, :strict?, false)
            )
        end

      {:ok, branch}
    end
  end

  @doc """
  Returns active branch with sibling metadata for each node.
  """
  @spec get_branch_with_meta(Chat.t() | integer(), any()) :: [branch_node()]
  def get_branch_with_meta(chat_or_id, actor) do
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)
    branch_meta_from_messages(chat, messages)
  end

  defp branch_meta_from_messages(%Chat{} = chat, messages) when is_list(messages) do
    by_id = Map.new(messages, &{&1.id, &1})
    children = build_children_index(messages)

    chain_ids = chain_from_leaf(chat.last_message_id, by_id)

    {meta, _cache} =
      Enum.map_reduce(chain_ids, %{}, fn node_id, cache ->
        node = Map.fetch!(by_id, node_id)
        siblings = Map.get(children, node.parent_id, [])
        sorted_siblings = Enum.sort_by(siblings, &sort_key/1)
        sibling_ids = Enum.map(sorted_siblings, & &1.id)

        current_index = Enum.find_index(sibling_ids, &(&1 == node.id)) || 0
        prev_id = if current_index > 0, do: Enum.at(sibling_ids, current_index - 1), else: nil

        next_id =
          if current_index + 1 < length(sibling_ids),
            do: Enum.at(sibling_ids, current_index + 1),
            else: nil

        {siblings_meta, cache} =
          Enum.map_reduce(sorted_siblings, cache, fn sibling, cache ->
            {size, cache} = subtree_size(sibling.id, children, cache)
            {%{id: sibling.id, size: size, active: sibling.id == node.id}, cache}
          end)

        node_meta = %{
          id: node.id,
          role: node.role,
          token_count: node.token_count || 0,
          created_at: node.created_at,
          parent: node.parent_id,
          status: node.status,
          error_detail: node.error_detail,
          llm_configuration: node.llm_configuration_id,
          prev_sibling: prev_id,
          next_sibling: next_id,
          siblings: siblings_meta
        }

        {node_meta, cache}
      end)

    meta
  end

  @doc """
  Switches to a sibling branch and activates the rightmost leaf.
  """
  def switch_branch(chat_or_id, current_message_id, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)

    by_id = Map.new(messages, &{&1.id, &1})
    children = build_children_index(messages)

    with {:ok, current} <- fetch_message_from_chat(by_id, current_message_id),
         {:ok, target} <- select_switch_target(current, children, opts),
         leaf <- rightmost_leaf(target, children) do
      _chat = set_last_message!(chat, leaf.id, actor)
      {:ok, get_branch_with_meta(chat.id, actor)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Activates the branch that includes the provided message.
  """
  def activate_branch(chat_or_id, message_id, actor) do
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)
    by_id = Map.new(messages, &{&1.id, &1})
    children = build_children_index(messages)

    with {:ok, target} <- fetch_message_from_chat(by_id, message_id),
         leaf <- rightmost_leaf(target, children) do
      _chat = set_last_message!(chat, leaf.id, actor)
      {:ok, get_branch_with_meta(chat.id, actor)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a message while preserving descendants by reattaching direct children.
  """
  def delete_message_keep_children(chat_or_id, message_id, actor) do
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)
    by_id = Map.new(messages, &{&1.id, &1})
    children = build_children_index(messages)

    with {:ok, message} <- fetch_message_from_chat(by_id, message_id) do
      siblings =
        messages
        |> Enum.filter(&(&1.parent_id == message.parent_id and &1.id != message.id))
        |> Enum.sort_by(&sort_key/1)

      direct_children =
        messages
        |> Enum.filter(&(&1.parent_id == message.id))
        |> Enum.sort_by(&sort_key/1)

      has_siblings = siblings != []
      has_children = direct_children != []

      if has_siblings and has_children and Enum.any?(direct_children, &(&1.role != message.role)) do
        {:error, :cannot_mix_roles}
      else
        was_last = chat.last_message_id == message.id

        new_last_id =
          cond do
            not was_last -> chat.last_message_id
            has_siblings -> siblings |> List.last() |> rightmost_leaf(children) |> Map.get(:id)
            true -> message.parent_id
          end

        if was_last do
          _chat = set_last_message!(chat, new_last_id, actor)
        end

        Enum.each(direct_children, fn child ->
          _child =
            child
            |> Ash.Changeset.for_update(:reparent, %{parent_id: message.parent_id}, actor: actor)
            |> Ash.update!(actor: actor)
        end)

        _ = Ash.destroy!(message, actor: actor)

        {:ok, get_branch_with_meta(chat.id, actor)}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns ids of messages on the active branch.
  """
  def active_branch_ids(chat_or_id, actor) do
    chat = fetch_chat!(chat_or_id, actor)
    messages = load_messages(chat.id, actor)
    by_id = Map.new(messages, &{&1.id, &1})

    chat.last_message_id
    |> chain_from_leaf(by_id)
    |> MapSet.new()
  end

  @doc """
  Returns active branch message ids grouped by chat id.
  """
  def active_branch_ids_by_chat(chat_ids, actor) when is_list(chat_ids) do
    chat_ids =
      chat_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if chat_ids == [] do
      %{}
    else
      chats =
        Chat
        |> Ash.Query.filter(id in ^chat_ids)
        |> Ash.Query.select([:id, :last_message_id])
        |> Ash.read!(actor: actor)

      messages =
        ChatMessage
        |> Ash.Query.filter(chat_id in ^chat_ids)
        |> Ash.Query.select([:id, :chat_id, :parent_id])
        |> Ash.read!(actor: actor)

      parents_by_chat =
        Enum.reduce(messages, %{}, fn msg, acc ->
          Map.update(acc, msg.chat_id, %{msg.id => msg.parent_id}, fn parents ->
            Map.put(parents, msg.id, msg.parent_id)
          end)
        end)

      Enum.reduce(chats, %{}, fn chat, acc ->
        active_ids = chain_ids(chat.last_message_id, Map.get(parents_by_chat, chat.id, %{}))
        Map.put(acc, chat.id, MapSet.new(active_ids))
      end)
    end
  end

  @doc """
  Returns active branch message counts grouped by chat id.
  """
  def active_branch_counts_by_chat(chat_ids, actor) when is_list(chat_ids) do
    chat_ids
    |> active_branch_ids_by_chat(actor)
    |> Map.new(fn {chat_id, active_ids} -> {chat_id, MapSet.size(active_ids)} end)
  end

  defp fetch_chat!(%Chat{} = chat, _actor), do: chat

  defp fetch_chat!(chat_id, actor) when is_integer(chat_id) do
    Ash.get!(Chat, chat_id, actor: actor)
  end

  defp load_messages(chat_id, actor) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.read!(actor: actor)
  end

  defp set_last_message!(chat, last_message_id, actor) do
    chat
    |> Ash.Changeset.for_update(:set_last_message, %{last_message_id: last_message_id})
    |> Ash.update!(actor: actor)
  end

  defp fetch_message_from_chat(by_id, message_id) do
    case Map.get(by_id, message_id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  end

  defp select_switch_target(current, children, opts) do
    siblings =
      children
      |> Map.get(current.parent_id, [])
      |> Enum.sort_by(&sort_key/1)

    target_id = Keyword.get(opts, :target_id)
    direction = Keyword.get(opts, :direction)

    target =
      cond do
        is_integer(target_id) ->
          Enum.find(siblings, &(&1.id == target_id))

        direction in [:prev, "prev", :next, "next"] ->
          current_index = Enum.find_index(siblings, &(&1.id == current.id))

          cond do
            is_nil(current_index) ->
              nil

            direction in [:prev, "prev"] and current_index > 0 ->
              Enum.at(siblings, current_index - 1)

            direction in [:next, "next"] and current_index + 1 < length(siblings) ->
              Enum.at(siblings, current_index + 1)

            true ->
              nil
          end

        true ->
          nil
      end

    case target do
      nil -> {:error, :switch_not_possible}
      target -> {:ok, target}
    end
  end

  defp build_children_index(messages) do
    messages
    |> Enum.reduce(%{}, fn message, acc ->
      Map.update(acc, message.parent_id, [message], &[message | &1])
    end)
    |> Enum.into(%{}, fn {parent_id, children} ->
      {parent_id, Enum.sort_by(children, &sort_key/1)}
    end)
  end

  defp chain_from_leaf(nil, _by_id), do: []

  defp chain_from_leaf(leaf_id, by_id) do
    do_chain_from_leaf(leaf_id, by_id, [])
  end

  defp do_chain_from_leaf(nil, _by_id, acc), do: acc

  defp do_chain_from_leaf(node_id, by_id, acc) do
    case Map.get(by_id, node_id) do
      nil -> acc
      node -> do_chain_from_leaf(node.parent_id, by_id, [node.id | acc])
    end
  end

  defp chain_ids(nil, _parents), do: []

  defp chain_ids(leaf_id, parents) when is_integer(leaf_id) and is_map(parents) do
    do_chain_ids(leaf_id, parents, MapSet.new(), [])
  end

  defp do_chain_ids(nil, _parents, _seen, acc), do: acc

  defp do_chain_ids(node_id, parents, seen, acc) do
    if MapSet.member?(seen, node_id) do
      acc
    else
      next_seen = MapSet.put(seen, node_id)
      do_chain_ids(Map.get(parents, node_id), parents, next_seen, [node_id | acc])
    end
  end

  defp subtree_size(node_id, children, cache) do
    case Map.fetch(cache, node_id) do
      {:ok, size} ->
        {size, cache}

      :error ->
        descendants = Map.get(children, node_id, [])

        {child_sizes, cache} =
          Enum.map_reduce(descendants, cache, fn child, cache ->
            subtree_size(child.id, children, cache)
          end)

        size = 1 + Enum.sum(child_sizes)
        {size, Map.put(cache, node_id, size)}
    end
  end

  defp rightmost_leaf(node, children) do
    case Map.get(children, node.id, []) do
      [] -> node
      node_children -> node_children |> Enum.max_by(&sort_key/1) |> rightmost_leaf(children)
    end
  end

  defp sort_key(message) do
    {sort_timestamp(message.created_at), message.id || 0}
  end

  defp sort_timestamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp sort_timestamp(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp sort_timestamp(_value), do: -1

  defp normalize_contents(content, opts) when is_list(opts) do
    case Keyword.fetch(opts, :contents) do
      {:ok, nil} ->
        normalize_content_specs([%{kind: :text, content_text: to_string(content || "")}])

      {:ok, contents} ->
        normalize_content_specs(contents)

      :error ->
        normalize_content_specs([%{kind: :text, content_text: to_string(content || "")}])
    end
  end

  defp normalize_content_specs(contents) when is_list(contents) do
    contents
    |> Enum.filter(&is_map/1)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {content, idx} ->
      case normalize_content_spec(content, idx) do
        nil -> []
        spec -> [spec]
      end
    end)
  end

  defp normalize_content_specs(_other), do: []

  defp normalize_content_spec(content, sequence) when is_map(content) and is_integer(sequence) do
    kind =
      case Map.get(content, :kind, Map.get(content, "kind")) do
        value when value in [:media, "media"] -> :media
        value when value in [:opaque, "opaque"] -> :opaque
        _ -> :text
      end

    content_text =
      Map.get(content, :content_text, Map.get(content, "content_text", "")) |> to_string()

    content_json = Map.get(content, :content_json, Map.get(content, "content_json"))
    file_id = Map.get(content, :file_id, Map.get(content, "file_id"))

    cond do
      kind == :text and content_text == "" ->
        nil

      kind == :media and not is_integer(file_id) ->
        nil

      true ->
        %{
          sequence: sequence,
          kind: kind,
          content_text: if(kind == :text, do: content_text, else: ""),
          content_json: if(kind == :opaque, do: content_json, else: nil),
          file_id: if(kind == :media, do: file_id, else: nil)
        }
    end
  end

  defp text_from_contents(contents) when is_list(contents) do
    contents
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map(&to_string(&1.content_text || ""))
    |> Enum.join("")
  end

  defp text_from_contents(_other), do: ""

  defp persist_message_trace!(message, role, contents, actor) do
    item_type =
      case role do
        :user -> :input
        "user" -> :input
        :assistant -> :answer
        "assistant" -> :answer
        _ -> :other
      end

    with {:ok, step} <-
           ChatMessageStep
           |> Ash.Changeset.for_create(:create, %{chat_message_id: message.id, sequence: 1},
             actor: actor
           )
           |> Ash.create(),
         {:ok, item} <-
           ChatMessageItem
           |> Ash.Changeset.for_create(
             :create,
             %{chat_message_step_id: step.id, sequence: 1, type: item_type},
             actor: actor
           )
           |> Ash.create() do
      if contents == [] do
        {:ok, item}
      else
        Enum.reduce_while(contents, {:ok, item}, fn content, {:ok, _item} ->
          ChatMessageContent
          |> Ash.Changeset.for_create(
            :create,
            %{
              chat_message_item_id: item.id,
              sequence: content.sequence,
              kind: content.kind,
              content_text: content.content_text,
              content_json: content.content_json,
              file_id: content.file_id
            },
            actor: actor
          )
          |> Ash.create()
          |> case do
            {:ok, _content} -> {:cont, {:ok, item}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
      end
    end
  end
end
