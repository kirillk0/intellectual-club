defmodule IntellectualClubWeb.Bff.ChatUploadPolicy do
  @moduledoc """
  Chat attachment policy derived from the current bot and configuration.
  """

  alias IntellectualClub.Chat.UploadPolicy

  @type t :: UploadPolicy.t()

  defdelegate default_max_file_size_bytes(), to: UploadPolicy
  defdelegate load_for_chat(chat_id, actor), to: UploadPolicy
  defdelegate from_chat(chat), to: UploadPolicy
  defdelegate validate_upload(upload, policy), to: UploadPolicy
  defdelegate validate_file_spec(filename, mime_type, size, policy), to: UploadPolicy
end
