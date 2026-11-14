defmodule IntellectualClubWeb.Bff.ChatDraftsController do
  @moduledoc "Private, versioned chat composer text."
  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.{ChatDraft, ChatDraftAttachment}
  alias IntellectualClubWeb.Bff.{ChatAccess, ChatParams, Helpers}

  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, draft} <- ChatDraft.get(chat_id, actor) do
      conn |> put_resp_header("cache-control", "no-store") |> json(%{draft: draft})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, error} -> ChatAccess.render_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, result} <- ChatDraft.save(chat_id, params, actor) do
      conn = put_resp_header(conn, "cache-control", "no-store")

      case result do
        %{error: :not_found} ->
          ChatAccess.render_error(conn, :not_found)

        %{error: error} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: error})

        %{draft: draft, conflict: conflict} ->
          conn |> put_status(if(conflict, do: :conflict, else: :ok)) |> json(%{draft: draft})
      end
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, error} -> ChatAccess.render_error(conn, error)
    end
  end

  def attachments(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, attachments} <- ChatDraftAttachment.list(chat_id, actor) do
      conn |> put_resp_header("cache-control", "no-store") |> json(%{attachments: attachments})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, error} -> ChatAccess.render_error(conn, error)
    end
  end

  def attachment(conn, %{"id" => id, "attachment_id" => attachment_id, "variant" => variant}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, attachment_id} <- Ecto.UUID.cast(attachment_id),
         {:ok, {file, path}} <-
           ChatDraftAttachment.load_file(chat_id, attachment_id, variant, actor) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> IntellectualClubWeb.Bff.ImageControllerHelpers.send_file_path(file, path,
        disposition: :attachment
      )
    else
      {:error, %Plug.Conn{} = conn} -> conn
      _ -> ChatAccess.render_error(conn, :not_found)
    end
  end

  def mutate_attachment(conn, %{"id" => id, "attachment_id" => attachment_id} = params) do
    operation =
      case {conn.method, params["operation"]} do
        {"DELETE", _} -> :delete
        {_, "start"} -> :start
        {_, "finish"} -> :finish
        {_, "select"} -> :select
        _ -> nil
      end

    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id),
         {:ok, attachment_id} <- Ecto.UUID.cast(attachment_id),
         true <- not is_nil(operation),
         {:ok, result} <-
           ChatDraftAttachment.mutate(chat_id, attachment_id, operation, params, actor) do
      conn |> put_resp_header("cache-control", "no-store") |> json(result)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} when is_binary(error) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: error})

      {:error, error} ->
        ChatAccess.render_error(conn, error)

      _ ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid attachment request."})
    end
  end
end
