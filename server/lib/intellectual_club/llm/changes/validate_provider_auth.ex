defmodule IntellectualClub.Llm.Changes.ValidateProviderAuth do
  @moduledoc """
  Validates provider auth method and credential requirements.

  For MVP we support two auth methods:
  - `api_key`: static bearer token
  - `openai_oauth_refresh_token`: OpenAI OAuth refresh flow (Responses providers only)
  """

  use Ash.Resource.Change

  alias Ash.Changeset

  @supported_auth_methods [:api_key, :openai_oauth_refresh_token]

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      type = get_provider_type(changeset)
      auth_method = get_auth_method(changeset)

      changeset =
        if auth_method in @supported_auth_methods do
          changeset
        else
          Changeset.add_error(changeset, field: :auth_method, message: "unsupported auth method")
        end

      validate_auth_method_supported_for_type(changeset, type, auth_method)
      |> validate_credentials_present(type, auth_method)
    end)
  end

  defp get_provider_type(changeset) do
    raw =
      Changeset.get_attribute(changeset, :type) ||
        case changeset.data do
          %{type: type} -> type
          _ -> nil
        end

    normalize_provider_type(raw)
  end

  defp get_auth_method(changeset) do
    raw =
      Changeset.get_attribute(changeset, :auth_method) ||
        case changeset.data do
          %{auth_method: auth_method} -> auth_method
          _ -> nil
        end

    normalize_auth_method(raw) || :api_key
  end

  defp validate_auth_method_supported_for_type(changeset, type, auth_method) do
    cond do
      auth_method == :openai_oauth_refresh_token and type != :responses ->
        Changeset.add_error(changeset,
          field: :auth_method,
          message: "is only supported for responses providers"
        )

      true ->
        changeset
    end
  end

  defp validate_credentials_present(changeset, type, auth_method) do
    if changeset.context[:duplicate_without_credentials] == true do
      changeset
    else
      cond do
        type in [:responses, :openrouter_chat_completion] and auth_method == :api_key ->
          api_key =
            Changeset.get_attribute(changeset, :api_key) ||
              case changeset.data do
                %{api_key: api_key} -> api_key
                _ -> nil
              end

          if blank?(api_key) do
            Changeset.add_error(changeset, field: :api_key, message: "is required")
          else
            changeset
          end

        type == :responses and auth_method == :openai_oauth_refresh_token ->
          refresh_token =
            Changeset.get_attribute(changeset, :oauth_refresh_token) ||
              case changeset.data do
                %{oauth_refresh_token: token} -> token
                _ -> nil
              end

          if blank?(refresh_token) do
            Changeset.add_error(changeset, field: :oauth_refresh_token, message: "is required")
          else
            changeset
          end

        true ->
          changeset
      end
    end
  end

  defp normalize_provider_type(value) when is_atom(value), do: value

  defp normalize_provider_type(value) when is_binary(value) do
    case String.trim(value) do
      "openrouter_chat_completion" -> :openrouter_chat_completion
      "openai_compatible" -> :openrouter_chat_completion
      "responses" -> :responses
      "demo" -> :demo
      _ -> nil
    end
  end

  defp normalize_provider_type(_value), do: nil

  defp normalize_auth_method(value) when is_atom(value), do: value

  defp normalize_auth_method(value) when is_binary(value) do
    case String.trim(value) do
      "api_key" -> :api_key
      "openai_oauth_refresh_token" -> :openai_oauth_refresh_token
      _ -> nil
    end
  end

  defp normalize_auth_method(_value), do: nil

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
