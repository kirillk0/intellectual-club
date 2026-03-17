defmodule IntellectualClubWeb.Bff.ChatKnowledgeBlocksController do
  @moduledoc """
  CRUD endpoints for chat-level knowledge block bindings.

  The SPA uses these to manage per-chat prompt blocks and ordering.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  def create(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = Helpers.parse_optional_integer(Map.get(params, "chat_id"))
      knowledge_block_id = Helpers.parse_optional_integer(Map.get(params, "knowledge_block_id"))

      enabled =
        case Map.get(params, "enabled", true) do
          false -> false
          "false" -> false
          _ -> true
        end

      sequence =
        case Helpers.parse_optional_integer(Map.get(params, "sequence")) do
          nil -> 0
          value -> value
        end

      cond do
        not is_integer(chat_id) ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "chat_id is required"})

        not is_integer(knowledge_block_id) ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "knowledge_block_id is required"})

        true ->
          binding =
            ChatKnowledgeBlock
            |> Ash.Changeset.for_create(
              :create,
              %{
                chat_id: chat_id,
                knowledge_block_id: knowledge_block_id,
                enabled: enabled,
                sequence: sequence
              },
              actor: actor
            )
            |> Ash.create!()
            |> Ash.load!([knowledge_block: [:image]], actor: actor)

          json(conn, %{chat_knowledge_block: Serializer.chat_block_binding(binding)})
      end
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      binding_id = String.to_integer(id)
      binding = Ash.get!(ChatKnowledgeBlock, binding_id, actor: actor)

      patch =
        params
        |> Map.take(~w(enabled sequence))
        |> Enum.reduce(%{}, fn
          {"enabled", value}, acc ->
            enabled =
              case value do
                false -> false
                "false" -> false
                _ -> true
              end

            Map.put(acc, :enabled, enabled)

          {"sequence", value}, acc ->
            case Helpers.parse_optional_integer(value) do
              nil -> acc
              seq -> Map.put(acc, :sequence, seq)
            end

          _other, acc ->
            acc
        end)

      binding =
        binding
        |> Ash.Changeset.for_update(:update, patch, actor: actor)
        |> Ash.update!()
        |> Ash.load!([knowledge_block: [:image]], actor: actor)

      json(conn, %{chat_knowledge_block: Serializer.chat_block_binding(binding)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      binding_id = String.to_integer(id)
      binding = Ash.get!(ChatKnowledgeBlock, binding_id, actor: actor)
      _ = Ash.destroy!(binding, actor: actor)
      json(conn, %{status: "ok"})
    end
  end
end
