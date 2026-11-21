defmodule IntellectualClub.Chat.LinkedForkCleanup.LegacyChatReference do
  @moduledoc """
  Detaches legacy chat pointers to the trace of a fenced chat before it disappears.

  A surviving row may point to the chat, its message and its tool item. PostgreSQL's
  separate SET NULL actions can check a transient version of that row while another
  target is already gone. Clear only the trace pointers first, while all targets
  exist. Leave parent_chat_id to its FK and orphan-archiving trigger.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat.LinkedForkCleanup,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageItem}
  alias IntellectualClub.Chat.LinkedForkCleanup.Operation

  require Ash.Query

  postgres do
    table("chats")
    repo(IntellectualClub.Repo)
    migrate?(false)
  end

  attributes do
    integer_primary_key(:id)
  end

  relationships do
    belongs_to(:parent_message, ChatMessage, attribute_type: :integer)
    belongs_to(:parent_tool_call_item, ChatMessageItem, attribute_type: :integer)
  end

  actions do
    read :read do
      primary?(true)
      public?(false)
    end

    update :detach_message do
      accept([])
      public?(false)
      change(set_attribute(:parent_message_id, nil))
    end

    update :detach_item do
      accept([])
      public?(false)
      change(set_attribute(:parent_tool_call_item_id, nil))
    end
  end

  policies do
    policy action(:read) do
      authorize_if expr(
                     exists(parent_message, owner_id == ^actor(:id)) or
                       exists(parent_tool_call_item, owner_id == ^actor(:id))
                   )
    end

    policy action(:detach_message) do
      authorize_if expr(exists(parent_message, owner_id == ^actor(:id)))
    end

    policy action(:detach_item) do
      authorize_if expr(exists(parent_tool_call_item, owner_id == ^actor(:id)))
    end
  end

  @doc false
  def detach!(chat_id, actor, operation) do
    Operation.record!(operation, Chat, chat_id, actor)

    # capture! has fenced all trace items; a late reference cannot attach until
    # this delete has committed or rolled back. No parent_chat_id is cleared here.
    __MODULE__
    |> Ash.Query.filter(parent_message.chat_id == ^chat_id)
    |> detach_query!(:detach_message, actor)

    __MODULE__
    |> Ash.Query.filter(parent_tool_call_item.chat_message_step.chat_message.chat_id == ^chat_id)
    |> detach_query!(:detach_item, actor)
  end

  defp detach_query!(query, action, actor) do
    case Ash.bulk_update!(query, action, %{},
           actor: actor,
           authorize?: true,
           strategy: [:atomic],
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
    end
  end
end
