defmodule IntellectualClubWeb.Bff.ChatBranchesController do
  @moduledoc """
  Chat branch navigation BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.ChatPayloads
  alias IntellectualClubWeb.Bff.Helpers

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
end
