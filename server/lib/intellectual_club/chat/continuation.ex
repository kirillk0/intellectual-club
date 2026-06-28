defmodule IntellectualClub.Chat.Continuation do
  @moduledoc """
  Copies the active branch of a readable chat into a new chat owned by the actor.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Branching
  alias IntellectualClub.Chat.ChatSettingsCopy
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.MessageTreeCopy
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Repo

  @spec continue_chat(integer(), map()) :: {:ok, Chat.t()} | {:error, term()}
  def continue_chat(source_chat_id, actor) when is_integer(source_chat_id) do
    with {:ok, %Chat{} = source} <- Ash.get(Chat, source_chat_id, actor: actor) do
      Repo.transaction(fn ->
        target = create_target_chat!(source, actor)
        copy_active_branch_to_target!(source, target, actor)
      end)
      |> unwrap_transaction()
    end
  end

  def continue_chat(_source_chat_id, _actor), do: {:error, :invalid_chat_id}

  defp create_target_chat!(%Chat{} = source, actor) do
    Chat
    |> Ash.Changeset.for_create(
      :create_empty,
      %{
        note: source.note,
        bot_id: source.bot_id,
        llm_configuration_id: source.llm_configuration_id
      },
      actor: actor
    )
    |> Ash.create!()
  end

  @spec target_attrs(Chat.t()) :: map()
  def target_attrs(%Chat{} = source) do
    %{
      note: source.note,
      bot_id: source.bot_id,
      llm_configuration_id: source.llm_configuration_id
    }
  end

  @spec branch_target_attrs(Chat.t()) :: map()
  def branch_target_attrs(%Chat{} = source) do
    %{
      note: branch_note(source.note),
      bot_id: source.bot_id,
      llm_configuration_id: source.llm_configuration_id
    }
  end

  defp branch_note(nil), do: ""
  defp branch_note(""), do: ""
  defp branch_note(note), do: to_string(note) <> " (branch)"

  @spec copy_active_branch_to_target!(Chat.t(), Chat.t(), map()) :: Chat.t()
  def copy_active_branch_to_target!(%Chat{} = source, %Chat{} = target, actor) do
    source
    |> Threads.active_branch(actor, load: MessageTreeCopy.load_spec(), strict?: true)
    |> MessageTreeCopy.copy_messages!(target, actor)

    Ash.get!(Chat, target.id, actor: actor)
  end

  @spec copy_branch_to_target!(Chat.t(), Chat.t(), integer(), map(), keyword()) :: Chat.t()
  def copy_branch_to_target!(%Chat{} = source, %Chat{} = target, message_id, actor, opts \\ [])
      when is_integer(message_id) and is_list(opts) do
    case copy_branch_to_target(source, target, message_id, actor, opts) do
      {:ok, chat} -> chat
      {:error, reason} -> raise "Failed to create branch chat: #{inspect(reason)}"
    end
  end

  @spec copy_branch_to_target(Chat.t(), Chat.t(), integer(), map(), keyword()) ::
          {:ok, Chat.t()} | {:error, term()}
  def copy_branch_to_target(%Chat{} = source, %Chat{} = target, message_id, actor, opts \\ [])
      when is_integer(message_id) and is_list(opts) do
    branch_opts = [load: MessageTreeCopy.load_spec(), strict?: true]

    with {:ok, %{message: selected, prefix: prefix}} <-
           Branching.active_branch_selection(source, message_id, actor, branch_opts),
         {:ok, replacement_contents} <- replacement_contents(selected, opts) do
      ChatSettingsCopy.copy_bindings!(source.id, target.id, actor)

      copied_ids = MessageTreeCopy.copy_messages!(prefix, target, actor)

      if Branching.user_message?(selected) do
        add_replacement_user_message!(replacement_contents, selected, target, copied_ids, actor)
      end

      {:ok, Ash.get!(Chat, target.id, actor: actor, load: [:last_message])}
    end
  end

  defp replacement_contents(%ChatMessage{} = selected, opts) do
    if Branching.user_message?(selected) do
      user_replacement_contents(opts)
    else
      {:ok, []}
    end
  end

  defp user_replacement_contents(opts) do
    contents = Keyword.get(opts, :replacement_contents, [])

    if contents == [] do
      {:error, :empty_user_message}
    else
      {:ok, contents}
    end
  end

  defp add_replacement_user_message!(
         contents,
         %ChatMessage{} = selected,
         %Chat{} = target,
         copied_ids,
         actor
       ) do
    {:ok, _message} =
      Threads.add_message(target, :user, "",
        actor: actor,
        parent_id: mapped_parent_id(selected.parent_id, copied_ids),
        contents: contents,
        status: :done
      )

    :ok
  end

  defp mapped_parent_id(nil, _copied_ids), do: nil

  defp mapped_parent_id(parent_id, copied_ids) when is_integer(parent_id) do
    Map.fetch!(copied_ids, parent_id)
  end

  defp unwrap_transaction({:ok, %Chat{} = chat}), do: {:ok, chat}
  defp unwrap_transaction({:error, error}), do: {:error, error}
end
