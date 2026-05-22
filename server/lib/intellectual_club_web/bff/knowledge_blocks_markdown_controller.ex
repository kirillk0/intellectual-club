defmodule IntellectualClubWeb.Bff.KnowledgeBlocksMarkdownController do
  @moduledoc """
  BFF endpoints for Markdown import and export of knowledge blocks.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Knowledge.MarkdownTransfer
  alias IntellectualClubWeb.Bff.Helpers

  def export(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         tag_id when is_integer(tag_id) <- Helpers.parse_optional_integer(params["tag_id"]),
         {:ok, block_ids} <- parse_block_ids(params["block_ids"]),
         {:ok, archive} <- MarkdownTransfer.export_archive(tag_id, block_ids, actor) do
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header("content-disposition", content_disposition(archive.filename))
      |> send_resp(:ok, archive.payload)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      nil ->
        render_error(conn, "Tag is required.")

      {:error, message} when is_binary(message) ->
        render_error(conn, message)

      {:error, error} ->
        render_error(conn, inspect(error))
    end
  end

  def preview(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         tag_id when is_integer(tag_id) <- Helpers.parse_optional_integer(params["tag_id"]),
         {:ok, payload} <- MarkdownTransfer.preview_import(tag_id, extract_uploads(params), actor) do
      json(conn, payload)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      nil ->
        render_error(conn, "Tag is required.")

      {:error, message} when is_binary(message) ->
        render_error(conn, message)

      {:error, error} ->
        render_error(conn, inspect(error))
    end
  end

  def import(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         tag_id when is_integer(tag_id) <- Helpers.parse_optional_integer(params["tag_id"]),
         {:ok, decisions} <- decode_decisions(params["decisions"]),
         {:ok, payload} <-
           MarkdownTransfer.import_entries(
             tag_id,
             extract_uploads(params),
             params["version"],
             decisions,
             actor
           ) do
      json(conn, payload)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      nil ->
        render_error(conn, "Tag is required.")

      {:error, message} when is_binary(message) ->
        render_error(conn, message)

      {:error, error} ->
        render_error(conn, inspect(error))
    end
  end

  defp parse_block_ids(ids) when is_list(ids) do
    {:ok, ids}
  end

  defp parse_block_ids(id) when is_integer(id) or is_binary(id) do
    {:ok, [id]}
  end

  defp parse_block_ids(_other), do: {:ok, []}

  defp extract_uploads(params) when is_map(params) do
    []
    |> append_uploads(Map.get(params, "files"))
    |> append_uploads(Map.get(params, "files[]"))
    |> append_uploads(Map.get(params, "file"))
  end

  defp append_uploads(uploads, nil), do: uploads

  defp append_uploads(uploads, values) when is_list(values) do
    uploads ++ Enum.filter(values, &match?(%Plug.Upload{}, &1))
  end

  defp append_uploads(uploads, %Plug.Upload{} = upload), do: uploads ++ [upload]
  defp append_uploads(uploads, _other), do: uploads

  defp decode_decisions(nil), do: {:ok, %{}}
  defp decode_decisions(decisions) when is_map(decisions), do: {:ok, decisions}

  defp decode_decisions(decisions) when is_binary(decisions) do
    case Jason.decode(decisions) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, "Import decisions must be a JSON object."}
      {:error, _error} -> {:error, "Import decisions must be valid JSON."}
    end
  end

  defp decode_decisions(_decisions), do: {:error, "Import decisions must be a JSON object."}

  defp content_disposition(filename) do
    safe_filename = filename |> to_string() |> String.replace("\"", "")
    ~s(attachment; filename="#{safe_filename}")
  end

  defp render_error(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end
end
