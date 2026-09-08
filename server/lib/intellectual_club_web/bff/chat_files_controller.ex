defmodule IntellectualClubWeb.Bff.ChatFilesController do
  @moduledoc """
  Authenticated downloads and inline images referenced by file UUID in chat Markdown.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.{ChatMessageContent, ContentFiles, Media}
  alias IntellectualClubWeb.Bff.{Helpers, ImageControllerHelpers}

  def show(conn, %{"file_external_id" => external_id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, external_id} <- Ecto.UUID.cast(external_id),
         {:ok, %ChatMessageContent{} = content} <-
           ChatMessageContent
           |> Ash.Query.for_read(:by_file_external_id, %{file_external_id: external_id},
             actor: actor
           )
           |> Ash.read_one(actor: actor),
         {:ok, {_content, file, path}} <- ContentFiles.load_path_for_content(content) do
      inline? = Map.get(params, "inline") == "1"

      if inline? and not Media.image_mime_type?(file.mime_type) do
        conn
        |> put_status(:unsupported_media_type)
        |> json(%{error: "File is not an image"})
      else
        ImageControllerHelpers.send_file_path(conn, file, path,
          disposition: if(inline?, do: :inline, else: :attachment)
        )
      end
    else
      {:error, %Plug.Conn{} = conn} -> conn
      _other -> ImageControllerHelpers.render_not_found(conn)
    end
  end
end
