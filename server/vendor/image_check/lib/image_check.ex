defmodule ImageCheck do
  @moduledoc """
  Cheap structural validation of JPEG, PNG, GIF and WebP payloads.

  Pixels are never decoded. The checks walk container and codec headers, so a
  payload that passes is well-formed enough for common decoders to open it,
  while payloads that typical decoders reject (broken Huffman tables, corrupt
  PNG streams, truncated GIF/WebP files, ...) fail. JPEG entropy-coded data is
  skipped, PNG image data is inflated in bounded chunks only to verify its
  length and row filter bytes, and GIF LZW data is not decoded.

  Error reasons are stable atoms or short tuples of atoms. They never contain
  bytes, numbers or names taken from the input, and no atoms are created from
  input data. Neither function raises for binary input.
  """

  alias ImageCheck.{Gif, Jpeg, Png, Webp}

  @default_max_pixels 100_000_000

  @type format :: :jpeg | :png | :gif | :webp
  @type info :: %{
          format: format(),
          mime_type: String.t(),
          width: pos_integer(),
          height: pos_integer()
        }
  @type reason :: atom() | {atom(), atom()}

  @modules %{jpeg: Jpeg, png: Png, gif: Gif, webp: Webp}
  @mime_types %{
    jpeg: "image/jpeg",
    png: "image/png",
    gif: "image/gif",
    webp: "image/webp"
  }
  @generic_reasons [:too_many_pixels]

  @doc """
  Detects the format and reads the dimensions from the headers only.

  For GIF these are the logical screen dimensions; `validate/2` also accounts
  for frames that extend past the screen, so it can report a larger size.

  Returns `{:error, :unknown_format}` for unrecognized payloads and
  `{:error, {:unsupported_format, format}}` for recognized formats that are not
  supported (`:bmp`, `:tiff`, `:avif`, `:heic`, `:jxl`, `:ico`).
  """
  @spec header(binary()) :: {:ok, info()} | {:error, reason()}
  def header(payload) when is_binary(payload), do: run(payload, :header, nil)
  def header(_payload), do: {:error, :not_binary}

  @doc """
  Performs the full structural check.

  Options:

    * `:max_pixels` - maximum `width * height` declared by the headers, checked
      before any image data is processed (default #{@default_max_pixels}).
      `:infinity` disables the limit.

  The reported size is the one decoders produce: for GIF, the union of the
  logical screen and every frame rectangle, checked against `:max_pixels` at
  each image descriptor.
  """
  @spec validate(binary(), keyword()) :: {:ok, info()} | {:error, reason()}
  def validate(payload, opts \\ [])

  def validate(payload, opts) when is_binary(payload) and is_list(opts) do
    case Keyword.get(opts, :max_pixels, @default_max_pixels) do
      max when (is_integer(max) and max > 0) or max == :infinity ->
        run(payload, :validate, max)

      _other ->
        {:error, :invalid_options}
    end
  end

  def validate(_payload, _opts), do: {:error, :invalid_arguments}

  @doc "Detects the container format from its magic bytes."
  @spec format(binary()) ::
          {:ok, format()} | {:error, :unknown_format | {:unsupported_format, atom()}}
  def format(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: {:ok, :jpeg}
  def format(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: {:ok, :png}
  def format(<<"GIF87a", _rest::binary>>), do: {:ok, :gif}
  def format(<<"GIF89a", _rest::binary>>), do: {:ok, :gif}
  def format(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: {:ok, :webp}
  def format(<<"BM", _rest::binary>>), do: unsupported(:bmp)
  def format(<<"II", 42, 0, _rest::binary>>), do: unsupported(:tiff)
  def format(<<"MM", 0, 42, _rest::binary>>), do: unsupported(:tiff)
  def format(<<"II", 43, 0, _rest::binary>>), do: unsupported(:tiff)
  def format(<<"MM", 0, 43, _rest::binary>>), do: unsupported(:tiff)
  def format(<<0xFF, 0x0A, _rest::binary>>), do: unsupported(:jxl)
  def format(<<0, 0, 0, 12, "JXL ", _rest::binary>>), do: unsupported(:jxl)
  def format(<<0, 0, 1, 0, _rest::binary>>), do: unsupported(:ico)

  def format(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>) do
    cond do
      brand in ["avif", "avis"] ->
        unsupported(:avif)

      brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"] ->
        unsupported(:heic)

      true ->
        {:error, :unknown_format}
    end
  end

  def format(_payload), do: {:error, :unknown_format}

  @doc "Returns the MIME type for a supported format."
  @spec mime_type(format()) :: String.t()
  def mime_type(format) when is_map_key(@mime_types, format), do: Map.fetch!(@mime_types, format)

  @doc false
  # Parsers throw `{ImageCheck, reason}` to abort a check.
  @spec fail(atom()) :: no_return()
  def fail(reason) when is_atom(reason), do: throw({__MODULE__, reason})

  @doc false
  def check_pixels(width, height, max_pixels) do
    if max_pixels != :infinity and width * height > max_pixels, do: fail(:too_many_pixels)
    :ok
  end

  defp unsupported(format), do: {:error, {:unsupported_format, format}}

  defp run(payload, mode, max_pixels) do
    with {:ok, format} <- format(payload) do
      module = Map.fetch!(@modules, format)

      try do
        {width, height} =
          case mode do
            :header -> module.header(payload)
            :validate -> module.validate(payload, max_pixels)
          end

        {:ok,
         %{
           format: format,
           mime_type: Map.fetch!(@mime_types, format),
           width: width,
           height: height
         }}
      catch
        {__MODULE__, reason} when reason in @generic_reasons -> {:error, reason}
        {__MODULE__, reason} -> {:error, {format, reason}}
        :error, _exception -> {:error, {format, :malformed}}
      end
    end
  end
end
