defmodule IntellectualClubWeb.Bff.ChatAttachments do
  @moduledoc """
  Helpers for preparing chat attachment file ids from uploads, copies, and legacy multipart files.
  """

  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.Uploads
  alias IntellectualClub.Files
  alias IntellectualClubWeb.Bff.ChatUploadPolicy
  alias IntellectualClubWeb.Bff.Helpers

  @type prepared_uploads :: %{
          upload_ids: [String.t()],
          copy_content_ids: [integer()],
          legacy_uploads: [Plug.Upload.t()]
        }

  @spec parse_prepared_uploads(map()) :: {:ok, prepared_uploads()} | {:error, String.t()}
  def parse_prepared_uploads(params) when is_map(params) do
    with {:ok, upload_ids} <- parse_upload_ids(params),
         {:ok, copy_content_ids} <- parse_copy_content_ids(params),
         {:ok, legacy_uploads} <- parse_legacy_uploads(params) do
      {:ok,
       %{
         upload_ids: upload_ids,
         copy_content_ids: copy_content_ids,
         legacy_uploads: legacy_uploads
       }}
    end
  end

  @spec with_prepared_file_ids(
          integer(),
          term(),
          ChatUploadPolicy.t(),
          prepared_uploads(),
          ([integer()] -> {:ok, term()} | {:error, term()})
        ) :: {:ok, term()} | {:error, term()}
  def with_prepared_file_ids(chat_id, actor, upload_policy, prepared, fun)
      when is_integer(chat_id) and is_map(upload_policy) and is_function(fun, 1) do
    upload_ids = Map.get(prepared, :upload_ids, [])
    copy_content_ids = Map.get(prepared, :copy_content_ids, [])
    legacy_uploads = Map.get(prepared, :legacy_uploads, [])

    with {:ok, materialized} <- materialize_uploads(chat_id, upload_ids, actor) do
      case duplicate_copied_attachments(copy_content_ids, chat_id, actor) do
        {:ok, copied_file_ids} ->
          case persist_legacy_uploads(legacy_uploads, upload_policy) do
            {:ok, legacy_file_ids} ->
              file_ids =
                copied_file_ids ++ Enum.map(materialized.files, & &1.id) ++ legacy_file_ids

              case execute_callback(fun, file_ids) do
                {:ok, result} ->
                  Uploads.finalize_materialized_uploads(materialized)
                  {:ok, result}

                {:error, reason} ->
                  rollback_created_files(copied_file_ids ++ legacy_file_ids)
                  Uploads.rollback_materialized_uploads(materialized)
                  {:error, reason}
              end

            {:error, reason} ->
              rollback_created_files(copied_file_ids)
              Uploads.rollback_materialized_uploads(materialized)
              {:error, reason}
          end

        {:error, reason} ->
          Uploads.rollback_materialized_uploads(materialized)
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_callback(fun, file_ids) do
    try do
      case fun.(file_ids) do
        {:ok, _result} = ok -> ok
        {:error, _reason} = error -> error
        other -> {:error, "Unexpected attachment callback result: #{inspect(other)}"}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, value -> {:error, "Attachment callback #{kind}: #{inspect(value)}"}
    end
  end

  defp materialize_uploads(_chat_id, [], _actor), do: {:ok, %{sessions: [], files: []}}

  defp materialize_uploads(chat_id, upload_ids, actor) do
    Uploads.materialize_uploads(chat_id, upload_ids, actor)
  end

  defp duplicate_copied_attachments([], _chat_id, _actor), do: {:ok, []}

  defp duplicate_copied_attachments(content_ids, chat_id, actor) do
    Enum.reduce_while(content_ids, {:ok, []}, fn content_id, {:ok, acc} ->
      with {:ok, content} <- load_copyable_content(content_id, chat_id, actor),
           {:ok, duplicated_file} <- Files.duplicate_file(content.file_id) do
        {:cont, {:ok, acc ++ [duplicated_file.id]}}
      else
        {:error, reason} ->
          rollback_created_files(acc)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp load_copyable_content(content_id, chat_id, actor) do
    load = [chat_message_item: [chat_message_step: [:chat_message]]]

    case Ash.get(ChatMessageContent, content_id, actor: actor, load: load) do
      {:ok, %ChatMessageContent{} = content} ->
        item = Map.get(content, :chat_message_item)
        step = if is_map(item), do: Map.get(item, :chat_message_step), else: nil
        message = step && Map.get(step, :chat_message)

        cond do
          content.kind != :media ->
            {:error, "Only media attachments can be copied."}

          not is_integer(content.file_id) ->
            {:error, "Attachment file is missing."}

          is_nil(message) or message.chat_id != chat_id ->
            {:error, "Some attachments cannot be copied."}

          true ->
            {:ok, content}
        end

      {:ok, nil} ->
        {:error, "Some attachments cannot be copied."}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        {:error, "Some attachments cannot be copied."}

      {:error, error} ->
        {:error, error}
    end
  end

  defp persist_legacy_uploads([], _upload_policy), do: {:ok, []}

  defp persist_legacy_uploads(uploads, upload_policy)
       when is_list(uploads) and is_map(upload_policy) do
    Enum.reduce_while(uploads, {:ok, []}, fn
      %Plug.Upload{} = upload, {:ok, acc} ->
        with :ok <- ChatUploadPolicy.validate_upload(upload, upload_policy),
             {:ok, file} <-
               Files.create_from_path(upload.filename, upload.content_type, upload.path) do
          {:cont, {:ok, acc ++ [file.id]}}
        else
          {:error, reason} ->
            rollback_created_files(acc)
            {:halt, {:error, reason}}
        end

      _other, _acc ->
        {:halt, {:error, "Invalid file upload."}}
    end)
  end

  defp rollback_created_files(file_ids) when is_list(file_ids) do
    Enum.each(file_ids, fn file_id ->
      _ = Files.delete_file_and_maybe_payload(file_id)
    end)

    :ok
  end

  defp parse_upload_ids(params) do
    params
    |> list_param("upload_ids", "upload_ids_json")
    |> case do
      {:ok, values} ->
        values
        |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
          normalized = value |> to_string() |> String.trim()

          cond do
            normalized == "" ->
              {:halt, {:error, "Invalid upload id."}}

            normalized in acc ->
              {:cont, {:ok, acc}}

            true ->
              {:cont, {:ok, acc ++ [normalized]}}
          end
        end)

      error ->
        error
    end
  end

  defp parse_copy_content_ids(params) do
    params
    |> list_param("copy_content_ids", "copy_content_ids_json")
    |> case do
      {:ok, values} ->
        values
        |> Enum.map(&Helpers.parse_optional_integer/1)
        |> Enum.reduce_while([], fn
          nil, _acc -> {:halt, :error}
          id, acc -> {:cont, Enum.uniq(acc ++ [id])}
        end)
        |> case do
          :error -> {:error, "Invalid attachment copy ids."}
          ids -> {:ok, ids}
        end

      error ->
        error
    end
  end

  defp parse_legacy_uploads(params) do
    uploads =
      params
      |> Map.get("files", Map.get(params, :files, []))
      |> List.wrap()

    if Enum.all?(uploads, &match?(%Plug.Upload{}, &1)) do
      {:ok, uploads}
    else
      {:error, "Invalid file upload."}
    end
  end

  defp list_param(params, key, json_key) do
    cond do
      Map.has_key?(params, key) ->
        normalize_list_value(Map.get(params, key))

      Map.has_key?(params, json_key) ->
        normalize_list_value(Map.get(params, json_key))

      true ->
        {:ok, []}
    end
  end

  defp normalize_list_value(nil), do: {:ok, []}
  defp normalize_list_value(values) when is_list(values), do: {:ok, values}

  defp normalize_list_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:ok, []}

      true ->
        case Jason.decode(trimmed) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _other -> {:ok, [trimmed]}
        end
    end
  end

  defp normalize_list_value(_other), do: {:error, "Invalid attachment payload."}
end
