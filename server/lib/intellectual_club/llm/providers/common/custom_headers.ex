defmodule IntellectualClub.Llm.Providers.Common.CustomHeaders do
  @moduledoc """
  Applies provider header overrides at the transport boundary, outside the logical payload.
  """

  @type headers :: [{String.t(), String.t()}]

  @spec merge(headers(), map() | nil) :: headers()
  def merge(defaults, custom) when is_map(custom) and map_size(custom) > 0 do
    overrides = Map.new(custom, fn {name, value} -> {String.downcase(name, :ascii), value} end)

    Enum.reject(defaults, fn {name, _value} ->
      Map.has_key?(overrides, String.downcase(name, :ascii))
    end) ++
      Enum.sort(overrides)
  end

  def merge(defaults, _custom), do: defaults

  @spec request!(keyword(), map() | nil) :: Req.Response.t()
  def request!(opts, custom) when is_map(custom) and map_size(custom) > 0 do
    opts
    |> Keyword.update!(:headers, &merge(&1, custom))
    |> Req.new()
    |> Req.Request.prepend_response_steps(provider_redirect: &guard_redirect/1)
    |> Req.request!()
  end

  def request!(opts, _custom), do: Req.request!(opts)

  # Req strips Authorization on cross-origin redirects, but arbitrary customer
  # headers may contain credentials too. Leave same-origin redirects to Req.
  defp guard_redirect({request, %{status: status} = response} = pair)
       when status in [301, 302, 303, 307, 308] do
    with [location | _] <- Req.Response.get_header(response, "location"),
         target = URI.merge(request.url, location),
         false <- origin(request.url) == origin(target) do
      if match?(%Req.Response.Async{}, response.body), do: Req.cancel_async_response(response)
      Req.Request.halt(request, RuntimeError.exception("Cross-origin provider redirect blocked."))
    else
      _ -> pair
    end
  end

  defp guard_redirect(pair), do: pair

  defp origin(uri), do: {uri.scheme, uri.host, uri.port}
end
