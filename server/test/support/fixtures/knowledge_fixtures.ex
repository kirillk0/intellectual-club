defmodule IntellectualClub.KnowledgeFixtures do
  @moduledoc """
  Fixtures for knowledge blocks, knowledge tags and chat block bindings.
  """

  import IntellectualClub.Fixtures

  require Ash.Query

  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Knowledge.{KnowledgeBlock, KnowledgeTag}

  @doc """
  Creates a knowledge block. Defaults: a unique `name`, `version: "v1"`,
  `content: "content"`. Arguments such as `:tag_bindings` are passed through.
  """
  def create_knowledge_block!(actor, attrs \\ %{}) do
    defaults = %{name: unique_name("Block"), version: "v1", content: "content"}
    create!(KnowledgeBlock, merge_attrs(defaults, attrs), actor)
  end

  @doc "Creates a knowledge tag. Defaults: a unique `name`, `parent_id: nil`."
  def create_knowledge_tag!(actor, attrs \\ %{}) do
    create!(KnowledgeTag, merge_attrs(%{name: unique_name("tag"), parent_id: nil}, attrs), actor)
  end

  @doc "Binds `block` to `chat`. Defaults: `enabled: true`, `sequence: 0`."
  def create_chat_block_binding!(actor, chat, block, attrs \\ %{}) do
    defaults = %{chat_id: chat.id, knowledge_block_id: block.id, enabled: true, sequence: 0}
    create!(ChatKnowledgeBlock, merge_attrs(defaults, attrs), actor)
  end

  @doc "Reads the knowledge block bindings of `chat` (a record or an id) ordered by sequence."
  def chat_block_bindings!(actor, chat) do
    chat_id = id_of(chat)

    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: actor)
  end
end
