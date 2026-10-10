defmodule IntellectualClubWeb.Bff.ChatFilesController do
  @moduledoc """
  Authenticated attachment previews, downloads and inline images referenced by file UUID.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.{ChatMessageContent, ContentFiles, Media}
  alias IntellectualClubWeb.Bff.{Helpers, ImageControllerHelpers, Serializer}

  def show(conn, %{"file_external_id" => external_id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, %ChatMessageContent{} = content} <- load_content(external_id, actor),
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

  def attachment(conn, %{"file_external_id" => external_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, %ChatMessageContent{} = content} <-
           load_content(external_id, actor, [:file, chat_message_item: :chat_message_step]) do
      json(conn, %{
        message_id: content.chat_message_item.chat_message_step.chat_message_id,
        content: Serializer.content(content)
      })
    else
      {:error, %Plug.Conn{} = conn} -> conn
      _other -> ImageControllerHelpers.render_not_found(conn)
    end
  end

  defp load_content(external_id, actor, load \\ []) do
    with {:ok, external_id} <- Ecto.UUID.cast(external_id) do
      ChatMessageContent
      |> Ash.Query.for_read(:by_file_external_id, %{file_external_id: external_id}, actor: actor)
      |> Ash.Query.load(load)
      |> Ash.read_one(actor: actor)
    end
  end
end
