defmodule IntellectualClubWeb.Bff.ChatUploadsController do
  @moduledoc """
  Chunked upload API for chat attachments.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.ChatUploadSession
  alias IntellectualClub.Chat.Uploads
  alias IntellectualClubWeb.Bff.Helpers

  @body_read_length_bytes 1 * 1024 * 1024

  def create(conn, %{"chat_id" => chat_id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         chat_id when is_integer(chat_id) <- Helpers.parse_optional_integer(chat_id),
         {:ok, upload} <- Uploads.start_upload(chat_id, actor, params) do
      json(conn, %{upload: serialize_upload(upload)})
    else
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "chat_id is required."})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Upload not found."})

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(error)})
    end
  end

  def show(conn, %{"chat_id" => chat_id, "upload_id" => upload_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         chat_id when is_integer(chat_id) <- Helpers.parse_optional_integer(chat_id),
         {:ok, upload} <- Uploads.get_upload(chat_id, upload_id, actor) do
      json(conn, %{upload: serialize_upload(upload)})
    else
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "chat_id is required."})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Upload not found."})

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(error)})
    end
  end

  def append_chunk(conn, %{"chat_id" => chat_id, "upload_id" => upload_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         chat_id when is_integer(chat_id) <- Helpers.parse_optional_integer(chat_id),
         {:ok, upload} <- Uploads.get_upload(chat_id, upload_id, actor),
         offset when is_integer(offset) <-
           conn
           |> get_req_header("x-upload-offset")
           |> List.first()
           |> Helpers.parse_optional_integer() do
      case read_request_body(conn, upload.chunk_size_bytes) do
        {:ok, conn, body} ->
          case Uploads.append_chunk(chat_id, upload_id, offset, body, actor) do
            {:ok, updated} ->
              json(conn, %{upload: serialize_upload(updated)})

            {:error, {:offset_mismatch, next_offset}} ->
              conn
              |> put_status(:conflict)
              |> json(%{error: "Upload offset mismatch.", next_offset: next_offset})

            {:error, :not_found} ->
              conn
              |> put_status(:not_found)
              |> json(%{error: "Upload not found."})

            {:error, message} when is_binary(message) ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: message})

            {:error, error} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: inspect(error)})
          end

        {:error, conn, message} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: message})
      end
    else
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Invalid upload offset."})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Upload not found."})

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(error)})
    end
  end

  def delete(conn, %{"chat_id" => chat_id, "upload_id" => upload_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         chat_id when is_integer(chat_id) <- Helpers.parse_optional_integer(chat_id),
         {:ok, upload} <- Uploads.abort_upload(chat_id, upload_id, actor) do
      json(conn, %{upload: serialize_upload(upload)})
    else
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "chat_id is required."})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Upload not found."})

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: message})

      {:error, error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(error)})
    end
  end

  defp serialize_upload(%ChatUploadSession{} = upload) do
    %{
      upload_id: upload.external_id,
      filename: upload.filename,
      mime_type: upload.mime_type,
      size_bytes: upload.size_bytes,
      uploaded_bytes: upload.uploaded_bytes,
      chunk_size_bytes: upload.chunk_size_bytes,
      status: Atom.to_string(upload.status),
      expires_at: upload.expires_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp read_request_body(conn, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    read_request_body(conn, [], 0, max_bytes)
  end

  defp read_request_body(conn, acc, total_bytes, max_bytes) do
    case Plug.Conn.read_body(conn,
           length: max_bytes + 1,
           read_length: min(max_bytes + 1, @body_read_length_bytes),
           read_timeout: 30_000
         ) do
      {:ok, chunk, conn} ->
        total_bytes = total_bytes + byte_size(chunk)
        body = IO.iodata_to_binary(Enum.reverse([chunk | acc]))

        cond do
          total_bytes == 0 ->
            {:error, conn, "Upload chunk is empty."}

          total_bytes > max_bytes ->
            {:error, conn, "Upload chunk exceeds the allowed chunk size."}

          true ->
            {:ok, conn, body}
        end

      {:more, chunk, conn} ->
        total_bytes = total_bytes + byte_size(chunk)

        if total_bytes > max_bytes do
          case drain_request_body(conn) do
            {:ok, conn} ->
              {:error, conn, "Upload chunk exceeds the allowed chunk size."}

            {:error, conn, reason} ->
              {:error, conn, reason}
          end
        else
          read_request_body(conn, [chunk | acc], total_bytes, max_bytes)
        end

      {:error, reason} ->
        {:error, conn, "Failed to read request body: #{inspect(reason)}"}
    end
  end

  defp drain_request_body(conn) do
    case Plug.Conn.read_body(conn,
           length: @body_read_length_bytes,
           read_length: @body_read_length_bytes,
           read_timeout: 30_000
         ) do
      {:ok, _chunk, conn} ->
        {:ok, conn}

      {:more, _chunk, conn} ->
        drain_request_body(conn)

      {:error, reason} ->
        {:error, conn, "Failed to read request body: #{inspect(reason)}"}
    end
  end
end
