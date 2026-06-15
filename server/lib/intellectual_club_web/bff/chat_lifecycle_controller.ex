defmodule IntellectualClubWeb.Bff.ChatLifecycleController do
  @moduledoc """
  Chat lifecycle BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.Chat
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  def create(conn, %{"copy_from_chat_id" => source_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, source_chat_id} <- ChatParams.resource_id(source_id),
         {:ok, %Chat{}} <- ChatAccess.fetch_readable_chat(source_chat_id, actor),
         {:ok, %Chat{} = chat} <-
           Chat
           |> Ash.Changeset.for_create(:copy, %{id: source_chat_id}, actor: actor)
           |> Ash.create() do
      json(conn, %{chat: Serializer.chat_detail(chat)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end

  def create(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat =
        Chat
        |> Ash.Changeset.for_create(:create, ChatParams.create_chat_attrs(params), actor: actor)
        |> Ash.create!()

      json(conn, %{chat: Serializer.chat_detail(chat)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)

      with {:ok, chat} <- ChatAccess.fetch_owned_chat(chat_id, actor) do
        chat =
          chat
          |> Ash.Changeset.for_update(:update, ChatParams.chat_patch(params), actor: actor)
          |> Ash.update!()

        json(conn, %{chat: Serializer.chat_detail(chat)})
      else
        {:error, error} -> ChatAccess.render_error(conn, error)
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)

      with {:ok, chat} <- ChatAccess.fetch_owned_chat(chat_id, actor) do
        case Ash.destroy(chat, actor: actor) do
          :ok ->
            json(conn, %{status: "ok"})

          {:ok, _chat} ->
            json(conn, %{status: "ok"})

          {:error, %Ash.Error.Forbidden{} = error} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Forbidden: #{Exception.message(error)}"})

          {:error, %Ash.Error.Invalid{} = error} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Invalid request: #{Exception.message(error)}"})

          {:error, error} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to delete chat: #{inspect(error)}"})
        end
      else
        {:error, error} -> ChatAccess.render_error(conn, error)
      end
    end
  end

  def continue_conversation(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, chat} <-
           Chat
           |> Ash.Changeset.for_create(:continue, %{id: chat_id}, actor: actor)
           |> Ash.create() do
      json(conn, %{chat: Serializer.chat_detail(chat)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end
end
