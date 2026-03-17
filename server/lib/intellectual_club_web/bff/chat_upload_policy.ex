defmodule IntellectualClubWeb.Bff.ChatUploadPolicy do
  @moduledoc """
  Chat attachment policy derived from the current bot and configuration.
  """

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Llm.LlmConfiguration

  @default_max_file_size_bytes 500 * 1024 * 1024

  @type t :: %{
          allow_any_files: boolean(),
          allow_images: boolean(),
          max_file_size_bytes: pos_integer()
        }

  @spec default_max_file_size_bytes() :: pos_integer()
  def default_max_file_size_bytes, do: @default_max_file_size_bytes

  @spec load_for_chat(integer(), term()) :: t()
  def load_for_chat(chat_id, actor) when is_integer(chat_id) do
    chat =
      Ash.get!(Chat, chat_id,
        actor: actor,
        load: [:bot, :llm_configuration],
        strict?: true
      )

    from_chat(chat)
  end

  @spec from_chat(Chat.t()) :: t()
  def from_chat(%Chat{} = chat) do
    bot =
      case Map.get(chat, :bot) do
        %Bot{} = bot -> bot
        _other -> nil
      end

    configuration =
      case Map.get(chat, :llm_configuration) do
        %LlmConfiguration{} = configuration -> configuration
        _other -> nil
      end

    allow_any_files = bool_true?(bot && bot.supports_file_processing)

    allow_images =
      allow_any_files or bool_true?(configuration && configuration.supports_image_input)

    %{
      allow_any_files: allow_any_files,
      allow_images: allow_images,
      max_file_size_bytes: normalize_max_file_size(bot && bot.max_file_size_bytes)
    }
  end

  @spec validate_upload(Plug.Upload.t(), t()) :: :ok | {:error, String.t()}
  def validate_upload(%Plug.Upload{} = upload, policy) when is_map(policy) do
    with {:ok, stat} <- File.stat(upload.path),
         :ok <- validate_size(upload.filename, stat.size, policy),
         :ok <- validate_type(upload, policy) do
      :ok
    else
      {:error, :enoent} ->
        {:error, "Uploaded file is no longer available."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to inspect uploaded file: #{inspect(reason)}"}
    end
  end

  def validate_upload(_other, _policy), do: {:error, "Invalid file upload."}

  defp validate_size(filename, size, %{max_file_size_bytes: max_size})
       when is_integer(size) and is_integer(max_size) and size > max_size do
    {:error, "File #{inspect(filename)} exceeds the maximum size of #{format_size(max_size)}."}
  end

  defp validate_size(_filename, _size, _policy), do: :ok

  defp validate_type(_upload, %{allow_any_files: true}), do: :ok

  defp validate_type(%Plug.Upload{content_type: content_type}, %{allow_images: true}) do
    if Media.image_mime_type?(content_type) do
      :ok
    else
      {:error, "Only image files are allowed for the current bot and configuration."}
    end
  end

  defp validate_type(_upload, _policy) do
    {:error, "File uploads are disabled for the current bot and configuration."}
  end

  defp normalize_max_file_size(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_file_size(_other), do: @default_max_file_size_bytes

  defp bool_true?(value), do: value in [true, "true", 1, "1"]

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
