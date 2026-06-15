defmodule IntellectualClub.Chat.Branching do
  @moduledoc """
  Data-layer helpers for selecting messages from the active branch.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads

  @type selection :: %{
          source: Chat.t(),
          message: ChatMessage.t(),
          prefix: [ChatMessage.t()],
          user_message?: boolean()
        }

  @spec active_branch_selection(Chat.t() | integer(), integer(), map(), keyword()) ::
          {:ok, selection()} | {:error, term()}
  def active_branch_selection(source_chat_or_id, message_id, actor, opts \\ [])

  def active_branch_selection(source_chat_or_id, message_id, actor, opts)
      when is_integer(message_id) and is_list(opts) do
    with {:ok, %Chat{} = source} <- fetch_source_chat(source_chat_or_id, actor),
         {:ok, %ChatMessage{} = message, prefix} <-
           active_prefix_before_message(source, message_id, actor, opts) do
      {:ok,
       %{
         source: source,
         message: message,
         prefix: prefix,
         user_message?: user_message?(message)
       }}
    end
  end

  def active_branch_selection(_source_chat_or_id, _message_id, _actor, _opts),
    do: {:error, :message_not_in_active_branch}

  @spec validate_replacement_contents(selection() | ChatMessage.t(), list()) ::
          :ok | {:error, :empty_user_message}
  def validate_replacement_contents(%{message: %ChatMessage{} = message}, replacement_contents) do
    validate_replacement_contents(message, replacement_contents)
  end

  def validate_replacement_contents(%ChatMessage{} = message, replacement_contents) do
    if user_message?(message) and replacement_contents == [] do
      {:error, :empty_user_message}
    else
      :ok
    end
  end

  @spec user_message?(ChatMessage.t()) :: boolean()
  def user_message?(%ChatMessage{role: role}), do: role in [:user, "user"]

  defp fetch_source_chat(%Chat{id: id}, actor) when is_integer(id) do
    Ash.get(Chat, id, actor: actor)
  end

  defp fetch_source_chat(chat_id, actor) when is_integer(chat_id) do
    Ash.get(Chat, chat_id, actor: actor)
  end

  defp fetch_source_chat(_source_chat_or_id, _actor), do: {:error, :invalid_chat_id}

  defp active_prefix_before_message(%Chat{} = source, message_id, actor, opts) do
    branch = Threads.active_branch(source, actor, opts)
    index = Enum.find_index(branch, &(&1.id == message_id))

    if is_integer(index) do
      {:ok, Enum.at(branch, index), Enum.take(branch, index)}
    else
      {:error, :message_not_in_active_branch}
    end
  end
end
