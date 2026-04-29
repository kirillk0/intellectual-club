defmodule IntellectualClub.Llm.Providers.Common.AuthValidation do
  @moduledoc """
  Shared validation for provider metadata backed by existing credential fields.
  """

  @spec validate(map(), keyword()) :: :ok | {:error, keyword(String.t())}
  def validate(provider, opts) when is_map(provider) and is_list(opts) do
    metadata = Keyword.fetch!(opts, :metadata)
    duplicate_without_credentials? = Keyword.get(opts, :duplicate_without_credentials?, false)
    auth_method = normalize_id(Map.get(provider, :auth_method)) || metadata.default_auth_method
    auth_methods = Map.get(metadata, :auth_methods, [])

    case Enum.find(auth_methods, &(Map.get(&1, :value) == auth_method)) do
      nil ->
        {:error, auth_method: "unsupported auth method"}

      method ->
        validate_required_credential(provider, method, duplicate_without_credentials?)
    end
  end

  defp validate_required_credential(_provider, _method, true), do: :ok

  defp validate_required_credential(provider, method, false) do
    credential = Map.get(method, :credential)
    required? = Map.get(method, :required, true)

    cond do
      credential in [nil, ""] or required? == false ->
        :ok

      credential == "api_key" and blank?(Map.get(provider, :api_key)) ->
        {:error, api_key: "is required"}

      credential == "oauth_refresh_token" and blank?(Map.get(provider, :oauth_refresh_token)) ->
        {:error, oauth_refresh_token: "is required"}

      credential in ["api_key", "oauth_refresh_token"] ->
        :ok

      true ->
        {:error, auth_method: "uses unsupported credential field"}
    end
  end

  defp normalize_id(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp normalize_id(_value), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
