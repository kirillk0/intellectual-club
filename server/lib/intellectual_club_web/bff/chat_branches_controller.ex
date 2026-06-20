defmodule IntellectualClubWeb.Bff.ChatBranchesController do
  @moduledoc """
  Chat branch navigation BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.BranchMove
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.ChatPayloads
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  def switch(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      message_id = Helpers.parse_optional_integer(Map.get(params, "message_id"))
      opts = ChatParams.switch_params(params)

      with {:ok, chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
           message_id when is_integer(message_id) <- message_id,
           {:ok, _chat} <-
             chat
             |> Ash.Changeset.for_update(
               :switch_branch,
               Map.put(opts, :message_id, message_id),
               actor: actor
             )
             |> Ash.update() do
        json(conn, %{branch: ChatPayloads.branch_payload(chat_id, actor)})
      else
        nil ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "message_id is required"})

        {:error, :forbidden} ->
          ChatAccess.render_error(conn, :forbidden)

        {:error, :not_found} ->
          ChatAccess.render_error(conn, :not_found)

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to switch branch: #{inspect(reason)}"})
      end
    end
  end

  def activate(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      message_id = Helpers.parse_optional_integer(Map.get(params, "message_id"))

      with {:ok, chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
           message_id when is_integer(message_id) <- message_id,
           {:ok, _chat} <-
             chat
             |> Ash.Changeset.for_update(:activate_branch, %{message_id: message_id},
               actor: actor
             )
             |> Ash.update() do
        json(conn, %{branch: ChatPayloads.branch_payload(chat_id, actor)})
      else
        nil ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "message_id is required"})

        {:error, :forbidden} ->
          ChatAccess.render_error(conn, :forbidden)

        {:error, :not_found} ->
          ChatAccess.render_error(conn, :not_found)

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to activate branch: #{inspect(reason)}"})
      end
    end
  end

  def move_to_new_chat(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id) do
      message_id = Helpers.parse_optional_integer(Map.get(params, "message_id"))

      with {:ok, chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
           message_id when is_integer(message_id) <- message_id,
           {:ok, %{chat: target}} <- BranchMove.move_branch_to_new_chat(chat, message_id, actor) do
        {target_messages, target_meta_by_id} = ChatPayloads.load_branch(target.id, actor)

        json(conn, %{
          chat: Serializer.chat_detail(target),
          branch: ChatPayloads.serialize_branch(target_messages, target_meta_by_id, actor),
          source_branch: ChatPayloads.branch_payload(chat_id, actor)
        })
      else
        nil ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "message_id is required"})

        {:error, :no_siblings} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Message does not have sibling branches."})

        {:error, :branch_has_generating_message} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Cannot move a branch with a generating message."})

        {:error, :message_not_found} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Message does not belong to this chat."})

        {:error, :forbidden} ->
          ChatAccess.render_error(conn, :forbidden)

        {:error, :not_found} ->
          ChatAccess.render_error(conn, :not_found)

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to move branch: #{inspect(reason)}"})
      end
    else
      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end
end
