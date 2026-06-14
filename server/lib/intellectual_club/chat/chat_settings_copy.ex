defmodule IntellectualClub.Chat.ChatSettingsCopy do
  @moduledoc """
  Copies chat-level knowledge block and tool bindings between chats.
  """

  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Tools.ChatToolBinding

  require Ash.Query

  @spec copy_bindings!(integer(), integer(), map()) :: :ok
  def copy_bindings!(source_chat_id, target_chat_id, actor)
      when is_integer(source_chat_id) and is_integer(target_chat_id) do
    copy_knowledge_block_bindings!(source_chat_id, target_chat_id, actor)
    copy_tool_bindings!(source_chat_id, target_chat_id, actor)
    :ok
  end

  @spec knowledge_block_binding_attrs(integer(), map()) :: [map()]
  def knowledge_block_binding_attrs(chat_id, actor) when is_integer(chat_id) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn binding ->
      %{
        knowledge_block_id: binding.knowledge_block_id,
        enabled: binding.enabled,
        sequence: binding.sequence
      }
    end)
  end

  @spec tool_binding_attrs(integer(), map()) :: [map()]
  def tool_binding_attrs(chat_id, actor) when is_integer(chat_id) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn binding ->
      %{
        tool_instance_id: binding.tool_instance_id,
        enabled: binding.enabled,
        sequence: binding.sequence
      }
    end)
  end

  defp copy_knowledge_block_bindings!(source_chat_id, target_chat_id, actor) do
    source_chat_id
    |> knowledge_block_binding_attrs(actor)
    |> Enum.each(fn attrs ->
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :chat_id, target_chat_id), actor: actor)
      |> Ash.create!(actor: actor)
    end)
  end

  defp copy_tool_bindings!(source_chat_id, target_chat_id, actor) do
    source_chat_id
    |> tool_binding_attrs(actor)
    |> Enum.each(fn attrs ->
      ChatToolBinding
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :chat_id, target_chat_id), actor: actor)
      |> Ash.create!(actor: actor)
    end)
  end
end
