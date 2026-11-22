defmodule IntellectualClub.Llm.Validations.ValidCustomHeaders do
  @moduledoc """
  Validates provider-supplied HTTP headers before they reach the transport.
  """
  use Ash.Resource.Validation

  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @control ~r/[\x00-\x1F\x7F-\x9F]/u
  @reserved ~w(host content-length transfer-encoding connection upgrade keep-alive te trailer proxy-authorization proxy-connection)

  @impl true
  def validate(changeset, _opts, _context) do
    headers = Ash.Changeset.get_attribute(changeset, :custom_headers)

    with %{} <- headers,
         true <-
           Enum.all?(headers, fn {name, _} -> is_binary(name) and Regex.match?(@token, name) end) do
      names = Enum.map(Map.keys(headers), &String.downcase/1)

      cond do
        Enum.any?(names, &(&1 in @reserved or String.starts_with?(&1, "sec-websocket-"))) ->
          invalid("must not override transport-controlled headers")

        names != Enum.uniq(names) ->
          invalid("must not contain duplicate header names (case-insensitive)")

        Enum.any?(headers, fn {_, value} ->
          not is_binary(value) or Regex.match?(@control, value)
        end) ->
          invalid("header values must be strings without control characters")

        true ->
          :ok
      end
    else
      _ -> invalid("must be an object with valid HTTP header names")
    end
  end

  defp invalid(message), do: {:error, field: :custom_headers, message: message}
end
