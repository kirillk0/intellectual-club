defmodule IntellectualClub.Llm.Providers.Common.RequestHydration do
  @moduledoc false

  alias IntellectualClub.Generation.RequestImages

  @spec hydrate(map(), integer() | nil, atom() | String.t()) ::
          {:ok, map()} | {:error, map()}
  def hydrate(raw_request, request_step_id, provider) when is_map(raw_request) do
    case RequestImages.hydrate(raw_request, request_step_id) do
      {:ok, %{} = wire_request} ->
        {:ok, wire_request}

      {:error, reason} ->
        {:error, error_meta(raw_request, provider, reason)}

      other ->
        {:error, error_meta(raw_request, provider, {:invalid_hydration_result, other})}
    end
  rescue
    exception ->
      {:error, error_meta(raw_request, provider, exception)}
  catch
    kind, reason ->
      {:error, error_meta(raw_request, provider, {kind, reason})}
  end

  defp error_meta(raw_request, provider, reason) do
    %{
      provider: provider,
      status_code: nil,
      url: nil,
      retryable: false,
      error_kind: "request_hydration",
      error_text: "Failed to hydrate request images: #{error_text(reason)}",
      raw_request: raw_request,
      raw_response: nil
    }
  end

  defp error_text(%{__exception__: true} = exception), do: Exception.message(exception)
  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)
end
