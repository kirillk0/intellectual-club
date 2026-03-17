defmodule IntellectualClub.Llm.Auth do
  @moduledoc """
  Provider auth utilities.

  This module returns a bearer token string that can be used as:
  `Authorization: Bearer <token>`.
  """

  alias IntellectualClub.Llm.Auth.OpenAIOAuth

  @type auth_method :: :api_key | :openai_oauth_refresh_token

  @spec get_bearer_token(%{
          optional(:provider_id) => integer() | nil,
          optional(:auth_method) => auth_method() | String.t() | nil,
          optional(:api_key) => String.t() | nil,
          optional(:oauth_refresh_token) => String.t() | nil
        }) :: {:ok, String.t()} | {:error, String.t()}
  def get_bearer_token(opts) when is_map(opts) do
    provider_id = Map.get(opts, :provider_id)
    auth_method = normalize_auth_method(Map.get(opts, :auth_method))

    case auth_method do
      :api_key ->
        api_key = Map.get(opts, :api_key)

        if blank?(api_key) do
          {:error, "Provider API key is not set"}
        else
          {:ok, String.trim(api_key)}
        end

      :openai_oauth_refresh_token ->
        refresh_token = Map.get(opts, :oauth_refresh_token)

        if blank?(refresh_token) do
          {:error, "Provider OAuth refresh token is not set"}
        else
          OpenAIOAuth.get_access_token(String.trim(refresh_token), provider_id: provider_id)
        end
    end
  end

  defp normalize_auth_method(value) when is_atom(value) do
    if value in [:api_key, :openai_oauth_refresh_token], do: value, else: :api_key
  end

  defp normalize_auth_method(value) when is_binary(value) do
    case String.trim(value) do
      "api_key" -> :api_key
      "openai_oauth_refresh_token" -> :openai_oauth_refresh_token
      _ -> :api_key
    end
  end

  defp normalize_auth_method(_value), do: :api_key

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
