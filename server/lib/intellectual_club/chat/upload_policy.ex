defmodule IntellectualClub.Chat.UploadPolicy do
  @moduledoc """
  Chat attachment policy derived from the current bot and configuration.
  """

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Tools.BindingResolver

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

    tool_resolution = BindingResolver.resolve_for_chat(chat, actor)

    from_chat(chat, artifact_tools_available: tool_resolution.artifact_tools_available)
  end

  @spec from_chat(Chat.t(), keyword()) :: t()
  def from_chat(chat, opts \\ [])

  def from_chat(%Chat{} = chat, opts) when is_list(opts) do
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

    allow_any_files = bool_true?(Keyword.get(opts, :artifact_tools_available, false))

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
         :ok <- validate_file_spec(upload.filename, upload.content_type, stat.size, policy) do
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

  @spec validate_file_spec(String.t() | nil, String.t() | nil, integer(), t()) ::
          :ok | {:error, String.t()}
  def validate_file_spec(filename, mime_type, size, policy)
      when is_integer(size) and is_map(policy) do
    with :ok <- validate_presence(filename),
         :ok <- validate_non_empty(size),
         :ok <- validate_size(filename, size, policy),
         :ok <- validate_type(mime_type, policy) do
      :ok
    end
  end

  def validate_file_spec(_filename, _mime_type, _size, _policy),
    do: {:error, "Invalid file upload."}

  defp validate_presence(filename) do
    case filename |> to_string() |> String.trim() do
      "" -> {:error, "Filename is required."}
      _other -> :ok
    end
  end

  defp validate_non_empty(size) when size <= 0, do: {:error, "File is empty."}
  defp validate_non_empty(_size), do: :ok

  defp validate_size(filename, size, %{max_file_size_bytes: max_size})
       when is_integer(size) and is_integer(max_size) and size > max_size do
    {:error, "File #{inspect(filename)} exceeds the maximum size of #{format_size(max_size)}."}
  end

  defp validate_size(_filename, _size, _policy), do: :ok

  defp validate_type(_mime_type, %{allow_any_files: true}), do: :ok

  defp validate_type(mime_type, %{allow_images: true}) do
    if Media.image_mime_type?(mime_type) do
      :ok
    else
      {:error, "Only image files are allowed for the current bot and configuration."}
    end
  end

  defp validate_type(_mime_type, _policy) do
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
