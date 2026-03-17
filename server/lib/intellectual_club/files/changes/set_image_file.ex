defmodule IntellectualClub.Files.Changes.SetImageFile do
  @moduledoc """
  Replaces an image file reference using uploaded payload arguments.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Files

  @impl true
  def change(changeset, opts, _context) do
    field = Keyword.get(opts, :field, :image_file_id)
    filename_arg = Keyword.get(opts, :filename_arg, :filename)
    mime_type_arg = Keyword.get(opts, :mime_type_arg, :mime_type)
    payload_arg = Keyword.get(opts, :payload_arg, :payload)
    old_context_key = {__MODULE__, field, :old_file_id}
    new_context_key = {__MODULE__, field, :new_file_id}

    changeset
    |> Changeset.before_action(fn changeset ->
      old_file_id = current_file_id(changeset, field)
      filename = Changeset.get_argument(changeset, filename_arg)
      mime_type = Changeset.get_argument(changeset, mime_type_arg)
      payload = Changeset.get_argument(changeset, payload_arg)

      case validate_upload_args(filename, mime_type, payload) do
        :ok ->
          case Files.create_from_upload(%{
                 filename: filename,
                 mime_type: mime_type,
                 payload: payload
               }) do
            {:ok, file} ->
              changeset
              |> Changeset.put_context(old_context_key, old_file_id)
              |> Changeset.put_context(new_context_key, file.id)
              |> Changeset.force_change_attribute(field, file.id)

            {:error, _error} ->
              Changeset.add_error(changeset, field: field, message: "failed to store image")
          end

        {:error, message} ->
          Changeset.add_error(changeset, field: field, message: message)
      end
    end)
    |> Changeset.after_action(fn changeset, record ->
      old_file_id = Map.get(changeset.context, old_context_key)
      new_file_id = Map.get(changeset.context, new_context_key)

      if is_integer(old_file_id) and old_file_id != new_file_id do
        :ok = normalize_delete_result(Files.delete_file_and_maybe_payload(old_file_id))
      end

      {:ok, record}
    end)
  end

  defp current_file_id(changeset, field) do
    Changeset.get_attribute(changeset, field) ||
      case changeset.data do
        %{^field => value} -> value
        _ -> nil
      end
  end

  defp validate_upload_args(filename, mime_type, payload) do
    cond do
      not is_binary(filename) or String.trim(filename) == "" ->
        {:error, "filename is required"}

      not is_binary(mime_type) or String.trim(mime_type) == "" ->
        {:error, "mime_type is required"}

      not is_binary(payload) or byte_size(payload) == 0 ->
        {:error, "payload is required"}

      true ->
        :ok
    end
  end

  defp normalize_delete_result(:ok), do: :ok
  defp normalize_delete_result({:error, _reason}), do: :ok
end
