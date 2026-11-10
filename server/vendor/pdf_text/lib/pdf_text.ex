defmodule PdfText do
  @moduledoc """
  Bounded synchronous PDF text-layer extraction using Elixir and OTP zlib.

  No worker is started and no caller process flags are changed. Callers should
  provide admission control, a monitored memory-capped worker and a watchdog.
  See the package README for the supported subset and budget semantics.
  """
  alias PdfText.{Context, Document, Content}
  @version "0.1.0"
  @defaults %{
    max_chars: 500_000,
    timeout_ms: 45_000,
    max_input_bytes: 50 * 1024 * 1024,
    max_output_bytes: 2 * 1024 * 1024
  }
  @caps %{
    max_chars: 2_000_000,
    timeout_ms: 120_000,
    max_input_bytes: 100 * 1024 * 1024,
    max_output_bytes: 8 * 1024 * 1024
  }
  @type result :: %{
          text: binary(),
          page_count: non_neg_integer(),
          pages_extracted: non_neg_integer(),
          version: binary(),
          truncated: boolean(),
          partial: boolean(),
          warnings: [map()]
        }
  @spec extract(binary(), keyword()) :: {:ok, result()} | {:error, atom() | tuple()}
  def extract(bytes, opts \\ []) do
    with {:ok, options} <- options(opts),
         :ok <- input(bytes, options.max_input_bytes) do
      Context.run(options, fn -> execute(bytes) end)
    end
  end

  defp execute(bytes) do
    try do
      pages = Document.open(bytes)

      Enum.each(pages, fn page ->
        Document.clear_cache()
        if Context.get(:chars) > 0, do: Context.output("\n\n")

        try do
          Content.page(page)
          Context.put(:pages_extracted, Context.get(:pages_extracted) + 1)
        rescue
          _ -> Context.warn(:invalid_page)
        catch
          {:pdf_error, reason} -> Context.warn(reason)
        end
      end)

      result()
    rescue
      _ -> {:error, :invalid_pdf}
    catch
      :pdf_output_limit ->
        Context.put(:truncated, true)
        Context.put(:partial, true)
        Context.warn(:output_limit)
        result()

      {:pdf_limit, reason} ->
        Context.put(:truncated, true)
        Context.warn({:limit, reason})
        result({:limit_exceeded, reason})

      {:pdf_error, reason} ->
        {:error, reason}
    end
  end

  defp result(empty_reason \\ :no_text) do
    text =
      Context.get(:chunks)
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> String.trim()
      |> :binary.copy()

    if text == "" do
      {:error, empty_reason}
    else
      {:ok,
       %{
         text: text,
         page_count: Context.get(:page_count),
         pages_extracted: Context.get(:pages_extracted),
         version: @version,
         truncated: Context.get(:truncated),
         partial: Context.get(:partial),
         warnings: Enum.reverse(Context.get(:warnings))
       }}
    end
  end

  defp input(bytes, cap) when is_binary(bytes) do
    cond do
      byte_size(bytes) > cap -> {:error, :input_too_large}
      not match?(<<"%PDF-", _::binary>>, bytes) -> {:error, :invalid_pdf}
      true -> :ok
    end
  end

  defp input(_, _), do: {:error, :invalid_input}

  defp options(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Enum.all?(
           Keyword.keys(opts),
           &(&1 in [:max_chars, :timeout_ms, :max_input_bytes, :max_output_bytes, :limits])
         ) do
      overrides = Keyword.get(opts, :limits, [])
      base = Map.merge(@defaults, Map.new(Keyword.delete(opts, :limits)))
      valid = Enum.all?(base, fn {k, v} -> is_integer(v) and v > 0 and v <= @caps[k] end)
      limits = Context.defaults()

      if valid and is_list(overrides) and Keyword.keyword?(overrides) and
           Enum.all?(overrides, fn {k, v} ->
             Map.has_key?(limits, k) and is_integer(v) and v > 0 and v <= limits[k]
           end) do
        {:ok, Map.put(base, :limits, Map.merge(limits, Map.new(overrides)))}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end
end
