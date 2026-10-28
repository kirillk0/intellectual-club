defmodule IntellectualClub.Chat.ReadMessages do
  @moduledoc "Reads a bounded flat page of an authorized chat, including linked-fork context."
  use Ash.Resource.Actions.Implementation
  alias IntellectualClub.Chat.{Chat, ForkHistory, MessageText, Threads}

  @impl true
  def run(input, _opts, context) do
    %{id: id, offset: offset, limit: limit} = input.arguments
    offset = offset || 0
    limit = limit || 25
    actor = context.actor

    with {:ok, %Chat{} = chat} <- Ash.get(Chat, id, actor: actor, authorize?: true),
         {:ok, inherited} <- ForkHistory.prefix(chat, actor) do
      local = Threads.active_branch(chat, actor)
      page = Enum.slice(inherited ++ local, offset, limit + 1)
      has_more = length(page) > limit
      messages = Enum.take(page, limit)
      local_page = Enum.reject(messages, &Map.has_key?(&1, :fork_inherited))
      texts = MessageText.load_texts(local_page, actor)

      {:ok,
       %{
         chat_id: id,
         messages: Enum.map(messages, &message_view(&1, texts)),
         next_offset: if(has_more, do: offset + limit),
         has_more: has_more
       }}
    else
      {:ok, nil} ->
        {:error, Ash.Error.Query.NotFound.exception(resource: Chat, primary_key: %{id: id})}

      {:error, :fork_context_unavailable} ->
        {:error,
         Ash.Error.Query.InvalidArgument.exception(
           field: :id,
           message: "Linked fork context is unavailable."
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp message_view(message, texts) do
    inherited? = Map.has_key?(message, :fork_inherited)

    %{
      id: message.id,
      chat_id: message.chat_id,
      role: message.role,
      status: message.status,
      text:
        if(inherited?, do: MessageText.from_loaded(message), else: Map.get(texts, message.id, "")),
      created_at: DateTime.to_iso8601(message.created_at),
      finished_at: if(message.finished_at, do: DateTime.to_iso8601(message.finished_at)),
      inherited: inherited?
    }
  end
end
