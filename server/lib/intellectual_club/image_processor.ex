defmodule IntellectualClub.ImageProcessor do
  @moduledoc false

  @windows? match?({:win32, _name}, :os.type())

  @spec resize_down(binary(), String.t(), pos_integer()) ::
          {:ok, binary(), String.t()} | {:error, term()}
  def resize_down(payload, mime_type, max_edge)
      when is_binary(payload) and is_binary(mime_type) and is_integer(max_edge) and max_edge > 0 do
    with {detected_mime, width, height, _variant}
         when is_binary(detected_mime) and is_integer(width) and is_integer(height) <-
           ExImageInfo.info(payload) do
      if max(width, height) <= max_edge do
        {:ok, payload, normalize_mime_type(detected_mime)}
      else
        resize_backend(payload, normalize_mime_type(mime_type), max_edge)
      end
    else
      nil -> {:error, :invalid_image_payload}
      other -> {:error, {:invalid_image_payload, other}}
    end
  end

  if @windows? do
    defp resize_backend(payload, mime_type, max_edge) do
      with {:ok, suffix} <- image_suffix(mime_type),
           {:ok, executable} <- vips_executable() do
        root =
          Path.join(
            System.tmp_dir!(),
            "intellectual-club-vips-#{System.unique_integer([:positive, :monotonic])}"
          )

        input_path = Path.join(root, "input#{suffix}")
        output_path = Path.join(root, "output#{suffix}")

        try do
          with :ok <- File.mkdir_p(root),
               :ok <- File.write(input_path, payload),
               {_output, 0} <-
                 System.cmd(
                   executable,
                   [
                     "thumbnail",
                     input_path,
                     output_path,
                     Integer.to_string(max_edge),
                     "--size",
                     "down"
                   ],
                   stderr_to_stdout: true
                 ),
               {:ok, resized} <- File.read(output_path),
               {detected_mime, width, height, _variant}
               when is_binary(detected_mime) and is_integer(width) and is_integer(height) <-
                 ExImageInfo.info(resized),
               true <- max(width, height) <= max_edge do
            {:ok, resized, normalize_mime_type(detected_mime)}
          else
            {output, status} when is_integer(status) ->
              {:error, {:vips_failed, status, String.trim(output)}}

            false ->
              {:error, :resized_image_exceeds_limit}

            nil ->
              {:error, :resized_image_invalid}

            {:error, reason} ->
              {:error, reason}

            other ->
              {:error, other}
          end
        after
          File.rm_rf(root)
        end
      end
    end

    defp vips_executable do
      candidates = [
        System.get_env("IC_VIPS_BIN"),
        bundled_vips_executable(),
        System.find_executable("vips.exe"),
        System.find_executable("vips")
      ]

      case Enum.find(candidates, &(is_binary(&1) and File.regular?(&1))) do
        nil -> {:error, :vips_executable_not_found}
        executable -> {:ok, executable}
      end
    end

    defp bundled_vips_executable do
      Application.app_dir(:intellectual_club, "priv/libvips/bin/vips.exe")
    rescue
      _error -> nil
    end
  else
    defp resize_backend(payload, mime_type, max_edge) do
      with {:ok, suffix} <- image_suffix(mime_type),
           {:ok, image} <- Image.from_binary(payload),
           {:ok, resized_image} <- Image.thumbnail(image, max_edge, resize: :down),
           {:ok, resized_payload} when is_binary(resized_payload) <-
             Image.write(resized_image, :memory, suffix: suffix),
           {detected_mime, width, height, _variant}
           when is_binary(detected_mime) and is_integer(width) and is_integer(height) <-
             ExImageInfo.info(resized_payload),
           true <- max(width, height) <= max_edge do
        {:ok, resized_payload, normalize_mime_type(detected_mime)}
      else
        false -> {:error, :resized_image_exceeds_limit}
        nil -> {:error, :resized_image_invalid}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end
  end

  defp image_suffix("image/jpeg"), do: {:ok, ".jpg"}
  defp image_suffix("image/jpg"), do: {:ok, ".jpg"}
  defp image_suffix("image/png"), do: {:ok, ".png"}
  defp image_suffix("image/webp"), do: {:ok, ".webp"}
  defp image_suffix("image/gif"), do: {:ok, ".gif"}
  defp image_suffix(mime_type), do: {:error, {:unsupported_image_mime_type, mime_type}}

  defp normalize_mime_type("image/jpg"), do: "image/jpeg"
  defp normalize_mime_type(mime_type), do: mime_type
end
