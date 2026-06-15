defmodule IntellectualClubWeb.Bff.ChatGenerationController do
  @moduledoc """
  Chat generation orchestration BFF endpoints.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatGenerationFlow
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.Helpers

  def send(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)

      case ChatGenerationFlow.send_message(chat_id, params, actor) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, :forbidden} ->
          ChatAccess.render_error(conn, :forbidden)

        {:error, :not_found} ->
          ChatAccess.render_error(conn, :not_found)

        {:error, {:user_message, error}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to create user message: #{inspect(error)}"})

        {:error, error_message} when is_binary(error_message) ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: error_message})

        other ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to start generation: #{inspect(other)}"})
      end
    end
  end

  def generate(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)

      case ChatGenerationFlow.generate(chat_id, params, actor) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, error} when error in [:forbidden, :not_found] ->
          ChatAccess.render_error(conn, error)

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to start generation: #{inspect(reason)}"})
      end
    end
  end

  def branch_to_new_chat(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id) do
      message_id = Helpers.parse_optional_integer(Map.get(params, "message_id"))

      case ChatGenerationFlow.branch_to_new_chat(chat_id, message_id, params, actor) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, :message_required} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "message_id is required"})

        {:error, :message_not_in_active_branch} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Message is not in the active branch."})

        {:error, :empty_user_message} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "User branch message cannot be empty."})

        {:error, %Plug.Conn{} = conn} ->
          conn

        {:error, error_message} when is_binary(error_message) ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: error_message})

        {:error, error} ->
          ChatAccess.render_error(conn, error)
      end
    else
      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end

  def handoff(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(id) do
      case ChatGenerationFlow.manual_handoff(chat_id, actor) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, %Plug.Conn{} = conn} ->
          conn

        {:error, error} ->
          ChatAccess.render_error(conn, error)
      end
    else
      {:error, error} ->
        ChatAccess.render_error(conn, error)
    end
  end
end
