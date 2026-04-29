defmodule IntellectualClub.Llm.Changes.ValidateProviderAuth do
  @moduledoc """
  Validates provider type, auth method, and credential requirements.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Llm.Providers.Common.Registry

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      provider = provider_attributes(changeset)
      duplicate_without_credentials? = changeset.context[:duplicate_without_credentials] == true

      case Registry.fetch(Map.get(provider, :type)) do
        {:ok, provider_module} ->
          case provider_module.validate_provider(provider,
                 duplicate_without_credentials?: duplicate_without_credentials?
               ) do
            :ok -> changeset
            {:error, errors} -> add_errors(changeset, errors)
          end

        {:error, :unknown_provider_type} ->
          Changeset.add_error(changeset, field: :type, message: "is not available")
      end
    end)
  end

  defp provider_attributes(changeset) do
    data = changeset.data || %{}

    %{
      type: get_value(changeset, data, :type) || "openrouter_chat_completion",
      auth_method: get_value(changeset, data, :auth_method) || "api_key",
      api_key: get_value(changeset, data, :api_key),
      oauth_refresh_token: get_value(changeset, data, :oauth_refresh_token)
    }
  end

  defp get_value(changeset, data, field) do
    Changeset.get_attribute(changeset, field) ||
      case data do
        %{^field => value} -> value
        _other -> nil
      end
  end

  defp add_errors(changeset, errors) when is_list(errors) do
    Enum.reduce(errors, changeset, fn {field, message}, changeset ->
      Changeset.add_error(changeset, field: field, message: message)
    end)
  end
end
