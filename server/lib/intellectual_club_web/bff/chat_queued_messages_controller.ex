defmodule IntellectualClubWeb.Bff.ChatQueuedMessagesController do
  @moduledoc """
  Durable chat queue mutations and attachment transport.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Chat.QueuedMessageContent
  alias IntellectualClub.Chat.QueuedMessages
  alias IntellectualClub.Files
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.ChatAttachments
  alias IntellectualClubWeb.Bff.ChatParams
  alias IntellectualClubWeb.Bff.ChatQueuedMessagePayload
  alias IntellectualClubWeb.Bff.ChatUploadPolicy
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.ImageControllerHelpers

  @dispatcher IntellectualClub.Generation.QueueDispatcher

  def create(conn, %{"chat_id" => chat_id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- ChatParams.resource_id(chat_id),
         {:ok, _chat} <- ChatAccess.fetch_owned_chat(chat_id, actor),
         upload_policy = ChatUploadPolicy.load_for_chat(chat_id, actor),
         {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params),
         :ok <- validate_create_payload(params, prepared_uploads),
         {:ok, queued_message} <-
           ChatAttachments.with_prepared_file_ids(
             chat_id,
             actor,
             upload_policy,
             prepared_uploads,
             fn file_ids ->
               QueuedMessages.enqueue_follow_up(
                 chat_id,
                 %{content: Map.get(params, "content", ""), file_ids: file_ids},
                 actor
               )
             end
           ) do
      kick_dispatcher(chat_id)

      conn
      |> put_status(:created)
      |> json(%{queued_message: ChatQueuedMessagePayload.queued_message(queued_message)})
    else
      {:error, error} -> render_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, queued_message_id} <- ChatParams.resource_id(id),
         {:ok, queued_message} <- QueuedMessages.get(queued_message_id, actor),
         upload_policy = ChatUploadPolicy.load_for_chat(queued_message.chat_id, actor),
         {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params),
         {:ok, remove_content_ids} <- parse_remove_content_ids(params),
         {:ok, updated} <-
           ChatAttachments.with_prepared_file_ids(
             queued_message.chat_id,
             actor,
             upload_policy,
             prepared_uploads,
             fn file_ids ->
               attrs =
                 %{file_ids: file_ids, remove_content_ids: remove_content_ids}
                 |> maybe_put_content(params)

               QueuedMessages.update(queued_message.id, attrs, actor)
             end
           ) do
      json(conn, %{queued_message: ChatQueuedMessagePayload.queued_message(updated)})
    else
      {:error, error} -> render_error(conn, error)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, queued_message_id} <- ChatParams.resource_id(id),
         {:ok, canceled} <- QueuedMessages.cancel(queued_message_id, actor) do
      json(conn, %{queued_message: ChatQueuedMessagePayload.queued_message(canceled)})
    else
      {:error, error} -> render_error(conn, error)
    end
  end

  def send_next(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, queued_message_id} <- ChatParams.resource_id(id),
         {:ok, queued_message} <- QueuedMessages.send_next(queued_message_id, actor) do
      kick_dispatcher(queued_message.chat_id)
      json(conn, %{queued_message: ChatQueuedMessagePayload.queued_message(queued_message)})
    else
      {:error, error} -> render_error(conn, error)
    end
  end

  def content_file(conn, %{"id" => id, "content_id" => content_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, queued_message_id} <- ChatParams.resource_id(id),
         {:ok, content_id} <- ChatParams.resource_id(content_id),
         {:ok, queued_message} <- QueuedMessages.get(queued_message_id, actor),
         %QueuedMessageContent{kind: :media, file_id: file_id} <-
           Enum.find(queued_message.contents, &(&1.id == content_id)),
         true <- is_integer(file_id),
         {:ok, {file, path}} <- Files.load_path(file_id) do
      disposition = if Media.image_mime_type?(file.mime_type), do: :inline, else: :attachment
      ImageControllerHelpers.send_file_path(conn, file, path, disposition: disposition)
    else
      {:error, error} when error in [:forbidden, :not_found] ->
        render_error(conn, error)

      _other ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Queued attachment not found"})
    end
  end

  defp validate_create_payload(params, prepared_uploads) do
    content = params |> Map.get("content", "") |> to_string()

    has_attachments? =
      Enum.any?([:upload_ids, :copy_content_ids, :legacy_uploads], fn key ->
        List.wrap(Map.get(prepared_uploads, key, [])) != []
      end)

    if content != "" or has_attachments?, do: :ok, else: {:error, :empty_message}
  end

  defp parse_remove_content_ids(params) do
    value =
      cond do
        Map.has_key?(params, "remove_content_ids") ->
          Map.get(params, "remove_content_ids")

        Map.has_key?(params, "remove_content_ids_json") ->
          decode_json_list(Map.get(params, "remove_content_ids_json"))

        true ->
          []
      end

    value
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, ids} ->
      case Helpers.parse_optional_integer(raw) do
        id when is_integer(id) and id > 0 -> {:cont, {:ok, Enum.uniq(ids ++ [id])}}
        _other -> {:halt, {:error, :invalid_remove_content_ids}}
      end
    end)
  end

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, values} when is_list(values) -> values
      _other -> [:invalid]
    end
  end

  defp decode_json_list(value) when is_list(value), do: value
  defp decode_json_list(_value), do: [:invalid]

  defp maybe_put_content(attrs, params) do
    if Map.has_key?(params, "content") do
      Map.put(attrs, :content, Map.get(params, "content", ""))
    else
      attrs
    end
  end

  defp kick_dispatcher(chat_id) do
    if Code.ensure_loaded?(@dispatcher) and function_exported?(@dispatcher, :kick, 1) do
      _ = apply(@dispatcher, :kick, [chat_id])
    end

    :ok
  end

  defp render_error(conn, :forbidden), do: ChatAccess.render_error(conn, :forbidden)
  defp render_error(conn, :not_found), do: ChatAccess.render_error(conn, :not_found)

  defp render_error(conn, error)
       when error in [
              :already_dispatched,
              :generation_active,
              :not_queue_head
            ] do
    conn
    |> put_status(:conflict)
    |> json(%{code: Atom.to_string(error), error: error_message(error)})
  end

  defp render_error(conn, error)
       when error in [
              :empty_message,
              :invalid_file_ids,
              :invalid_remove_content_ids,
              :follow_up_required,
              :steer_attachments_not_supported
            ] do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{code: Atom.to_string(error), error: error_message(error)})
  end

  defp render_error(conn, error) when is_binary(error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error})
  end

  defp render_error(conn, %Ash.Error.Forbidden{}), do: render_error(conn, :forbidden)
  defp render_error(conn, %Ash.Error.Query.NotFound{}), do: render_error(conn, :not_found)

  defp render_error(conn, error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Queue mutation failed: #{inspect(error)}"})
  end

  defp error_message(:empty_message), do: "A queued message must contain text or an attachment."
  defp error_message(:invalid_file_ids), do: "Invalid queued attachment ids."
  defp error_message(:invalid_remove_content_ids), do: "Some queued attachments cannot be edited."
  defp error_message(:follow_up_required), do: "Only follow-up messages can be sent next."

  defp error_message(:steer_attachments_not_supported),
    do: "Steering messages do not support attachments."

  defp error_message(:already_dispatched), do: "This queued message is already finished."
  defp error_message(:generation_active), do: "Wait for the active generation to finish."
  defp error_message(:not_queue_head), do: "Only the first follow-up can be sent next."
end
