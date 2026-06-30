defmodule IntellectualClubWeb.Bff.ImageControllerHelpers do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  alias IntellectualClub.Files

  @max_upload_bytes 15 * 1024 * 1024

  def validate_image_upload(nil), do: {:error, "File is required."}

  def validate_image_upload(%Plug.Upload{} = upload) do
    with {:ok, payload} <- File.read(upload.path) do
      mime_type = upload.content_type |> to_string() |> String.trim()
      filename = upload.filename |> to_string() |> String.trim()

      cond do
        byte_size(payload) == 0 ->
          {:error, "File is empty."}

        byte_size(payload) > @max_upload_bytes ->
          {:error, "File is too large (max 15 MB)."}

        not String.starts_with?(mime_type, "image/") ->
          {:error, "Unsupported file type. Expected image/* Content-Type."}

        filename == "" ->
          {:error, "Filename is required."}

        true ->
          {:ok, %{filename: filename, mime_type: mime_type, payload: payload}}
      end
    else
      {:error, _reason} -> {:error, "Failed to read uploaded file."}
    end
  end

  def validate_image_upload(_other), do: {:error, "File is required."}

  def render_validation_error(conn, message) when is_binary(message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  def render_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  def render_action_error(conn, error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error_message(error)})
  end

  def send_image(conn, file_id) when is_integer(file_id) do
    send_stored_file(conn, file_id, disposition: :inline)
  end

  def send_image(conn, _file_id), do: render_not_found(conn)

  def send_stored_file(conn, file_id, opts \\ [])

  def send_stored_file(conn, file_id, opts) when is_integer(file_id) and is_list(opts) do
    case Files.load_path(file_id) do
      {:ok, {file, path}} ->
        send_file_path(conn, file, path, opts)

      {:error, _reason} ->
        render_not_found(conn)
    end
  end

  def send_stored_file(conn, _file_id, _opts), do: render_not_found(conn)

  def send_file_path(conn, file, path, opts \\ [])

  def send_file_path(conn, file, path, opts)
      when is_map(file) and is_binary(path) and is_list(opts) do
    conn = prepare_file_response(conn, file, opts)
    etag = ~s("#{Map.get(file, :sha256) || Map.get(file, "sha256")}")

    if etag_matches?(conn, etag) do
      send_resp(conn, :not_modified, "")
    else
      send_file(conn, :ok, path)
    end
  end

  def send_loaded_file(conn, file, payload, opts \\ [])

  def send_loaded_file(conn, file, payload, opts) when is_map(file) and is_binary(payload) do
    conn = prepare_file_response(conn, file, opts)
    etag = ~s("#{Map.get(file, :sha256) || Map.get(file, "sha256")}")

    if etag_matches?(conn, etag) do
      send_resp(conn, :not_modified, "")
    else
      send_resp(conn, :ok, payload)
    end
  end

  defp prepare_file_response(conn, file, opts) do
    mime_type =
      Map.get(file, :mime_type) || Map.get(file, "mime_type") || "application/octet-stream"

    filename = Map.get(file, :filename) || Map.get(file, "filename")
    disposition = Keyword.get(opts, :disposition, :attachment)
    etag = ~s("#{Map.get(file, :sha256) || Map.get(file, "sha256")}")

    conn
    |> put_resp_content_type(mime_type)
    |> put_resp_header("cache-control", "private, no-cache")
    |> put_resp_header("etag", etag)
    |> maybe_put_content_disposition(filename, disposition)
  end

  defp maybe_put_content_disposition(conn, filename, disposition) do
    safe_name = filename |> to_string() |> String.replace("\"", "")

    value =
      case disposition do
        :inline -> "inline"
        _other -> "attachment"
      end

    if safe_name == "" do
      conn
    else
      put_resp_header(conn, "content-disposition", ~s(#{value}; filename="#{safe_name}"))
    end
  end

  defp etag_matches?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.any?(fn value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.any?(&(&1 == etag or &1 == "*"))
    end)
  end

  defp error_message(%Ash.Error.Invalid{errors: errors}) when is_list(errors) and errors != [] do
    errors
    |> Enum.map(&Exception.message/1)
    |> Enum.join(", ")
  end

  defp error_message(error) when is_exception(error), do: Exception.message(error)
  defp error_message(_error), do: "Request failed."
end
